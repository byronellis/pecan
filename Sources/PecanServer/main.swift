import Foundation
import GRPC
import NIO
import PecanShared

final class ClientServiceProvider: Pecan_ClientServiceAsyncProvider {
    func streamEvents(
        requestStream: GRPCAsyncRequestStream<Pecan_ClientMessage>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        print("UI Client connected to streamEvents.")
        
        do {
            for try await message in requestStream {
                switch message.payload {
                case .startTask(let req):
                    print("Received start_task: \(req.initialPrompt)")
                    
                    var response = Pecan_ServerMessage()
                    var started = Pecan_SessionStarted()
                    started.sessionID = UUID().uuidString
                    response.sessionStarted = started
                    
                    try await responseStream.send(response)
                    
                    // Simulate agent response
                    var outputResp = Pecan_ServerMessage()
                    var output = Pecan_AgentOutput()
                    output.sessionID = started.sessionID
                    output.text = "Hello! I am ready to help. (Simulated)"
                    outputResp.agentOutput = output
                    
                    try await responseStream.send(outputResp)

                case .userInput(let req):
                    print("Received user input for session \(req.sessionID): \(req.text)")
                    // Echo back for now
                    var outputResp = Pecan_ServerMessage()
                    var output = Pecan_AgentOutput()
                    output.sessionID = req.sessionID
                    output.text = "I received your message: \(req.text)"
                    outputResp.agentOutput = output
                    
                    try await responseStream.send(outputResp)

                case .toolApproval(let req):
                    print("Received tool approval: \(req.approved) for \(req.toolCallID)")
                case nil:
                    print("Received empty payload from UI Client.")
                }
            }
        } catch {
            print("Stream error or disconnected: \(error)")
        }
        
        print("UI Client disconnected.")
    }
}

func main() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    
    let server = try await Server.insecure(group: group)
        .withServiceProviders([ClientServiceProvider()])
        .bind(host: "0.0.0.0", port: 3000)
        .get()
    
    print("Pecan Server started on port \(server.channel.localAddress?.port ?? 3000)")
    
    // Keep server running
    try await server.onClose.get()
    
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        print("Server error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
