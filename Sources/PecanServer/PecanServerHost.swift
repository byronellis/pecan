import Foundation
import Logging
import NIOCore
import NIOPosix
import PecanProtocol
import PecanSettings

private let logger = Logger(label: "com.pecan.server.host")

/// The resident pecan server: holds the channel's single-instance lock and serves the client
/// protocol on its unix socket until stopped or replaced by a newer build.
public actor PecanServerHost {
    private let lock: ServerLock
    private let startedAt = Date()
    private var connectedClients = 0
    private var signalSources: [any DispatchSourceSignal] = []

    private init(lock: ServerLock) {
        self.lock = lock
    }

    /// Runs the server in the foreground. Returns immediately if another server already holds the lock.
    public static func run() async throws {
        try PecanPaths.ensureRunDirectory()
        guard let lock = try await acquireLock() else {
            logger.notice("another pecan server holds \(PecanPaths.lockPath); exiting")
            return
        }
        try await PecanServerHost(lock: lock).serve()
    }

    /// Retries briefly: a client checking whether an old server has exited holds the lock for an
    /// instant, which must not make a freshly started server give up.
    private static func acquireLock() async throws -> ServerLock? {
        for _ in 0..<10 {
            if let lock = try ServerLock.acquire(at: PecanPaths.lockPath) { return lock }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func serve() async throws {
        let socketPath = PecanPaths.socketPath
        // Holding the lock means no live server owns an existing socket file, so it is stale.
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true,
                  childChannelInitializer: RPCChannel.configure)
        chmod(socketPath, 0o600)
        signalSources = makeSignalSources()
        logger.info("pecan server \(BuildInfo.current) listening on \(socketPath) (pid \(getpid()))")

        try await listener.executeThenClose { clients in
            try await withThrowingDiscardingTaskGroup { group in
                for try await client in clients {
                    group.addTask { await self.handle(client) }
                }
            }
        }
    }

    private func handle(_ client: RPCChannel.Async) async {
        connectedClients += 1
        defer { connectedClients -= 1 }
        do {
            try await client.executeThenClose { inbound, outbound in
                for try await line in inbound {
                    let (reply, shutdownReason) = self.respond(to: Data(line.readableBytesView))
                    try await outbound.write(RPCChannel.frame(reply))
                    if let shutdownReason {
                        self.shutdown(reason: shutdownReason)
                    }
                }
            }
        } catch {
            logger.debug("client connection ended: \(error)")
        }
    }

    private func respond(to message: Data) -> (reply: Data, shutdown: Shutdown.Reason?) {
        let header: RPCHeader
        do {
            header = try RPCCoding.decoder.decode(RPCHeader.self, from: message)
        } catch {
            return (errorReply(id: nil, code: RPCError.parseError, "invalid JSON"), nil)
        }
        guard let id = header.id, let method = header.method else {
            return (errorReply(id: header.id, code: RPCError.invalidRequest, "missing id or method"), nil)
        }

        do {
            switch method {
            case Hello.name:
                let params = try decodeParams(Hello.self, from: message)
                logger.info("client \(params.build) connected (protocol \(params.protocolVersion))")
                return (try reply(id: id, Hello.Result(
                    build: .current, protocolVersion: pecanProtocolVersion, pid: getpid())), nil)

            case GetStatus.name:
                return (try reply(id: id, GetStatus.Result(
                    build: .current, pid: getpid(), startedAt: startedAt, connectedClients: connectedClients)), nil)

            case Shutdown.name:
                let params = try decodeParams(Shutdown.self, from: message)
                return (try reply(id: id, Empty()), params.reason)

            default:
                return (errorReply(id: id, code: RPCError.methodNotFound, "unknown method '\(method)'"), nil)
            }
        } catch is DecodingError {
            return (errorReply(id: id, code: RPCError.invalidParams, "invalid params for '\(method)'"), nil)
        } catch {
            return (errorReply(id: id, code: RPCError.internalError, "\(error)"), nil)
        }
    }

    private func decodeParams<M: RPCMethod>(_ method: M.Type, from message: Data) throws -> M.Params {
        try RPCCoding.decoder.decode(RPCRequest<M.Params>.self, from: message).params
    }

    private func reply<Result: Codable & Sendable>(id: Int, _ result: Result) throws -> Data {
        try RPCCoding.encoder.encode(RPCResponse(id: id, result: result))
    }

    private func errorReply(id: Int?, code: Int, _ message: String) -> Data {
        let response = RPCResponse<Empty>(id: id, error: RPCError(code: code, message: message))
        return (try? RPCCoding.encoder.encode(response)) ?? Data()
    }

    /// Nonisolated so the handlers are too: Dispatch calls them on its own queue, off the actor.
    private nonisolated func makeSignalSources() -> [any DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber)
            source.setEventHandler { Task { await self.shutdown(reason: .stop) } }
            source.resume()
            return source
        }
    }

    /// Exits the process. Session state is persisted as it changes, so the only work lost is an
    /// in-flight turn; once sessions exist they are recorded here as interrupted before exiting.
    private func shutdown(reason: Shutdown.Reason) -> Never {
        logger.info("shutting down (\(reason.rawValue))")
        unlink(PecanPaths.socketPath)
        lock.release()
        exit(0)
    }
}
