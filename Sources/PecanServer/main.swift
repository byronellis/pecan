import Foundation
import GRPC
import NIO
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.server")

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
            logger.warning("No UI stream found for session \(sessionID)")
        }
    }
    
    func sendToAgent(sessionID: String, command: Pecan_HostCommand) async throws {
        if let stream = agentStreams[sessionID] {
            try await stream.send(command)
        } else {
            logger.warning("No Agent stream found for session \(sessionID)")
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

    func getContext(sessionID: String) throws -> Data {
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
        return try JSONSerialization.data(withJSONObject: messages)
    }
    
    func compactContext(sessionID: String, section: Pecan_ContextSection, keepRecent: Int) {
        if let count = context[sessionID]?[section]?.count, count > keepRecent {
            let keep = Array(context[sessionID]![section]!.suffix(keepRecent))
            context[sessionID]![section] = keep
        }
    }
    
    func removeSession(sessionID: String) async {
        uiStreams.removeValue(forKey: sessionID)
        agentStreams.removeValue(forKey: sessionID)
        context.removeValue(forKey: sessionID)
        
        do {
            try await SpawnerFactory.shared.terminate(sessionID: sessionID)
        } catch {
            logger.error("Failed to terminate agent VM for session \(sessionID): \(error)")
        }
    }
}

final class ClientServiceProvider: Pecan_ClientServiceAsyncProvider {
    func streamEvents(
        requestStream: GRPCAsyncRequestStream<Pecan_ClientMessage>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        logger.info("UI Client connected.")
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
                    
                    // Spawn the agent using the Pluggable VM architecture
                    do {
                        try await SpawnerFactory.shared.spawn(sessionID: sessionID)
                    } catch {
                        logger.error("Failed to spawn agent: \(error)")
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sessionID
                        out.text = "System Error: Failed to spawn isolated agent VM. (\(error.localizedDescription))"
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                    }

                case .userInput(let req):
                    logger.debug("Routing user input to agent for session \(req.sessionID)")
                    var cmdMsg = Pecan_HostCommand()
                    var processInput = Pecan_ProcessInput()
                    processInput.text = req.text
                    cmdMsg.processInput = processInput
                    
                    try await SessionManager.shared.sendToAgent(sessionID: req.sessionID, command: cmdMsg)

                case .toolApproval(let req):
                    logger.info("Received tool approval: \(req.approved) for \(req.toolCallID)")
                case nil:
                    break
                }
            }
        } catch {
            logger.error("UI Stream error or disconnected: \(error)")
        }
        
        if let sid = activeSessionID {
            await SessionManager.shared.removeSession(sessionID: sid)
        }
        logger.info("UI Client disconnected.")
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
                    
                case .getModels(let req):
                    logger.debug("Agent requested models list.")
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
                    logger.info("LLM Request from agent: \(req.requestID) using model: \(modelKey)")
                    
                    if let modelConfig = config.models[modelKey] {
                        let provider = ProviderFactory.create(config: modelConfig)
                        do {
                            let contextData = try await SessionManager.shared.getContext(sessionID: sid)
                            var contextMessages: [[String: Any]] = []
                            if let decoded = try JSONSerialization.jsonObject(with: contextData) as? [[String: Any]] {
                                contextMessages = decoded
                            }
                            
                            var payload: [String: Any] = ["messages": contextMessages]
                            
                            // Tools are now injected by the agent directly via paramsJson
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
                            logger.error("Provider error: \(error)")
                            var cmdMsg = Pecan_HostCommand()
                            var compResp = Pecan_LLMCompletionResponse()
                            compResp.requestID = req.requestID
                            compResp.errorMessage = error.localizedDescription
                            cmdMsg.completionResponse = compResp
                            try await responseStream.send(cmdMsg)
                        }
                    } else {
                        logger.error("Error: No valid model configuration found for key \(modelKey).")
                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.errorMessage = "No valid model configuration found for key \(modelKey)."
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                    }
                    
                case .toolRequest(let req):
                    logger.info("Tool Request from agent: \(req.toolName)")
                    // Server-side tools to be implemented later if needed.
                    var cmdMsg = Pecan_HostCommand()
                    var toolResp = Pecan_ToolExecutionResponse()
                    toolResp.requestID = req.requestID
                    toolResp.errorMessage = "Server-side tools are not currently implemented. Agent should execute tools locally."
                    cmdMsg.toolResponse = toolResp
                    try await responseStream.send(cmdMsg)
                    
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

func main() async throws {

    let config = try Config.load()

    // Launch the vm-launcher subprocess and wait for it to be ready
    let launcher = try LauncherProcessManager()
    try launcher.waitForSocket()

    // Switch to container-based execution
    await SpawnerFactory.shared.useVirtualizationFramework(launcher: launcher)

    // Ensure launcher is terminated on exit
    defer {
        Task { await SpawnerFactory.shared.shutdownLauncher() }
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let providers = [ClientServiceProvider(), AgentServiceProvider(config: config)] as [CallHandlerProvider]

    // TCP server for UI clients
    let tcpServer = try await Server.insecure(group: group)
        .withServiceProviders(providers)
        .bind(host: "0.0.0.0", port: 3000)
        .get()

    // Unix socket server for containerized agents (relayed via vsock)
    let runDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".run")
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let socketPath = runDir.appendingPathComponent("grpc.sock").path
    // Remove stale socket file if it exists
    try? FileManager.default.removeItem(atPath: socketPath)

    let udsServer = try await Server.insecure(group: group)
        .withServiceProviders(providers)
        .bind(unixDomainSocketPath: socketPath)
        .get()

    logger.info("Pecan Server started on port \(tcpServer.channel.localAddress?.port ?? 3000) and Unix socket \(socketPath) with default model: \(config.defaultModel ?? "unknown")")

    // Handle SIGINT/SIGTERM for clean shutdown
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            Task {
                await SpawnerFactory.shared.shutdownLauncher()
            }
            exit(0)
        }
    }

    // Wait for either server to close
    try await tcpServer.onClose.get()
    try await udsServer.onClose.get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        logger.critical("Server error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
