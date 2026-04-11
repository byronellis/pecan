import Foundation
import GRPC
import NIO
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.agent")

/// Serializes all writes to the gRPC request stream to prevent concurrent send crashes.
actor StreamWriter {
    private let stream: GRPCAsyncRequestStreamWriter<Pecan_AgentEvent>

    init(_ stream: GRPCAsyncRequestStreamWriter<Pecan_AgentEvent>) {
        self.stream = stream
    }

    func send(_ msg: Pecan_AgentEvent) async throws {
        try await stream.send(msg)
    }

    func finish() {
        stream.finish()
    }
}


/// Send a JSON-structured progress message to the server for the UI to parse.
func sendTypedProgress(
    _ writer: StreamWriter,
    type: String,
    fields: [String: String] = [:]
) async throws {
    var dict = fields
    dict["type"] = type
    let data = try JSONSerialization.data(withJSONObject: dict)
    let json = String(data: data, encoding: .utf8)!
    var msg = Pecan_AgentEvent()
    var prog = Pecan_TaskProgress()
    prog.statusMessage = json
    msg.progress = prog
    try await writer.send(msg)
}

func main() async throws {
    let args = CommandLine.arguments

    // Invoke subcommand: pecan-agent invoke <tool_name> [<json_args>]
    if args.count >= 3 && args[1] == "invoke" {
        let toolName = args[2]
        let argsJSON = args.count >= 4 ? args[3] : "{}"
        await ToolManager.shared.registerBuiltinTools()
        await ToolManager.shared.loadTools()
        await SkillManager.shared.discoverSkills()
        await SkillManager.shared.registerLuaTools()
        do {
            let result = try await ToolManager.shared.executeTool(name: toolName, argumentsJSON: argsJSON)
            print(result)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    guard args.count > 1 else {
        logger.error("Usage: pecan-agent <session_id> [host_address]")
        exit(1)
    }
    
    let sessionID = args[1]
    let hostAddress = args.count > 2 ? args[2] : "127.0.0.1"
    let agentID = UUID().uuidString

    // Register built-in tools, then load user Lua tools, then hooks, then prompt fragments
    await ToolManager.shared.registerBuiltinTools()
    await ToolManager.shared.loadTools()
    await HookManager.shared.loadHooks()
    await SkillManager.shared.discoverSkills()
    await SkillManager.shared.registerLuaTools()
    await PromptComposer.shared.registerBuiltinFragments()
    await PromptComposer.shared.loadUserFragments()

#if os(Linux)
    // Create FUSE filesystem actors — mount all at startup before the gRPC event loop
    let memFS = MemoryFUSEFilesystem()
    let skillsFS = SkillsFUSEFilesystem(upperDir: "/tmp/skills-upper")

    // Mount COW overlay at /project if lower dir exists; upper dir is local to the container
    let lowerProjectDir = "/project-lower"
    let upperProjectDir = "/project-upper"
    if FileManager.default.fileExists(atPath: lowerProjectDir) {
        Thread.detachNewThread {
            do {
                let fd = try fuseOpenDevice()
                try fuseMountPoint("/project", fd: fd)
                let fs = COWOverlayFilesystem(lower: lowerProjectDir, upper: upperProjectDir)
                let server = FUSEServer(fd: fd, fs: fs)
                logger.info("Mounted COW overlay at /project (lower: \(lowerProjectDir), upper: \(upperProjectDir))")
                server.runOnThread()
            } catch {
                logger.error("Failed to mount project overlay: \(error)")
            }
        }
    }

    Thread.detachNewThread {
        do {
            let fd = try fuseOpenDevice()
            try fuseMountPoint("/memory", fd: fd)
            let server = FUSEServer(fd: fd, fs: memFS)
            logger.info("Mounted memory FUSE at /memory")
            server.runOnThread()
        } catch {
            logger.error("Failed to mount memory FUSE: \(error)")
        }
    }

    Thread.detachNewThread {
        do {
            let fd = try fuseOpenDevice()
            try fuseMountPoint("/skills", fd: fd)
            let server = FUSEServer(fd: fd, fs: skillsFS)
            logger.info("Mounted skills FUSE at /skills")
            server.runOnThread()
        } catch {
            logger.error("Failed to mount skills FUSE: \(error)")
        }
    }

#endif

    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel: GRPCChannel
    if hostAddress.hasPrefix("/") {
        // Unix domain socket path (used when running inside a container with vsock relay)
        logger.info("Pecan Agent \(agentID) Starting for session: \(sessionID) connecting via Unix socket \(hostAddress)")
        channel = try GRPCChannelPool.with(
            target: .unixDomainSocket(hostAddress),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) { config in
            config.keepalive = ClientConnectionKeepalive(
                interval: .seconds(15),
                timeout: .seconds(10),
                permitWithoutCalls: true,
                maximumPingsWithoutData: 0
            )
        }
    } else {
        // TCP connection (used for local development)
        logger.info("Pecan Agent \(agentID) Starting for session: \(sessionID) connecting to \(hostAddress):3000")
        channel = try GRPCChannelPool.with(
            target: .host(hostAddress, port: 3000),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) { config in
            config.keepalive = ClientConnectionKeepalive(
                interval: .seconds(15),
                timeout: .seconds(10),
                permitWithoutCalls: true,
                maximumPingsWithoutData: 0
            )
            config.connectionBackoff = ConnectionBackoff(
                initialBackoff: 1.0,
                maximumBackoff: 60.0,
                multiplier: 1.6,
                jitter: 0.2
            )
        }
    }

    let client = Pecan_AgentServiceAsyncClient(channel: channel)
    
    // Open Bidirectional Stream
    let call = client.makeConnectCall()
    let writer = StreamWriter(call.requestStream)

    // Configure gRPC clients with the send callback
    await TaskClient.shared.configure { msg in
        try await writer.send(msg)
    }
    await HttpClient.shared.configure { msg in
        try await writer.send(msg)
    }
    await MemoryClient.shared.configure { msg in
        try await writer.send(msg)
    }
    await SkillsClient.shared.configure { msg in
        try await writer.send(msg)
    }
    await ProjectToolClient.shared.configure { msg in
        try await writer.send(msg)
    }

    // Register
    var regMsg = Pecan_AgentEvent()
    var reg = Pecan_AgentRegistration()
    reg.agentID = agentID
    reg.sessionID = sessionID
    regMsg.register = reg
    try await writer.send(regMsg)
    
    var availableModels: [String] = []
    
    // Listen for commands from Server
    do {
        for try await command in call.responseStream {
            switch command.payload {
            case .registrationResponse(let resp):
                logger.info("Registration successful: \(resp.success)")

                // Store project/team context for prompt composition and tools
                if !resp.projectName.isEmpty {
                    await PromptComposer.shared.setProjectContext(
                        name: resp.projectName,
                        directory: resp.projectDirectory,
                        mount: resp.projectMount
                    )
                }
                if !resp.teamName.isEmpty {
                    await PromptComposer.shared.setTeamContext(
                        name: resp.teamName,
                        mount: resp.teamMount
                    )
                }

                // Register project tools received from server
                if !resp.projectTools.isEmpty {
                    for toolDef in resp.projectTools {
                        let tool = ProjectTool(definition: toolDef)
                        await ToolManager.shared.register(tool: tool)
                    }
                    logger.info("Registered \(resp.projectTools.count) project tool(s): \(resp.projectTools.map(\.name).joined(separator: ", "))")
                }

                logger.info("Registration: firing agent.registered hook")

                await HookManager.shared.fire(event: "agent.registered", data: [
                    "agent_id": agentID,
                    "session_id": sessionID,
                    "project": resp.projectName,
                    "team": resp.teamName,
                ])
                logger.info("Registration: hook done, configuring FUSE")

#if os(Linux)
                // Configure memory FUSE with project/team scope now that we know the context
                await memFS.configure(hasProject: !resp.projectName.isEmpty, hasTeam: !resp.teamName.isEmpty)
                // Populate skills FUSE lower layer from server in background
                Task.detached { await skillsFS.configure() }
                logger.info("Registration: FUSE configured, sending progress")
#endif

                // Immediately send a progress update that we are alive
                var progMsg = Pecan_AgentEvent()
                var prog = Pecan_TaskProgress()
                prog.statusMessage = "Agent booted and registered!"
                progMsg.progress = prog
                try await writer.send(progMsg)
                logger.info("Registration: progress sent, requesting models")

                // Ask for models
                var modelsReqMsg = Pecan_AgentEvent()
                var modelsReq = Pecan_GetModelsRequest()
                modelsReq.requestID = UUID().uuidString
                modelsReqMsg.getModels = modelsReq
                try await writer.send(modelsReqMsg)
                logger.info("Registration: getModels sent, composing system prompt")

                // Add a system prompt to context
                var ctxMsg = Pecan_AgentEvent()
                var ctxCmd = Pecan_ContextCommand()
                ctxCmd.requestID = UUID().uuidString
                var addMsg = Pecan_AddContextMessage()
                addMsg.section = .system
                addMsg.role = "system"
                let systemPrompt = await PromptComposer.shared.compose(agentID: agentID, sessionID: sessionID)
                logger.info("System prompt length: \(systemPrompt.count) chars")
                logger.debug("System prompt:\n\(systemPrompt)")
                addMsg.content = systemPrompt
                ctxCmd.addMessage = addMsg
                ctxMsg.contextCommand = ctxCmd
                try await writer.send(ctxMsg)
                logger.info("Registration: context sent, entering main loop")

            case .modelsResponse(let resp):
                availableModels = resp.models.map { $0.key }
                logger.info("Agent received available models: \(availableModels)")
                
            case .contextResponse(let resp):
                logger.debug("Agent received context response: \(resp.infoJson)")
                
            case .processInput(let input):
                logger.info("Received processInput, text length: \(input.text.count)")
                
                // Add user message to context
                var ctxMsg = Pecan_AgentEvent()
                var ctxCmd = Pecan_ContextCommand()
                ctxCmd.requestID = UUID().uuidString
                var addMsg = Pecan_AddContextMessage()
                addMsg.section = .conversation
                addMsg.role = "user"
                addMsg.content = input.text
                ctxCmd.addMessage = addMsg
                ctxMsg.contextCommand = ctxCmd
                try await writer.send(ctxMsg)
                
                // Signal thinking to UI
                try await sendTypedProgress(writer, type: "thinking")

                // Request completion
                var reqMsg = Pecan_AgentEvent()
                var compReq = Pecan_LLMCompletionRequest()
                compReq.requestID = UUID().uuidString
                compReq.modelKey = ""

                let activeTags = await PromptComposer.shared.getActiveToolTags()
                if let toolData = try? await ToolManager.shared.getToolDefinitions(tags: activeTags),
                   let toolDefs = try? JSONSerialization.jsonObject(with: toolData) as? [[String: Any]],
                   !toolDefs.isEmpty {
                    let params = ["tools": toolDefs]
                    if let data = try? JSONSerialization.data(withJSONObject: params),
                       let str = String(data: data, encoding: .utf8) {
                        compReq.paramsJson = str
                    }
                    logger.info("Sending \(toolDefs.count) tool definitions to LLM")
                } else {
                    compReq.paramsJson = ""
                    logger.warning("No tool definitions available!")
                }

                reqMsg.completionRequest = compReq
                try await writer.send(reqMsg)
                logger.info("Sent LLM request to server using default model.")
                
            case .completionResponse(let resp):
                logger.info("Received completion_response for request \(resp.requestID)")
                
                var finalText = ""
                var toolCallsToExecute: [[String: Any]] = []
                var messageToSave: [String: Any]? = nil
                
                if !resp.errorMessage.isEmpty {
                    finalText = "Error from LLM Provider: \(resp.errorMessage)"
                } else {
                    // Try to parse OpenAI format
                    if let data = resp.responseJson.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any] {
                        
                        messageToSave = message
                        
                        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                            toolCallsToExecute = toolCalls
                        } else if let content = message["content"] as? String {
                            finalText = content
                        } else {
                            finalText = "Could not parse response content."
                        }
                    } else {
                        finalText = "Could not parse response: \(resp.responseJson)"
                    }
                }
                
                // 1. Save the assistant's message to context (whether it's text or tool_calls)
                if let msg = messageToSave {
                    var ctxMsg = Pecan_AgentEvent()
                    var ctxCmd = Pecan_ContextCommand()
                    ctxCmd.requestID = UUID().uuidString
                    var addMsg = Pecan_AddContextMessage()
                    addMsg.section = .conversation
                    addMsg.role = "assistant"
                    addMsg.content = msg["content"] as? String ?? ""
                    
                    var metadata = msg
                    metadata.removeValue(forKey: "role")
                    metadata.removeValue(forKey: "content")
                    if let metaData = try? JSONSerialization.data(withJSONObject: metadata),
                       let metaStr = String(data: metaData, encoding: .utf8) {
                        addMsg.metadataJson = metaStr
                    }
                    
                    ctxCmd.addMessage = addMsg
                    ctxMsg.contextCommand = ctxCmd
                    try await writer.send(ctxMsg)
                }
                
                // 2. Execute tools or send final output to UI
                // Tool execution runs in a separate Task so the response loop
                // stays free to deliver TaskResponse messages (needed by task_* tools).
                if !toolCallsToExecute.isEmpty {
                    // Extract into Sendable struct before crossing Task boundary
                    struct ToolCallInfo: Sendable {
                        let name: String
                        let arguments: String
                        let callId: String
                    }
                    let parsedCalls: [ToolCallInfo] = toolCallsToExecute.compactMap { toolCall in
                        guard let function = toolCall["function"] as? [String: Any],
                              let name = function["name"] as? String,
                              let arguments = function["arguments"] as? String,
                              let callId = toolCall["id"] as? String else { return nil }
                        return ToolCallInfo(name: name, arguments: arguments, callId: callId)
                    }
                    // Capture hook enrichment data before crossing Task boundary
                    let hookTags = await PromptComposer.shared.getActiveToolTags()
                    let hookFocusedTask = await PromptComposer.shared.getFocusedTask()
                    Task {
                        for tc in parsedCalls {
                            let name = tc.name
                            let arguments = tc.arguments
                            let callId = tc.callId

                            logger.info("Executing tool: \(name) locally")

                            // Signal tool_call to UI
                            try await sendTypedProgress(writer, type: "tool_call", fields: [
                                "name": name,
                                "arguments": arguments
                            ])

                            await HookManager.shared.fire(event: "tool.before", data: [
                                "name": name,
                                "arguments": arguments,
                                "active_tags": Array(hookTags).joined(separator: ","),
                                "focused_task_id": hookFocusedTask.map { String($0.id) } ?? "",
                                "focused_task_title": hookFocusedTask?.title ?? ""
                            ])

                            var resultStr = ""
                            do {
                                resultStr = try await ToolManager.shared.executeTool(name: name, argumentsJSON: arguments)
                            } catch {
                                logger.error("Local tool execution failed: \(error)")
                                resultStr = "Error: \(error.localizedDescription)"
                            }

                            // Update focused task in composer when task_focus executes
                            if name == "task_focus" {
                                if let data = resultStr.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let taskID = json["id"] as? Int, taskID > 0 {
                                    let title = json["title"] as? String ?? ""
                                    let desc = json["description"] as? String ?? ""
                                    let status = json["status"] as? String ?? ""
                                    await PromptComposer.shared.setFocusedTask(
                                        PromptContext.TaskInfo(id: taskID, title: title, description: desc, status: status)
                                    )
                                } else {
                                    await PromptComposer.shared.setFocusedTask(nil)
                                }
                            }

                            await HookManager.shared.fire(event: "tool.after", data: [
                                "name": name,
                                "arguments": arguments,
                                "result": resultStr,
                                "active_tags": Array(hookTags).joined(separator: ","),
                                "focused_task_id": hookFocusedTask.map { String($0.id) } ?? "",
                                "focused_task_title": hookFocusedTask?.title ?? ""
                            ])

                            // Signal tool_result to UI
                            let formatted = await ToolManager.shared.formatToolResult(name: name, result: resultStr)
                            try await sendTypedProgress(writer, type: "tool_result", fields: [
                                "name": name,
                                "result": resultStr,
                                "formatted": formatted ?? ""
                            ])

                            // Add tool result to context
                            var ctxMsg = Pecan_AgentEvent()
                            var ctxCmd = Pecan_ContextCommand()
                            ctxCmd.requestID = UUID().uuidString
                            var addMsg = Pecan_AddContextMessage()
                            addMsg.section = .conversation
                            addMsg.role = "tool"
                            addMsg.content = resultStr

                            // Pass the tool_call_id via metadata
                            let meta: [String: Any] = ["tool_call_id": callId]
                            if let metaData = try? JSONSerialization.data(withJSONObject: meta),
                               let metaStr = String(data: metaData, encoding: .utf8) {
                                addMsg.metadataJson = metaStr
                            }

                            ctxCmd.addMessage = addMsg
                            ctxMsg.contextCommand = ctxCmd
                            try await writer.send(ctxMsg)
                        }

                        // Signal thinking again before next LLM call
                        try await sendTypedProgress(writer, type: "thinking")

                        // Request next completion from LLM after the tools have run
                        var reqMsg = Pecan_AgentEvent()
                        var compReq = Pecan_LLMCompletionRequest()
                        compReq.requestID = UUID().uuidString
                        compReq.modelKey = ""

                        let activeTags = await PromptComposer.shared.getActiveToolTags()
                if let toolData = try? await ToolManager.shared.getToolDefinitions(tags: activeTags),
                           let toolDefs = try? JSONSerialization.jsonObject(with: toolData) as? [[String: Any]],
                           !toolDefs.isEmpty {
                            let params = ["tools": toolDefs]
                            if let data = try? JSONSerialization.data(withJSONObject: params),
                               let str = String(data: data, encoding: .utf8) {
                                compReq.paramsJson = str
                            }
                        } else {
                            compReq.paramsJson = ""
                        }

                        reqMsg.completionRequest = compReq
                        try await writer.send(reqMsg)
                    }

                } else {
                    // Send structured response for UI
                    try await sendTypedProgress(writer, type: "response", fields: [
                        "text": finalText
                    ])
                }
                
            case .taskResponse(let resp):
                logger.debug("Received task_response for \(resp.requestID)")
                await TaskClient.shared.handleResponse(resp)

            case .httpResponse(let resp):
                logger.debug("Received http_response for \(resp.requestID)")
                await HttpClient.shared.handleResponse(resp)

            case .toolResponse(let resp):
                await ProjectToolClient.shared.handleResponse(resp)
                
            case .execCommand(let cmd):
                logger.info("Received exec command: \(cmd.command)")
                Task.detached {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", cmd.command]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    var output = ""
                    var exitCode: Int32 = 0
                    do {
                        try process.run()
                        process.waitUntilExit()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        output = String(data: data, encoding: .utf8) ?? ""
                        exitCode = process.terminationStatus
                    } catch {
                        output = "Failed to run command: \(error)"
                        exitCode = 1
                    }
                    var event = Pecan_AgentEvent()
                    var resp = Pecan_ExecResponse()
                    resp.requestID = cmd.requestID
                    resp.output = output
                    resp.exitCode = exitCode
                    event.execResponse = resp
                    try? await writer.send(event)
                }

            case .memoryResponse(let resp):
                await MemoryClient.shared.handleResponse(resp)

            case .skillsResponse(let resp):
                await SkillsClient.shared.handleResponse(resp)

            case .changesetCommand(let cmd):
                #if os(Linux)
                let csResp = ChangesetHandler.handle(cmd: cmd)
                var csEvent = Pecan_AgentEvent()
                csEvent.changesetResponse = csResp
                try? await writer.send(csEvent)
                #endif

            case .mergeConflictCommand(let cmd):
                // Agent accepts its own version for all conflicts.
                // The server's MergeEngine will apply the resolutions to the project directory
                // and then discard those paths from the overlay, then retry the merge.
                var resolution = Pecan_MergeResolutionResponse()
                resolution.mergeID = cmd.mergeID
                resolution.abort = false
                resolution.resolved = cmd.conflicts.map { conflict in
                    var f = Pecan_MergeResolvedFile()
                    f.path = conflict.path
                    f.content = conflict.agentContent.data(using: .utf8) ?? Data()
                    return f
                }
                var resolveEvent = Pecan_AgentEvent()
                resolveEvent.mergeResolution = resolution
                try? await writer.send(resolveEvent)

            case .shutdown(let req):
                logger.warning("Received shutdown command: \(req.reason)")
                await HookManager.shared.fire(event: "agent.shutdown", data: [
                    "reason": req.reason
                ])
                break

            case nil:
                break
            }
        }
    } catch {
        logger.error("Disconnected from server: \(error)")
    }
    
    await writer.finish()
    logger.info("Pecan Agent Shutting Down.")
    
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        logger.critical("Error: \(error)")
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()
