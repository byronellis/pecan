import Foundation
import GRPC
import NIO
import PecanShared
import PecanServerCore
import Logging

let logger = Logger(label: "com.pecan.server")


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

    // Launch MLX server if any models use the mlx provider
    let hasMLXModels = config.models.values.contains { $0.resolvedProvider.lowercased() == "mlx" }
    if hasMLXModels {
        do {
            let mlxManager = try MLXProcessManager()
            try mlxManager.waitForSocket()
            ProviderFactory.mlxManager = mlxManager

            // Preload configured MLX models
            for (alias, modelConfig) in config.models where modelConfig.resolvedProvider.lowercased() == "mlx" {
                if let repo = modelConfig.huggingfaceRepo {
                    logger.info("Preloading MLX model '\(alias)' from \(repo)")
                    var req = Pecan_MLXRequest()
                    var loadReq = Pecan_MLXLoadModelRequest()
                    loadReq.alias = alias
                    loadReq.huggingfaceRepo = repo
                    loadReq.requestID = UUID().uuidString
                    req.loadModel = loadReq
                    let resp = try mlxManager.sendRequest(req, timeout: 300)
                    if case .error(let err) = resp.payload {
                        logger.error("Failed to preload MLX model '\(alias)': \(err.errorMessage)")
                    } else {
                        logger.info("MLX model '\(alias)' preloaded successfully")
                    }
                }
            }
        } catch {
            logger.error("Failed to start MLX server: \(error). MLX models will be unavailable.")
        }
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let providers = [ClientServiceProvider(), AgentServiceProvider(config: config)] as [CallHandlerProvider]

    // TCP server for UI clients — bind port 0 so the OS picks a free port
    let tcpServer = try await Server.insecure(group: group)
        .withServiceProviders(providers)
        .bind(host: "127.0.0.1", port: 0)
        .get()

    let boundPort = tcpServer.channel.localAddress?.port ?? 0
    guard boundPort > 0 else {
        logger.critical("Failed to determine bound port")
        exit(1)
    }

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

    // Write server status file so clients can discover the port and PID
    let status = ServerStatus(
        pid: ProcessInfo.processInfo.processIdentifier,
        port: boundPort,
        grpcSocketPath: socketPath
    )
    try status.write()

    logger.info("Pecan Server started on port \(boundPort) and Unix socket \(socketPath) with default model: \(config.defaultModel ?? "unknown")")

    // Ensure skills directory exists and populate built-in skills
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let skillsDir = homeDir.appendingPathComponent(".pecan/skills")
    try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    ensureBuiltinSkills(skillsDir: skillsDir.path)

    // Respawn persistent sessions from previous server run
    Task { await respawnPersistentSessions(config: config) }

    // Background trigger timer: check for due triggers every 10 seconds
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            let sessionIDs = await SessionManager.shared.activeSessionIDs()
            for sid in sessionIDs {
                await SessionManager.shared.checkAndDeliverTriggers(sessionID: sid)
            }
        }
    }

    // Handle SIGINT/SIGTERM for clean shutdown
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            ServerStatus.remove()
            Task {
                await SpawnerFactory.shared.shutdownLauncher()
            }
            ProviderFactory.mlxManager?.shutdown()
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
