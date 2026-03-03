import Foundation
import GRPC
import NIO
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.agent")

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

    return prompt
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

    // Register built-in tools, then load user Lua tools
    await ToolManager.shared.registerBuiltinTools()
    await ToolManager.shared.loadTools()

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
    
    // Register
    var regMsg = Pecan_AgentEvent()
    var reg = Pecan_AgentRegistration()
    reg.agentID = agentID
    reg.sessionID = sessionID
    regMsg.register = reg
    try await call.requestStream.send(regMsg)
    
    var availableModels: [String] = []
    
    // Listen for commands from Server
    do {
        for try await command in call.responseStream {
            switch command.payload {
            case .registrationResponse(let resp):
                logger.info("Registration successful: \(resp.success)")
                
                // Immediately send a progress update that we are alive
                var progMsg = Pecan_AgentEvent()
                var prog = Pecan_TaskProgress()
                prog.statusMessage = "Agent booted and registered!"
                progMsg.progress = prog
                try await call.requestStream.send(progMsg)
                
                // Ask for models
                var modelsReqMsg = Pecan_AgentEvent()
                var modelsReq = Pecan_GetModelsRequest()
                modelsReq.requestID = UUID().uuidString
                modelsReqMsg.getModels = modelsReq
                try await call.requestStream.send(modelsReqMsg)
                
                // Add a system prompt to context
                var ctxMsg = Pecan_AgentEvent()
                var ctxCmd = Pecan_ContextCommand()
                ctxCmd.requestID = UUID().uuidString
                var addMsg = Pecan_AddContextMessage()
                addMsg.section = .system
                addMsg.role = "system"
                addMsg.content = await buildSystemPrompt()
                ctxCmd.addMessage = addMsg
                ctxMsg.contextCommand = ctxCmd
                try await call.requestStream.send(ctxMsg)
                
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
                try await call.requestStream.send(ctxMsg)
                
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
                } else {
                    compReq.paramsJson = ""
                }
                
                reqMsg.completionRequest = compReq
                try await call.requestStream.send(reqMsg)
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
                    try await call.requestStream.send(ctxMsg)
                }
                
                // 2. Execute tools or send final output to UI
                if !toolCallsToExecute.isEmpty {
                    for toolCall in toolCallsToExecute {
                        if let function = toolCall["function"] as? [String: Any],
                           let name = function["name"] as? String,
                           let arguments = function["arguments"] as? String,
                           let callId = toolCall["id"] as? String {
                            
                            logger.info("Executing tool: \(name) locally")
                            
                            var resultStr = ""
                            do {
                                resultStr = try await ToolManager.shared.executeTool(name: name, argumentsJSON: arguments)
                            } catch {
                                logger.error("Local tool execution failed: \(error)")
                                resultStr = "Error: \(error.localizedDescription)"
                            }
                            
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
                            try await call.requestStream.send(ctxMsg)
                        }
                    }
                    
                    // Request next completion from LLM after the tool has run
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
                    try await call.requestStream.send(reqMsg)
                    
                } else {
                    var respMsg = Pecan_AgentEvent()
                    var prog = Pecan_TaskProgress()
                    prog.statusMessage = finalText
                    respMsg.progress = prog
                    try await call.requestStream.send(respMsg)
                }
                
            case .toolResponse(let resp):
                logger.info("Received tool_response from server for \(resp.requestID) - currently unused by local tool execution flow")
                
            case .shutdown(let req):
                logger.warning("Received shutdown command: \(req.reason)")
                break
                
            case nil:
                break
            }
        }
    } catch {
        logger.error("Disconnected from server: \(error)")
    }
    
    call.requestStream.finish()
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
