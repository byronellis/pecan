import Foundation
import GRPC
import NIO
import PecanShared

func main() async throws {
    let args = CommandLine.arguments
    guard args.count > 1 else {
        print("Usage: pecan-agent <session_id>")
        exit(1)
    }
    
    let sessionID = args[1]
    let agentID = UUID().uuidString
    print("Pecan Agent \(agentID) Starting for session: \(sessionID)")
    
    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: 3000),
        transportSecurity: .plaintext,
        eventLoopGroup: group
    )

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
    
    // Listen for commands from Server
    do {
        for try await command in call.responseStream {
            switch command.payload {
            case .registrationResponse(let resp):
                print("Registration successful: \(resp.success)")
                
                // Immediately send a progress update that we are alive
                var progMsg = Pecan_AgentEvent()
                var prog = Pecan_TaskProgress()
                prog.statusMessage = "Agent booted and registered!"
                progMsg.progress = prog
                try await call.requestStream.send(progMsg)
                
            case .processInput(let input):
                print("Received process_input from Server: \(input.text)")
                
                // Construct a simple OpenAI-compatible payload
                let payload: [String: Any] = [
                    "messages": [
                        ["role": "system", "content": "You are a helpful coding assistant. Keep your answers concise unless asked otherwise."],
                        ["role": "user", "content": input.text]
                    ]
                ]
                
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
                    let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                    
                    var reqMsg = Pecan_AgentEvent()
                    var compReq = Pecan_LLMCompletionRequest()
                    compReq.requestID = UUID().uuidString
                    compReq.payloadJson = jsonString
                    reqMsg.completionRequest = compReq
                    
                    try await call.requestStream.send(reqMsg)
                    print("Sent LLM request to server.")
                } catch {
                    print("Failed to construct LLM payload: \(error)")
                }
                
            case .completionResponse(let resp):
                print("Received completion_response for request \(resp.requestID)")
                
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
                print("Received tool_response: \(resp.resultJson)")
                
            case .shutdown(let req):
                print("Received shutdown command: \(req.reason)")
                break
                
            case nil:
                break
            }
        }
    } catch {
        print("Disconnected from server: \(error)")
    }
    
    call.requestStream.finish()
    print("Pecan Agent Shutting Down.")
    
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        print("Error: \(error)")
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()
