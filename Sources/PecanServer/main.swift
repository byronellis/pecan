import Foundation
import GRPC
import NIO
import PecanShared
import PecanServerCore
import PecanSettings
import Logging

let logger = Logger(label: "com.pecan.server")


func main() async throws {

    // Open the settings store (migrates from config.yaml automatically if present)
    try await SettingsStore.shared.open()

    // Launch the vm-launcher subprocess and wait for it to be ready
    let launcher = try LauncherProcessManager()
    try launcher.waitForSocket()

    // Switch to container-based execution
    await SpawnerFactory.shared.useVirtualizationFramework(launcher: launcher)

    // Ensure launcher is terminated on exit
    defer {
        Task { await SpawnerFactory.shared.shutdownLauncher() }
    }

    // Launch MLX server if any providers use the mlx type
    let mlxProviders = (try? await SettingsStore.shared.allProviders().filter {
        $0.type.lowercased() == "mlx" && $0.enabled
    }) ?? []
    if !mlxProviders.isEmpty {
        do {
            let mlxManager = try MLXProcessManager()
            try mlxManager.waitForSocket()
            ProviderFactory.mlxManager = mlxManager

            for p in mlxProviders {
                if let repo = p.huggingfaceRepo {
                    logger.info("Preloading MLX model '\(p.id)' from \(repo)")
                    var req = Pecan_MLXRequest()
                    var loadReq = Pecan_MLXLoadModelRequest()
                    loadReq.alias = p.id
                    loadReq.huggingfaceRepo = repo
                    loadReq.requestID = UUID().uuidString
                    req.loadModel = loadReq
                    let resp = try mlxManager.sendRequest(req, timeout: 300)
                    if case .error(let err) = resp.payload {
                        logger.error("Failed to preload MLX model '\(p.id)': \(err.errorMessage)")
                    } else {
                        logger.info("MLX model '\(p.id)' preloaded successfully")
                    }
                }
            }
        } catch {
            logger.error("Failed to start MLX server: \(error). MLX models will be unavailable.")
        }
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let providers = [ClientServiceProvider(), AgentServiceProvider()] as [CallHandlerProvider]

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

    let defaultModel = (try? await SettingsStore.shared.globalDefault()) ?? "unknown"
    logger.info("Pecan Server started on port \(boundPort) and Unix socket \(socketPath) with default model: \(defaultModel)")

    // Ensure skills directory exists and populate built-in skills
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let skillsDir = homeDir.appendingPathComponent(".pecan/skills")
    try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    ensureBuiltinSkills(skillsDir: skillsDir.path)

    // Respawn persistent sessions from previous server run
    Task { await respawnPersistentSessions() }

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
