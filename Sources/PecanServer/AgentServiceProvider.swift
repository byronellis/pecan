import Foundation
import GRPC
import NIO
import PecanShared
import PecanServerCore
import PecanSettings
import Logging


final class AgentServiceProvider: Pecan_AgentServiceAsyncProvider {
    init() {}
    
    func connect(
        requestStream: GRPCAsyncRequestStream<Pecan_AgentEvent>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        logger.info("Agent Client connected.")
        var activeSessionID: String? = nil
        
        do {
            for try await event in requestStream {
                switch event.payload {
                case .register(let reg):
                    logger.info("Agent \(reg.agentID) registered for session \(reg.sessionID)")
                    activeSessionID = reg.sessionID

                    await SessionManager.shared.registerAgent(sessionID: reg.sessionID, stream: responseStream)

                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_RegistrationResponse()
                    resp.success = true

                    // Include project/team context. In the flat model, team = project workspace.
                    if let teamName = await SessionManager.shared.getTeamName(sessionID: reg.sessionID) {
                        resp.teamName = teamName
                        resp.projectName = teamName
                        resp.teamMount = "/team"
                        // Get project directory from team store (flat model) or legacy project store
                        let projectDir = await SessionManager.shared.getProjectDirectory(sessionID: reg.sessionID) ?? ""
                        resp.projectDirectory = projectDir
                        if !projectDir.isEmpty {
                            resp.projectMount = "/project"
                            await ProjectToolRegistry.shared.registerSession(
                                sessionID: reg.sessionID,
                                projectName: teamName,
                                projectDirectory: projectDir
                            )
                            resp.projectTools = await ProjectToolRegistry.shared.getAllTools(sessionID: reg.sessionID).map { tool in
                                var def = Pecan_ProjectToolDefinition()
                                def.name = tool.name
                                def.description_p = tool.description
                                def.parametersJsonSchema = tool.parametersSchema ?? ""
                                return def
                            }
                        }
                    } else if let projectName = await SessionManager.shared.getProjectName(sessionID: reg.sessionID) {
                        // Legacy: project without team
                        resp.projectName = projectName
                        let projectDir = await SessionManager.shared.getProjectDirectory(sessionID: reg.sessionID) ?? ""
                        resp.projectDirectory = projectDir
                        if !projectDir.isEmpty {
                            resp.projectMount = "/project"
                        }
                    }

                    cmdMsg.registrationResponse = resp
                    try await responseStream.send(cmdMsg)
                    
                case .progress(let prog):
                    guard let sid = activeSessionID else { continue }
                    logger.debug("Progress from agent: \(prog.statusMessage)")
                    // Route to UI
                    var srvMsg = Pecan_ServerMessage()
                    var out = Pecan_AgentOutput()
                    out.sessionID = sid
                    out.text = prog.statusMessage
                    srvMsg.agentOutput = out
                    try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)

                    // Detect idle transition: agent sent a "response" type progress
                    if let data = prog.statusMessage.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String, type == "response" {
                        await SessionManager.shared.setAgentBusy(sessionID: sid, busy: false)
                        await SessionManager.shared.checkAndDeliverTriggers(sessionID: sid)
                    }
                    
                case .getModels(let req):
                    logger.debug("Agent requested models list.")
                    let allProviders = (try? await SettingsStore.shared.allProviders()) ?? []
                    let cached = await ModelCache.shared.models(providers: allProviders)
                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_GetModelsResponse()
                    resp.requestID = req.requestID
                    for m in cached {
                        var info = Pecan_GetModelsResponse.ModelInfo()
                        info.key = m.key
                        info.name = m.displayName
                        info.description_p = m.providerID
                        info.contextWindow = Int32(m.contextWindow ?? 0)
                        info.modelID = m.modelID
                        resp.models.append(info)
                    }
                    cmdMsg.modelsResponse = resp
                    try await responseStream.send(cmdMsg)
                    
                case .contextCommand(let cmd):
                    guard let sid = activeSessionID else { continue }
                    switch cmd.action {
                    case .addMessage(let addMsg):
                        await SessionManager.shared.addContextMessage(sessionID: sid, section: addMsg.section, role: addMsg.role, content: addMsg.content, metadata: addMsg.metadataJson)
                    case .compact(let compact):
                        await SessionManager.shared.compactContext(sessionID: sid, section: compact.section, keepRecent: Int(compact.keepRecentMessages))
                    case .getInfo(_):
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_ContextResponse()
                        resp.requestID = cmd.requestID
                        resp.infoJson = "{\"status\": \"info not fully implemented\"}"
                        cmdMsg.contextResponse = resp
                        try await responseStream.send(cmdMsg)
                    case nil: break
                    }

                case .completionRequest(let req):
                    guard let sid = activeSessionID else { continue }

                    // --- Model resolution chain ---
                    let allProviders = (try? await SettingsStore.shared.allProviders().filter { $0.enabled }) ?? []
                    let cachedModels = await ModelCache.shared.models(providers: allProviders)

                    let resolvedKey: String
                    if !req.modelKey.isEmpty {
                        resolvedKey = req.modelKey
                    } else if let sessionOverride = await SessionManager.shared.getModelOverride(sessionID: sid) {
                        resolvedKey = sessionOverride
                    } else if !req.currentPersona.isEmpty,
                              let personaModel = try? await SettingsStore.shared.personaModel(for: req.currentPersona) {
                        resolvedKey = personaModel
                    } else if let globalDefault = try? await SettingsStore.shared.globalDefault() {
                        resolvedKey = globalDefault
                    } else {
                        resolvedKey = cachedModels.first?.key ?? ""
                    }

                    logger.info("LLM Request from agent: \(req.requestID) persona='\(req.currentPersona)' resolved model='\(resolvedKey)'")

                    guard let (providerConfig, modelID) = Self.resolveModel(
                        key: resolvedKey, providers: allProviders, cachedModels: cachedModels
                    ) else {
                        let errMsg = "No provider found for model key '\(resolvedKey)'. Run 'pecan configure' to set up a provider."
                        logger.error("\(errMsg)")
                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.errorMessage = errMsg
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                        continue
                    }

                    let llmProvider = ProviderFactory.create(provider: providerConfig, modelID: modelID)
                    do {
                        let contextData = try await SessionManager.shared.getContext(sessionID: sid)
                        var contextMessages: [[String: Any]] = []
                        if let decoded = try JSONSerialization.jsonObject(with: contextData) as? [[String: Any]] {
                            contextMessages = decoded
                        }

                        var payload: [String: Any] = ["messages": contextMessages]
                        if !req.paramsJson.isEmpty,
                           let data = req.paramsJson.data(using: .utf8),
                           let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            for (k, v) in params { payload[k] = v }
                        }
                        let payloadString = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!

                        let responseString = try await llmProvider.complete(payloadJSON: payloadString)

                        // Track token usage for main-agent calls
                        if let paramsData = req.paramsJson.data(using: .utf8),
                           let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
                           params["messages"] == nil,
                           let responseData = responseString.data(using: .utf8),
                           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                           let usage = response["usage"] as? [String: Any],
                           let promptTokens = usage["prompt_tokens"] as? Int {
                            let ctxFromResponse = (response["context_window"] as? Int)
                                ?? (usage["context_window"] as? Int)
                            let ctxWindow = ctxFromResponse
                                ?? cachedModels.first(where: { $0.key == resolvedKey })?.contextWindow
                                ?? providerConfig.contextWindowOverride
                                ?? 0
                            await SessionManager.shared.updateTokenUsage(sessionID: sid, promptTokens: promptTokens, contextWindow: ctxWindow, modelKey: resolvedKey)
                        }

                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.responseJson = responseString
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                    } catch {
                        logger.error("Provider error: \(error)")
                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.errorMessage = error.localizedDescription
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                    }
                    
                case .taskCommand(let cmd):
                    guard let sid = activeSessionID else { continue }
                    do {
                        let result = try await SessionManager.shared.handleTaskCommand(sessionID: sid, action: cmd.action, payloadJSON: cmd.payloadJson, scope: cmd.scope)
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_TaskResponse()
                        resp.requestID = cmd.requestID
                        resp.resultJson = result
                        cmdMsg.taskResponse = resp
                        try await responseStream.send(cmdMsg)
                    } catch {
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_TaskResponse()
                        resp.requestID = cmd.requestID
                        resp.errorMessage = error.localizedDescription
                        cmdMsg.taskResponse = resp
                        try await responseStream.send(cmdMsg)
                    }

                case .httpRequest(let req):
                    guard let sid = activeSessionID else { continue }
                    logger.info("HTTP proxy request from agent: \(req.method) \(req.url) (approval: \(req.requiresApproval))")

                    if req.requiresApproval {
                        // Send approval request to UI, store pending continuation
                        await HttpProxyManager.shared.storePending(
                            requestID: req.requestID,
                            sessionID: sid,
                            request: req,
                            responseStream: responseStream
                        )

                        // Send approval request to UI
                        var srvMsg = Pecan_ServerMessage()
                        var approval = Pecan_ToolApprovalRequest()
                        approval.sessionID = sid
                        approval.toolCallID = req.requestID
                        approval.toolName = "http_request"
                        let details: [String: Any] = [
                            "method": req.method,
                            "url": req.url,
                            "body": req.body
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: details),
                           let str = String(data: data, encoding: .utf8) {
                            approval.argumentsJson = str
                        }
                        srvMsg.approvalRequest = approval
                        try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)
                    } else {
                        // Execute immediately
                        let httpResp = await Self.executeHttpRequest(req)
                        var cmdMsg = Pecan_HostCommand()
                        cmdMsg.httpResponse = httpResp
                        try await responseStream.send(cmdMsg)
                    }

                case .toolRequest(let req):
                    guard let sid = activeSessionID else { continue }
                    logger.info("Project tool request: '\(req.toolName)' for session \(sid)")
                    var cmdMsg = Pecan_HostCommand()
                    let projectDir = await SessionManager.shared.getProjectDirectory(sessionID: sid)
                    let toolResp: Pecan_ToolExecutionResponse
                    if let projectDir, !projectDir.isEmpty {
                        toolResp = await ProjectToolRegistry.shared.executeTool(
                            sessionID: sid,
                            name: req.toolName,
                            projectDirectory: projectDir,
                            requestID: req.requestID
                        )
                    } else {
                        var r = Pecan_ToolExecutionResponse()
                        r.requestID = req.requestID
                        r.errorMessage = "No project directory associated with this session. Project tools require a project context."
                        toolResp = r
                    }
                    cmdMsg.toolResponse = toolResp
                    try await responseStream.send(cmdMsg)

                case .execResponse(let resp):
                    guard let sid = activeSessionID else { continue }
                    var srvMsg = Pecan_ServerMessage()
                    var out = Pecan_AgentOutput()
                    out.sessionID = sid
                    out.text = resp.output
                    srvMsg.agentOutput = out
                    try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)

                case .memoryCommand(let cmd):
                    guard let sid = activeSessionID else { continue }
                    let reply = await Self.handleMemoryCommand(cmd, sessionID: sid)
                    var hostCmd = Pecan_HostCommand()
                    hostCmd.memoryResponse = reply
                    try await responseStream.send(hostCmd)

                case .skillsCommand(let cmd):
                    let reply = await Self.handleSkillsCommand(cmd)
                    var hostCmd = Pecan_HostCommand()
                    hostCmd.skillsResponse = reply
                    try await responseStream.send(hostCmd)

                case .changesetResponse(let resp):
                    await ChangesetClient.shared.handleResponse(resp)

                case .mergeResolution(let resp):
                    await MergeConflictClient.shared.handleResponse(resp)

                case nil:
                    break
                }
            }
        } catch {
            logger.error("Agent Stream error or disconnected: \(error)")
        }

        logger.info("Agent Client disconnected.")
    }
}

extension AgentServiceProvider {
    /// Resolve a model key to a (provider, modelID) pair.
    /// Key formats:
    ///   "providerID/modelID"  → explicit provider + model
    ///   "providerID"          → use provider's first cached model
    ///   "modelID"             → search all providers for this model ID
    static func resolveModel(
        key: String,
        providers: [ProviderConfig],
        cachedModels: [CachedModelInfo]
    ) -> (provider: ProviderConfig, modelID: String?)? {
        if key.contains("/") {
            let idx = key.firstIndex(of: "/")!
            let providerID = String(key[key.startIndex..<idx])
            let modelID = String(key[key.index(after: idx)...])
            guard let p = providers.first(where: { $0.id == providerID }) else { return nil }
            return (p, modelID)
        }
        // Bare key: try as provider ID first
        if let p = providers.first(where: { $0.id == key }) {
            let modelID = cachedModels.first(where: { $0.providerID == key })?.modelID
            return (p, modelID)
        }
        // Try as model ID across all providers
        if let m = cachedModels.first(where: { $0.modelID == key }),
           let p = providers.first(where: { $0.id == m.providerID }) {
            return (p, m.modelID)
        }
        // Fall back to first provider if nothing matches
        if let p = providers.first {
            return (p, nil)
        }
        return nil
    }

    /// Handle a memory command from the agent, dispatching to the appropriate store.
    static func handleMemoryCommand(_ cmd: Pecan_MemoryCommand, sessionID: String) async -> Pecan_MemoryResponse {
        var resp = Pecan_MemoryResponse()
        resp.requestID = cmd.requestID

        func store() async -> (any ScopedStore)? {
            switch cmd.scope {
            case "project": return await SessionManager.shared.getProjectStore(sessionID: sessionID)
            case "team":    return await SessionManager.shared.getTeamStore(sessionID: sessionID)
            default:        return await SessionManager.shared.getStore(sessionID: sessionID)
            }
        }

        do {
            guard let s = await store() else {
                resp.errorMessage = "No store available for scope '\(cmd.scope)'"
                return resp
            }
            switch cmd.action {
            case "list_tags":
                let tags = try s.listTags()
                resp.content = tags.joined(separator: "\n")
            case "read_tag":
                resp.content = try s.renderTag(tag: cmd.tag)
            case "write_tag":
                try s.applyMemoryDiff(tag: cmd.tag, content: cmd.content)
            case "append_tag":
                try s.appendMemory(tag: cmd.tag, content: cmd.content)
            case "unlink_tag":
                try s.unlinkTag(tag: cmd.tag)
            case "rename_tag":
                try s.renameTag(from: cmd.tag, to: cmd.newTag)
            default:
                resp.errorMessage = "Unknown memory action: \(cmd.action)"
            }
        } catch {
            resp.errorMessage = error.localizedDescription
        }
        return resp
    }

    /// Handle a skills command from the agent, serving files from ~/.pecan/skills/.
    static func handleSkillsCommand(_ cmd: Pecan_SkillsCommand) async -> Pecan_SkillsResponse {
        var resp = Pecan_SkillsResponse()
        resp.requestID = cmd.requestID

        let skillsBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pecan/skills").path
        // Sanitize path: strip leading slashes, resolve to skills dir
        let relPath = cmd.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = relPath.isEmpty ? skillsBase : "\(skillsBase)/\(relPath)"

        let fm = FileManager.default
        switch cmd.action {
        case "list_dir":
            guard let contents = try? fm.contentsOfDirectory(atPath: fullPath) else {
                resp.errorMessage = "Cannot list directory: \(cmd.path)"
                return resp
            }
            var entries: [[String: Any]] = []
            for name in contents.sorted() {
                let childPath = "\(fullPath)/\(name)"
                var isDir: ObjCBool = false
                fm.fileExists(atPath: childPath, isDirectory: &isDir)
                let isExec = !isDir.boolValue && fm.isExecutableFile(atPath: childPath)
                entries.append(["name": name, "isDir": isDir.boolValue, "isExecutable": isExec])
            }
            if let data = try? JSONSerialization.data(withJSONObject: entries),
               let json = String(data: data, encoding: .utf8) {
                resp.content = json
            }
        case "read_file":
            guard fm.fileExists(atPath: fullPath) else {
                resp.errorMessage = "File not found: \(cmd.path)"
                return resp
            }
            resp.content = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            resp.isExecutable = fm.isExecutableFile(atPath: fullPath)
        default:
            resp.errorMessage = "Unknown skills action: \(cmd.action)"
        }
        return resp
    }

    /// Execute an HTTP request on behalf of the agent.
    static func executeHttpRequest(_ req: Pecan_HttpProxyRequest) async -> Pecan_HttpProxyResponse {
        var resp = Pecan_HttpProxyResponse()
        resp.requestID = req.requestID

        // Build URL with query params
        guard var components = URLComponents(string: req.url) else {
            resp.errorMessage = "Invalid URL: \(req.url)"
            return resp
        }

        if !req.queryParams.isEmpty {
            var items = components.queryItems ?? []
            for qp in req.queryParams {
                items.append(URLQueryItem(name: qp.name, value: qp.value))
            }
            components.queryItems = items
        }

        guard let url = components.url else {
            resp.errorMessage = "Could not construct URL from components"
            return resp
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method
        urlRequest.timeoutInterval = 30

        for h in req.headers {
            urlRequest.setValue(h.value, forHTTPHeaderField: h.name)
        }

        if !req.body.isEmpty {
            urlRequest.httpBody = req.body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse {
                resp.statusCode = Int32(httpResponse.statusCode)
                for (key, value) in httpResponse.allHeaderFields {
                    var header = Pecan_HttpHeader()
                    header.name = "\(key)"
                    header.value = "\(value)"
                    resp.responseHeaders.append(header)
                }
            }
            resp.body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? "(binary data, \(data.count) bytes)"
        } catch {
            resp.errorMessage = error.localizedDescription
        }

        return resp
    }
}

extension ClientServiceProvider {
    /// Handle tool approval responses from the UI for HTTP proxy requests.
    static func handleToolApproval(_ approval: Pecan_ToolApproval) async {
        guard let pending = await HttpProxyManager.shared.removePending(requestID: approval.toolCallID) else {
            logger.warning("No pending HTTP request for approval ID \(approval.toolCallID)")
            return
        }

        var resp: Pecan_HttpProxyResponse
        if approval.approved {
            resp = await AgentServiceProvider.executeHttpRequest(pending.request)
        } else {
            resp = Pecan_HttpProxyResponse()
            resp.requestID = pending.request.requestID
            let reason = approval.rejectReason.isEmpty ? "User rejected the request" : "Request rejected by user: \(approval.rejectReason)"
            resp.errorMessage = reason
        }

        var cmdMsg = Pecan_HostCommand()
        cmdMsg.httpResponse = resp
        do {
            try await pending.responseStream.send(cmdMsg)
        } catch {
            logger.error("Failed to send HTTP proxy response: \(error)")
        }
    }
}

