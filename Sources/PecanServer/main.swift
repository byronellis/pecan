import Foundation
import GRPC
import NIO
import PecanShared

actor SessionManager {
    static let shared = SessionManager()
    
    // sessionID -> (uiStream, agentStream)
    private var uiStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>] = [:]
    private var agentStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>] = [:]
    
    // Context Storage
    // sessionID -> ContextSection -> [Message]
    struct ContextMessage {
        let role: String
        let content: String
        let metadataJson: String
    }
    private var context: [String: [Pecan_ContextSection: [ContextMessage]]] = [:]
    
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
    
    func addContextMessage(sessionID: String, section: Pecan_ContextSection, role: String, content: String, metadata: String) {
        if context[sessionID] == nil {
            context[sessionID] = [:]
        }
        if context[sessionID]![section] == nil {
            context[sessionID]![section] = []
        }
        context[sessionID]![section]!.append(ContextMessage(role: role, content: content, metadataJson: metadata))
    }

    func getContext(sessionID: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let sections: [Pecan_ContextSection] = [.system, .conversation, .tools]
        
        for section in sections {
            if let sectionMsgs = context[sessionID]?[section] {
                for msg in sectionMsgs {
                    var dict: [String: Any] = ["role": msg.role, "content": msg.content]
                    if !msg.metadataJson.isEmpty,
                       let data = msg.metadataJson.data(using: .utf8),
                       let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        for (k, v) in meta {
                            dict[k] = v
                        }
                    }
                    messages.append(dict)
                }
            }
        }
        return messages
    }
    
    func compactContext(sessionID: String, section: Pecan_ContextSection, keepRecent: Int) {
        if let count = context[sessionID]?[section]?.count, count > keepRecent {
            let keep = Array(context[sessionID]![section]!.suffix(keepRecent))
            context[sessionID]![section] = keep
        }
    }
    
    func removeSession(sessionID: String) {
        uiStreams.removeValue(forKey: sessionID)
        agentStreams.removeValue(forKey: sessionID)
        context.removeValue(forKey: sessionID)
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
    let config: Config
    
    init(config: Config) {
        self.config = config
    }
    
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
                    
                case .getModels(let req):
                    print("Agent requested models list.")
                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_GetModelsResponse()
                    resp.requestID = req.requestID
                    for (key, modelConfig) in config.models {
                        var info = Pecan_GetModelsResponse.ModelInfo()
                        info.key = key
                        info.name = modelConfig.name ?? key
                        info.description_p = modelConfig.description ?? "No description"
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
                    let modelKey = req.modelKey.isEmpty ? (config.defaultModel ?? config.models.keys.first ?? "") : req.modelKey
                    print("LLM Request from agent: \(req.requestID) using model: \(modelKey)")
                    
                    if let modelConfig = config.models[modelKey] {
                        let provider = ProviderFactory.create(config: modelConfig)
                        do {
                            let contextMessages = await SessionManager.shared.getContext(sessionID: sid)
                            var payload: [String: Any] = ["messages": contextMessages]
                            if !req.paramsJson.isEmpty {
                                if let data = req.paramsJson.data(using: .utf8),
                                   let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    for (k, v) in params {
                                        payload[k] = v
                                    }
                                }
                            }
                            let payloadData = try JSONSerialization.data(withJSONObject: payload)
                            let payloadString = String(data: payloadData, encoding: .utf8)!
                            
                            let responseString = try await provider.complete(payloadJSON: payloadString)
                            var cmdMsg = Pecan_HostCommand()
                            var compResp = Pecan_LLMCompletionResponse()
                            compResp.requestID = req.requestID
                            compResp.responseJson = responseString
                            cmdMsg.completionResponse = compResp
                            try await responseStream.send(cmdMsg)
                        } catch {
                            print("Provider error: \(error)")
                            var cmdMsg = Pecan_HostCommand()
                            var compResp = Pecan_LLMCompletionResponse()
                            compResp.requestID = req.requestID
                            compResp.errorMessage = error.localizedDescription
                            cmdMsg.completionResponse = compResp
                            try await responseStream.send(cmdMsg)
                        }
                    } else {
                        print("Error: No valid model configuration found for key \(modelKey).")
                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.errorMessage = "No valid model configuration found for key \(modelKey)."
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                    }
                    
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
    let config = try Config.load()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    
    let server = try await Server.insecure(group: group)
        .withServiceProviders([ClientServiceProvider(), AgentServiceProvider(config: config)])
        .bind(host: "0.0.0.0", port: 3000)
        .get()
    
    print("Pecan Server started on port \(server.channel.localAddress?.port ?? 3000) with default model: \(config.defaultModel ?? "unknown")")
    
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
