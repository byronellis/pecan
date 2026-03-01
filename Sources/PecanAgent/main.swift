import Foundation
import GRPC
import NIO
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.agent")

func main() async throws {
    let args = CommandLine.arguments
    guard args.count > 1 else {
        logger.error("Usage: pecan-agent <session_id>")
        exit(1)
    }
    
    let sessionID = args[1]
    let agentID = UUID().uuidString
    logger.info("Pecan Agent \(agentID) Starting for session: \(sessionID)")
    
    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: 3000),
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
                addMsg.content = "You are a helpful coding assistant. Keep your answers concise unless asked otherwise."
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
                // Send an empty string to instruct the server to use the user's configured default model
                compReq.modelKey = ""
                compReq.paramsJson = "" // Default params
                reqMsg.completionRequest = compReq
                try await call.requestStream.send(reqMsg)
                logger.info("Sent LLM request to server using default model.")
                
            case .completionResponse(let resp):
                logger.info("Received completion_response for request \(resp.requestID)")
                
                var finalText = ""
                
                if !resp.errorMessage.isEmpty {
                    finalText = "Error from LLM Provider: \(resp.errorMessage)"
                } else {
                    // Try to parse OpenAI format
                    if let data = resp.responseJson.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        finalText = content
                        
                        // Save assistant response to context
                        var ctxMsg = Pecan_AgentEvent()
                        var ctxCmd = Pecan_ContextCommand()
                        ctxCmd.requestID = UUID().uuidString
                        var addMsg = Pecan_AddContextMessage()
                        addMsg.section = .conversation
                        addMsg.role = "assistant"
                        addMsg.content = content
                        ctxCmd.addMessage = addMsg
                        ctxMsg.contextCommand = ctxCmd
                        try await call.requestStream.send(ctxMsg)
                        
                    } else {
                        finalText = "Could not parse response: \(resp.responseJson)"
                    }
                }
                
                var respMsg = Pecan_AgentEvent()
                var prog = Pecan_TaskProgress()
                prog.statusMessage = finalText
                respMsg.progress = prog
                try await call.requestStream.send(respMsg)
                
            case .toolResponse(let resp):
                logger.info("Received tool_response: \(resp.resultJson)")
                
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
