import Foundation
import PecanSettings

/// Finds, starts, and upgrades the resident pecan server for this build's channel.
///
/// There is no separate daemon binary: the server is this same executable running `server run`.
/// A client that is newer than the running server stops it and starts its own build in its place.
public enum ServerConnector {
    public enum ConnectError: Error, CustomStringConvertible {
        case notRunning
        case incompatible(server: BuildInfo, serverProtocol: Int)
        case startTimedOut
        case stopTimedOut
        case socketPathTooLong(String)

        public var description: String {
            switch self {
            case .socketPathTooLong(let path):
                "socket path \(path) exceeds the \(maxSocketPathLength - 1)-byte unix socket limit; use a shorter PECAN_HOME"
            case .notRunning:
                "no pecan server is running"
            case .incompatible(let server, let serverProtocol):
                "the running pecan server \(server) speaks protocol \(serverProtocol) but this client speaks "
                    + "\(pecanProtocolVersion); update this client or run `pecan server stop`"
            case .startTimedOut:
                "pecan server did not start; see \(PecanPaths.logPath)"
            case .stopTimedOut:
                "pecan server did not exit; see \(PecanPaths.logPath)"
            }
        }
    }

    public struct Connection: Sendable {
        public let rpc: RPCConnection
        public let server: Hello.Result
    }

    private static let pollInterval: Duration = .milliseconds(100)
    private static let startTimeout: Duration = .seconds(10)
    private static let stopTimeout: Duration = .seconds(10)
    /// `sockaddr_un.sun_path`, including the terminating NUL.
    static let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Connects to this channel's server.
    ///
    /// With `autoStart`, starts a server if none is running and replaces one this build supersedes.
    /// Without it, connects only to whatever is already running.
    public static func connect(autoStart: Bool = true) async throws -> Connection {
        guard PecanPaths.socketPath.utf8.count < maxSocketPathLength else {
            throw ConnectError.socketPathTooLong(PecanPaths.socketPath)
        }
        if let existing = try? await handshake() {
            if autoStart && BuildInfo.current.supersedes(existing.server.build) {
                try await shutdown(existing.rpc, reason: .upgrade)
            } else {
                return try await checkCompatible(existing)
            }
        } else if !autoStart {
            throw ConnectError.notRunning
        }

        try PecanPaths.ensureRunDirectory()
        try ServerProcess.spawn()
        let clock = ContinuousClock()
        let deadline = clock.now + startTimeout
        while clock.now < deadline {
            if let started = try? await handshake() {
                return try await checkCompatible(started)
            }
            try await Task.sleep(for: pollInterval)
        }
        throw ConnectError.startTimedOut
    }

    /// Stops the running server. Returns false if none was running.
    public static func stop() async throws -> Bool {
        guard let existing = try? await handshake() else { return false }
        try await shutdown(existing.rpc, reason: .stop)
        return true
    }

    private static func handshake() async throws -> Connection {
        let rpc = try await RPCConnection.open(socketPath: PecanPaths.socketPath)
        do {
            let server = try await rpc.call(
                Hello.self,
                .init(build: .current, protocolVersion: pecanProtocolVersion),
                timeout: .seconds(5)
            )
            return Connection(rpc: rpc, server: server)
        } catch {
            await rpc.close()
            throw error
        }
    }

    private static func checkCompatible(_ connection: Connection) async throws -> Connection {
        guard connection.server.protocolVersion == pecanProtocolVersion else {
            await connection.rpc.close()
            throw ConnectError.incompatible(
                server: connection.server.build,
                serverProtocol: connection.server.protocolVersion
            )
        }
        return connection
    }

    /// Asks the server to exit and waits until it has released its lock.
    private static func shutdown(_ rpc: RPCConnection, reason: Shutdown.Reason) async throws {
        do {
            _ = try await rpc.call(Shutdown.self, .init(reason: reason), timeout: .seconds(5))
        } catch RPCConnectionError.closed {
            // The server may exit before its reply is flushed.
        }
        await rpc.close()

        let clock = ContinuousClock()
        let deadline = clock.now + stopTimeout
        while ServerLock.isHeld(at: PecanPaths.lockPath) {
            guard clock.now < deadline else { throw ConnectError.stopTimedOut }
            try await Task.sleep(for: pollInterval)
        }
    }
}
