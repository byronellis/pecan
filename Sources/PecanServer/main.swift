import Foundation
import GRPC
import NIO
import PecanShared

actor SessionManager {
    static let shared = SessionManager()
    
    // sessionID -> (uiStream, agentStream)
    private var uiStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>] = [:]
    private var agentStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>] = [:]
    
    func registerUI(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>) {
        uiStreams[sessionID] = stream
    }
    
    func registerAgent(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>) {
        agentStreams[sessionID] = stream
    }
    
    func sendToUI(sessionID: String, message: Pecan_ServerMessage) async throws {
        if let stream = uiStreams[sessionID] {
            try await stream.send(message)
        } else {
            print("No UI stream found for session \(sessionID)")
        }
    }
    
    func sendToAgent(sessionID: String, command: Pecan_HostCommand) async throws {
        if let stream = agentStreams[sessionID] {
            try await stream.send(command)
        } else {
            print("No Agent stream found for session \(sessionID)")
        }
    }
    
    func removeSession(sessionID: String) {
        uiStreams.removeValue(forKey: sessionID)
        agentStreams.removeValue(forKey: sessionID)
    }
}

final class ClientServiceProvider: Pecan_ClientServiceAsyncProvider {
    func streamEvents(
        requestStream: GRPCAsyncRequestStream<Pecan_ClientMessage>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        print("UI Client connected.")
        var activeSessionID: String? = nil
        
        do {
            for try await message in requestStream {
                switch message.payload {
                case .startTask(_):
                    let sessionID = UUID().uuidString
                    activeSessionID = sessionID
                    
                    await SessionManager.shared.registerUI(sessionID: sessionID, stream: responseStream)
                    
                    // Notify UI that session started
                    var response = Pecan_ServerMessage()
                    var started = Pecan_SessionStarted()
                    started.sessionID = sessionID
                    response.sessionStarted = started
                    try await responseStream.send(response)
                    
                    // Spawn the agent locally for Phase 1
                    print("Spawning agent for session \(sessionID)...")
                    let task = Process()
                    // Use the built binary directly to avoid SPM locks
                    let currentPath = FileManager.default.currentDirectoryPath
                    task.executableURL = URL(fileURLWithPath: "\(currentPath)/.build/debug/pecan-agent")
                    task.arguments = [sessionID]
                    try task.run()

                case .userInput(let req):
                    print("Routing user input to agent for session \(req.sessionID)")
                    var cmdMsg = Pecan_HostCommand()
                    var processInput = Pecan_ProcessInput()
                    processInput.text = req.text
                    cmdMsg.processInput = processInput
                    
                    try await SessionManager.shared.sendToAgent(sessionID: req.sessionID, command: cmdMsg)

                case .toolApproval(let req):
                    print("Received tool approval: \(req.approved) for \(req.toolCallID)")
                case nil:
                    break
                }
            }
        } catch {
            print("UI Stream error or disconnected: \(error)")
        }
        
        if let sid = activeSessionID {
            await SessionManager.shared.removeSession(sessionID: sid)
        }
        print("UI Client disconnected.")
    }
}

final class AgentServiceProvider: Pecan_AgentServiceAsyncProvider {
    func connect(
        requestStream: GRPCAsyncRequestStream<Pecan_AgentEvent>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        print("Agent Client connected.")
        var activeSessionID: String? = nil
        
        do {
            for try await event in requestStream {
                switch event.payload {
                case .register(let reg):
                    print("Agent \(reg.agentID) registered for session \(reg.sessionID)")
                    activeSessionID = reg.sessionID
                    
                    await SessionManager.shared.registerAgent(sessionID: reg.sessionID, stream: responseStream)
                    
                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_RegistrationResponse()
                    resp.success = true
                    cmdMsg.registrationResponse = resp
                    try await responseStream.send(cmdMsg)
                    
                case .progress(let prog):
                    guard let sid = activeSessionID else { continue }
                    print("Progress from agent: \(prog.statusMessage)")
                    // Route to UI
                    var srvMsg = Pecan_ServerMessage()
                    var out = Pecan_AgentOutput()
                    out.sessionID = sid
                    out.text = prog.statusMessage
                    srvMsg.agentOutput = out
                    try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)
                    
                case .completionRequest(let req):
                    print("LLM Request from agent: \(req.requestID)")
                    // To be implemented: actually hit the LLM API here.
                    
                case .toolRequest(let req):
                    print("Tool Request from agent: \(req.toolName)")
                    
                case nil:
                    break
                }
            }
        } catch {
            print("Agent Stream error or disconnected: \(error)")
        }
        
        print("Agent Client disconnected.")
    }
}

func main() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    
    let server = try await Server.insecure(group: group)
        .withServiceProviders([ClientServiceProvider(), AgentServiceProvider()])
        .bind(host: "0.0.0.0", port: 3000)
        .get()
    
    print("Pecan Server started on port \(server.channel.localAddress?.port ?? 3000)")
    
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
