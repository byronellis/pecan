import Foundation
import PecanShared
import Logging

public protocol AgentSpawner: Sendable {
    func spawnAgent(sessionID: String) async throws
    func terminateAgent(sessionID: String) async throws
}

/// A spawner that just runs the agent as a local subprocess. Useful for development.
public actor LocalProcessSpawner: AgentSpawner {
    private var processes: [String: Process] = [:]

    public init() {}

    public func spawnAgent(sessionID: String) async throws {
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

/// A factory to determine which spawner to use.
public actor SpawnerFactory {
    public static let shared = SpawnerFactory()

    public var activeSpawner: AgentSpawner = LocalProcessSpawner()

    public func useVirtualizationFramework() {
        let currentPath = FileManager.default.currentDirectoryPath
        let socketPath = "\(currentPath)/.run/launcher.sock"
        activeSpawner = RemoteSpawner(socketPath: socketPath)
    }

    public func spawn(sessionID: String) async throws {
        try await activeSpawner.spawnAgent(sessionID: sessionID)
    }

    public func terminate(sessionID: String) async throws {
        try await activeSpawner.terminateAgent(sessionID: sessionID)
    }
}
