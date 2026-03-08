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

func buildSystemPrompt() async -> String {
    var prompt = """
    You are a helpful coding assistant with access to tools for reading, writing, editing, and searching files, as well as running shell commands.

    ## Guidelines
    - Read files before editing them to understand existing code.
    - Use search_files to locate relevant code before making changes.
    - When editing, provide enough context in old_string to uniquely identify the target.
    - Keep your answers concise unless asked otherwise.
    - Use the bash tool for running builds, tests, git commands, and other shell operations.

    ## Available Tools
    """

    let tools = await ToolManager.shared.allToolDescriptions()
    for tool in tools {
        prompt += "\n- **\(tool.name)**: \(tool.description)"
    }

    // Fetch core memories and append to system prompt
    do {
        let coreResult = try await TaskClient.shared.sendCommand(action: "memory_list", payload: ["tag": "core"])
        if let data = coreResult.data(using: .utf8),
           let memories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !memories.isEmpty {
            prompt += "\n\n## Core Memories\n"
            for mem in memories {
                let content = mem["content"] as? String ?? ""
                prompt += "\n- \(content)"
            }
        }
    } catch {
        // Core memories are best-effort; don't fail boot if unavailable
        logger.debug("Could not fetch core memories: \(error)")
    }

    return prompt
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
    guard args.count > 1 else {
        logger.error("Usage: pecan-agent <session_id> [host_address]")
        exit(1)
    }
    
    let sessionID = args[1]
    let hostAddress = args.count > 2 ? args[2] : "127.0.0.1"
    let agentID = UUID().uuidString

    // Register built-in tools, then load user Lua tools, then hooks
    await ToolManager.shared.registerBuiltinTools()
    await ToolManager.shared.loadTools()
    await HookManager.shared.loadHooks()

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

    // Configure TaskClient and HttpClient with the send callback
    await TaskClient.shared.configure { msg in
        try await writer.send(msg)
    }
    await HttpClient.shared.configure { msg in
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

                await HookManager.shared.fire(event: "agent.registered", data: [
                    "agent_id": agentID,
                    "session_id": sessionID
                ])

                // Immediately send a progress update that we are alive
                var progMsg = Pecan_AgentEvent()
                var prog = Pecan_TaskProgress()
                prog.statusMessage = "Agent booted and registered!"
                progMsg.progress = prog
                try await writer.send(progMsg)
                
                // Ask for models
                var modelsReqMsg = Pecan_AgentEvent()
                var modelsReq = Pecan_GetModelsRequest()
                modelsReq.requestID = UUID().uuidString
                modelsReqMsg.getModels = modelsReq
                try await writer.send(modelsReqMsg)
                
                // Add a system prompt to context
                var ctxMsg = Pecan_AgentEvent()
                var ctxCmd = Pecan_ContextCommand()
                ctxCmd.requestID = UUID().uuidString
                var addMsg = Pecan_AddContextMessage()
                addMsg.section = .system
                addMsg.role = "system"
                let systemPrompt = await buildSystemPrompt()
                logger.info("System prompt length: \(systemPrompt.count) chars")
                logger.debug("System prompt:\n\(systemPrompt)")
                addMsg.content = systemPrompt
                ctxCmd.addMessage = addMsg
                ctxMsg.contextCommand = ctxCmd
                try await writer.send(ctxMsg)
                
            case .modelsResponse(let resp):
                availableModels = resp.models.map { $0.key }
                logger.info("Agent received available models: \(availableModels)")
                
            case .contextResponse(let resp):
                logger.debug("Agent received context response: \(resp.infoJson)")
                
            case .processInput(let input):
                logger.info("Received process_input from Server: \(input.text)")
                
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

                if let toolData = try? await ToolManager.shared.getToolDefinitions(),
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
                                "arguments": arguments
                            ])

                            var resultStr = ""
                            do {
                                resultStr = try await ToolManager.shared.executeTool(name: name, argumentsJSON: arguments)
                            } catch {
                                logger.error("Local tool execution failed: \(error)")
                                resultStr = "Error: \(error.localizedDescription)"
                            }

                            await HookManager.shared.fire(event: "tool.after", data: [
                                "name": name,
                                "arguments": arguments,
                                "result": resultStr
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

                        if let toolData = try? await ToolManager.shared.getToolDefinitions(),
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
                logger.info("Received tool_response from server for \(resp.requestID) - currently unused by local tool execution flow")
                
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
