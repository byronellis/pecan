import Foundation
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.agent")

// MARK: - Progress helpers

/// Send a JSON-structured progress message to the server for the UI to parse.
public func sendTypedProgress(
    _ sink: any AgentEventSink,
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
    try await sink.send(msg)
}

// MARK: - AgentEventHandler

/// Handles the server-to-agent command stream. Owns all mutable per-session state
/// (available models, etc.) and delegates complex operations to dedicated helpers.
///
/// `onFUSERegistered(hasProject:hasTeam:)` is called after registration succeeds so
/// that `main()` can configure platform-specific FUSE filesystems without this type
/// needing to know about Linux-only FUSE types.
public actor AgentEventHandler {
    let sink: any AgentEventSink
    let agentID: String
    let sessionID: String
    let deps: AgentDependencies
    var availableModels: [String] = []
    /// Called after registration with (hasProject, hasTeam) flags.
    let onFUSERegistered: ((Bool, Bool) async -> Void)?

    public init(
        sink: any AgentEventSink,
        agentID: String,
        sessionID: String,
        deps: AgentDependencies = .shared,
        onFUSERegistered: ((Bool, Bool) async -> Void)? = nil
    ) {
        self.sink = sink
        self.agentID = agentID
        self.sessionID = sessionID
        self.deps = deps
        self.onFUSERegistered = onFUSERegistered
    }

    // MARK: - Dispatch

    public func handle(_ command: Pecan_HostCommand) async throws {
        switch command.payload {
        case .registrationResponse(let resp):
            try await onRegistrationResponse(resp)
        case .modelsResponse(let resp):
            availableModels = resp.models.map { $0.key }
            logger.info("Agent received available models: \(availableModels)")
        case .contextResponse(let resp):
            logger.debug("Agent received context response: \(resp.infoJson)")
        case .processInput(let input):
            try await onProcessInput(input)
        case .completionResponse(let resp):
            try await onCompletionResponse(resp)
        case .taskResponse(let resp):
            logger.debug("Received task_response for \(resp.requestID)")
            await TaskClient.shared.handleResponse(resp)
        case .httpResponse(let resp):
            logger.debug("Received http_response for \(resp.requestID)")
            await HttpClient.shared.handleResponse(resp)
        case .toolResponse(let resp):
            await ProjectToolClient.shared.handleResponse(resp)
        case .execCommand(let cmd):
            await onExecCommand(cmd)
        case .memoryResponse(let resp):
            await MemoryClient.shared.handleResponse(resp)
        case .skillsResponse(let resp):
            await SkillsClient.shared.handleResponse(resp)
        case .changesetCommand(let cmd):
            #if os(Linux)
            let csResp = ChangesetHandler.handle(cmd: cmd)
            var csEvent = Pecan_AgentEvent()
            csEvent.changesetResponse = csResp
            try? await sink.send(csEvent)
            #endif
        case .mergeConflictCommand(let cmd):
            try await onMergeConflict(cmd)
        case .shutdown(let req):
            logger.warning("Received shutdown command: \(req.reason)")
            await deps.hookManager.fire(event: "agent.shutdown", data: ["reason": req.reason])
        case nil:
            break
        }
    }

    // MARK: - Registration

    private func onRegistrationResponse(_ resp: Pecan_RegistrationResponse) async throws {
        logger.info("Registration successful: \(resp.success)")

        if !resp.projectName.isEmpty {
            await deps.promptComposer.setProjectContext(
                name: resp.projectName,
                directory: resp.projectDirectory,
                mount: resp.projectMount
            )
        }
        if !resp.teamName.isEmpty {
            await deps.promptComposer.setTeamContext(name: resp.teamName, mount: resp.teamMount)
        }

        if !resp.projectTools.isEmpty {
            for toolDef in resp.projectTools {
                let tool = ProjectTool(definition: toolDef)
                await deps.toolManager.register(tool: tool)
            }
            logger.info("Registered \(resp.projectTools.count) project tool(s): \(resp.projectTools.map(\.name).joined(separator: ", "))")
        }

        logger.info("Registration: firing agent.registered hook")
        await deps.hookManager.fire(event: "agent.registered", data: [
            "agent_id": agentID,
            "session_id": sessionID,
            "project": resp.projectName,
            "team": resp.teamName,
        ])
        logger.info("Registration: hook done, configuring FUSE")

#if os(Linux)
        await onFUSERegistered?(!resp.projectName.isEmpty, !resp.teamName.isEmpty)
        logger.info("Registration: FUSE configured, sending progress")
#endif

        var progMsg = Pecan_AgentEvent()
        var prog = Pecan_TaskProgress()
        prog.statusMessage = "Agent booted and registered!"
        progMsg.progress = prog
        try await sink.send(progMsg)
        logger.info("Registration: progress sent, requesting models")

        var modelsReqMsg = Pecan_AgentEvent()
        var modelsReq = Pecan_GetModelsRequest()
        modelsReq.requestID = UUID().uuidString
        modelsReqMsg.getModels = modelsReq
        try await sink.send(modelsReqMsg)
        logger.info("Registration: getModels sent, composing system prompt")

        var ctxMsg = Pecan_AgentEvent()
        var ctxCmd = Pecan_ContextCommand()
        ctxCmd.requestID = UUID().uuidString
        var addMsg = Pecan_AddContextMessage()
        addMsg.section = .system
        addMsg.role = "system"
        let systemPrompt = await deps.promptComposer.compose(agentID: agentID, sessionID: sessionID)
        logger.info("System prompt length: \(systemPrompt.count) chars")
        logger.debug("System prompt:\n\(systemPrompt)")
        addMsg.content = systemPrompt
        ctxCmd.addMessage = addMsg
        ctxMsg.contextCommand = ctxCmd
        try await sink.send(ctxMsg)
        logger.info("Registration: context sent, entering main loop")
    }

    // MARK: - Process input

    private func onProcessInput(_ input: Pecan_ProcessInput) async throws {
        logger.info("Received processInput, text length: \(input.text.count)")

        var ctxMsg = Pecan_AgentEvent()
        var ctxCmd = Pecan_ContextCommand()
        ctxCmd.requestID = UUID().uuidString
        var addMsg = Pecan_AddContextMessage()
        addMsg.section = .conversation
        addMsg.role = "user"
        addMsg.content = input.text
        ctxCmd.addMessage = addMsg
        ctxMsg.contextCommand = ctxCmd
        try await sink.send(ctxMsg)

        try await sendTypedProgress(sink, type: "thinking")
        try await sendCompletionRequest()
        logger.info("Sent LLM request to server using default model.")
    }

    // MARK: - Completion response + tool loop

    private func onCompletionResponse(_ resp: Pecan_LLMCompletionResponse) async throws {
        logger.info("Received completion_response for request \(resp.requestID)")

        var finalText = ""
        var toolCallsToExecute: [[String: Any]] = []
        var messageToSave: [String: Any]?

        if !resp.errorMessage.isEmpty {
            finalText = "Error from LLM Provider: \(resp.errorMessage)"
        } else if let data = resp.responseJson.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] {
            messageToSave = message
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                toolCallsToExecute = toolCalls
            } else {
                finalText = message["content"] as? String ?? "Could not parse response content."
            }
        } else {
            finalText = "Could not parse response: \(resp.responseJson)"
        }

        // Save the assistant's message to context
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
            try await sink.send(ctxMsg)
        }

        if !toolCallsToExecute.isEmpty {
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
            let hookTags = await deps.promptComposer.getActiveToolTags()
            let hookFocusedTask = await deps.promptComposer.getFocusedTask()
            Task {
                for tc in parsedCalls {
                    try await self.executeToolCall(
                        name: tc.name, arguments: tc.arguments, callId: tc.callId,
                        hookTags: hookTags, hookFocusedTask: hookFocusedTask
                    )
                }
                try await sendTypedProgress(self.sink, type: "thinking")
                try await self.sendCompletionRequest()
            }
        } else {
            try await sendTypedProgress(sink, type: "response", fields: ["text": finalText])
        }
    }

    // MARK: - Tool execution

    func executeToolCall(
        name: String,
        arguments: String,
        callId: String,
        hookTags: Set<String>,
        hookFocusedTask: PromptContext.TaskInfo?
    ) async throws {
        logger.info("Executing tool: \(name) locally")

        try await sendTypedProgress(sink, type: "tool_call", fields: ["name": name, "arguments": arguments])

        await deps.hookManager.fire(event: "tool.before", data: [
            "name": name,
            "arguments": arguments,
            "active_tags": Array(hookTags).joined(separator: ","),
            "focused_task_id": hookFocusedTask.map { String($0.id) } ?? "",
            "focused_task_title": hookFocusedTask?.title ?? ""
        ])

        var resultStr = ""
        do {
            resultStr = try await deps.toolManager.executeTool(name: name, argumentsJSON: arguments)
        } catch {
            logger.error("Local tool execution failed: \(error)")
            resultStr = "Error: \(error.localizedDescription)"
        }

        // Keep focused-task state in sync when task_focus runs
        if name == "task_focus" {
            if let data = resultStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let taskID = json["id"] as? Int, taskID > 0 {
                let title  = json["title"] as? String ?? ""
                let desc   = json["description"] as? String ?? ""
                let status = json["status"] as? String ?? ""
                await deps.promptComposer.setFocusedTask(
                    PromptContext.TaskInfo(id: taskID, title: title, description: desc, status: status)
                )
            } else {
                await deps.promptComposer.setFocusedTask(nil)
            }
        }

        await deps.hookManager.fire(event: "tool.after", data: [
            "name": name,
            "arguments": arguments,
            "result": resultStr,
            "active_tags": Array(hookTags).joined(separator: ","),
            "focused_task_id": hookFocusedTask.map { String($0.id) } ?? "",
            "focused_task_title": hookFocusedTask?.title ?? ""
        ])

        let formatted = await deps.toolManager.formatToolResult(name: name, result: resultStr)
        try await sendTypedProgress(sink, type: "tool_result", fields: [
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
        let meta: [String: Any] = ["tool_call_id": callId]
        if let metaData = try? JSONSerialization.data(withJSONObject: meta),
           let metaStr = String(data: metaData, encoding: .utf8) {
            addMsg.metadataJson = metaStr
        }
        ctxCmd.addMessage = addMsg
        ctxMsg.contextCommand = ctxCmd
        try await sink.send(ctxMsg)
    }

    // MARK: - Exec command

    private func onExecCommand(_ cmd: Pecan_ExecCommand) async {
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
            try? await self.sink.send(event)
        }
    }

    // MARK: - Merge conflict

    private func onMergeConflict(_ cmd: Pecan_MergeConflictCommand) async throws {
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
        try? await sink.send(resolveEvent)
    }

    // MARK: - LLM request helper

    /// Build and send an LLM completion request using current tool definitions.
    public func sendCompletionRequest() async throws {
        var reqMsg = Pecan_AgentEvent()
        var compReq = Pecan_LLMCompletionRequest()
        compReq.requestID = UUID().uuidString
        compReq.modelKey = ""

        let activeTags = await deps.promptComposer.getActiveToolTags()
        if let toolData = try? await deps.toolManager.getToolDefinitions(tags: activeTags),
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
        try await sink.send(reqMsg)
    }
}
