import Foundation
import Logging
import PecanSettings

private let mainLogger = Logger(label: "com.pecan.server.main")

func main() async throws {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = .info
        return handler
    }

    mainLogger.info("Starting Pecan LLM Proxy Server...")

    // Trigger config loading/creation at startup
    let config = ProxyConfig.load()
    let defaultModel = config.defaultModel ?? "none"
    mainLogger.info("Config loaded (default model: \(defaultModel))")

    // Start HTTP Proxy Server on a free port (port 0) or port 3000
    // Let's bind to 0 to dynamically assign a port, or 3000. Bind to 3000 by default, fallback to 0 if busy.
    var port = 3000
    let server = HTTPProxyServer(host: "127.0.0.1", port: port)
    
    let boundPort: Int
    do {
        boundPort = try await server.start()
    } catch {
        mainLogger.warning("Port 3000 busy, binding to dynamic port...")
        let dynamicServer = HTTPProxyServer(host: "127.0.0.1", port: 0)
        boundPort = try await dynamicServer.start()
    }

    // Write server status file so TUI and clients can auto-discover it
    let status = ServerStatus(
        pid: ProcessInfo.processInfo.processIdentifier,
        port: boundPort,
        grpcSocketPath: ""
    )
    do {
        let runDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try status.write()
        mainLogger.info("Server status written to \(ServerStatus.statusFilePath)")
    } catch {
        mainLogger.error("Failed to write server status: \(error)")
    }

    // Handle shutdown signals
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            ServerStatus.remove()
            mainLogger.info("Shutting down...")
            exit(0)
        }
    }

    // Keep server running
    while true {
        try await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
    }
}

Task {
    do {
        try await main()
    } catch {
        mainLogger.critical("Server main crash: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
