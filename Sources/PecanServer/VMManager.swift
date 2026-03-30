import Foundation
import PecanShared
import Logging

/// Mount specification passed through to the VM launcher.
public struct MountSpec: Codable, Sendable {
    public let source: String
    public let destination: String
    public let readOnly: Bool

    public init(source: String, destination: String, readOnly: Bool = true) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

public protocol AgentSpawner: Sendable {
    func spawnAgent(sessionID: String, agentName: String, workspacePath: String, shares: [MountSpec], networkEnabled: Bool, envMountPath: String) async throws
    func terminateAgent(sessionID: String) async throws
    func saveEnvironment(sessionID: String, outputPath: String) async throws
}

/// A spawner that just runs the agent as a local subprocess. Useful for development.
public actor LocalProcessSpawner: AgentSpawner {
    private var processes: [String: Process] = [:]

    public init() {}

    public func saveEnvironment(sessionID: String, outputPath: String) async throws {
        logger.info("LocalProcessSpawner: saveEnvironment is a no-op for local processes")
    }

    public func spawnAgent(sessionID: String, agentName: String, workspacePath: String, shares: [MountSpec], networkEnabled: Bool = false, envMountPath: String = "") async throws {
        logger.info("Spawning local agent process for session \(sessionID)...")
        let task = Process()
        let currentPath = FileManager.default.currentDirectoryPath
        task.executableURL = URL(fileURLWithPath: "\(currentPath)/.build/debug/pecan-agent")
        task.arguments = [sessionID]

        // Inherit standard output so we can see it in the server logs
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError

        try task.run()
        processes[sessionID] = task
    }

    public func terminateAgent(sessionID: String) async throws {
        if let task = processes[sessionID] {
            task.terminate()
            processes.removeValue(forKey: sessionID)
            logger.info("Terminated local agent for session \(sessionID)")
        }
    }
}

/// Manages the pecan-vm-launcher child process lifecycle.
public final class LauncherProcessManager: Sendable {
    private let process: Process
    private let socketPath: String

    /// Spawns the vm-launcher as a child process and waits for its socket to appear.
    public init() throws {
        let currentPath = FileManager.default.currentDirectoryPath
        socketPath = "\(currentPath)/.run/launcher.sock"

        // Resolve launcher binary: sibling of the running server binary, fallback to .build/debug/
        let serverBinary = CommandLine.arguments[0]
        let serverDir = (serverBinary as NSString).deletingLastPathComponent
        var launcherPath = "\(serverDir)/pecan-vm-launcher"
        if !FileManager.default.isExecutableFile(atPath: launcherPath) {
            launcherPath = "\(currentPath)/.build/debug/pecan-vm-launcher"
        }

        guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
            throw LauncherError.binaryNotFound(launcherPath)
        }

        // Remove stale socket before launching
        try? FileManager.default.removeItem(atPath: socketPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcherPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: currentPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        proc.terminationHandler = { p in
            logger.error("pecan-vm-launcher exited unexpectedly (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-vm-launcher (pid \(proc.processIdentifier)) from \(launcherPath)")
        self.process = proc
    }

    /// Waits for the launcher Unix socket to appear, polling briefly.
    public func waitForSocket(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                logger.info("Launcher socket ready at \(socketPath)")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LauncherError.socketTimeout(socketPath)
    }

    /// Terminates the launcher process.
    public func shutdown() {
        guard process.isRunning else { return }
        logger.info("Terminating pecan-vm-launcher (pid \(process.processIdentifier))")
        process.terminate()
        process.waitUntilExit()
    }

    public enum LauncherError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case socketTimeout(String)

        public var description: String {
            switch self {
            case .binaryNotFound(let path): return "Launcher binary not found at \(path)"
            case .socketTimeout(let path): return "Timed out waiting for launcher socket at \(path)"
            }
        }
    }
}

/// A factory to determine which spawner to use.
public actor SpawnerFactory {
    public static let shared = SpawnerFactory()

    public var activeSpawner: AgentSpawner = LocalProcessSpawner()
    private var launcherManager: LauncherProcessManager?

    public func useVirtualizationFramework(launcher: LauncherProcessManager) {
        self.launcherManager = launcher
        let currentPath = FileManager.default.currentDirectoryPath
        let socketPath = "\(currentPath)/.run/launcher.sock"
        activeSpawner = RemoteSpawner(socketPath: socketPath)
    }

    public func shutdownLauncher() {
        launcherManager?.shutdown()
        launcherManager = nil
    }

    public func spawn(sessionID: String, agentName: String, workspacePath: String, shares: [MountSpec] = [], networkEnabled: Bool = false, envMountPath: String = "") async throws {
        try await activeSpawner.spawnAgent(sessionID: sessionID, agentName: agentName, workspacePath: workspacePath, shares: shares, networkEnabled: networkEnabled, envMountPath: envMountPath)
    }

    public func saveEnvironment(sessionID: String, outputPath: String) async throws {
        try await activeSpawner.saveEnvironment(sessionID: sessionID, outputPath: outputPath)
    }

    public func terminate(sessionID: String) async throws {
        try await activeSpawner.terminateAgent(sessionID: sessionID)
    }
}
