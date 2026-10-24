import Foundation
import Logging
import NIOCore
import NIOPosix
import PecanProtocol
import PecanSettings
import Synchronization

private let logger = Logger(label: "com.pecan.server.host")

/// The resident pecan server: holds the channel's single-instance lock and serves the client
/// protocol on its unix socket until stopped or replaced by a newer build.
public actor PecanServerHost {
    private let lock: ServerLock
    private let startedAt = Date()
    private var connectedClients = 0
    private var signalSources: [any DispatchSourceSignal] = []
    private let sessions = SessionManager()

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

    private func handle(_ channel: RPCChannel.Async) async {
        connectedClients += 1
        let client = ClientConnection()
        do {
            try await channel.executeThenClose { inbound, outbound in
                client.attach(outbound)
                // Each request runs in its own task: a turn lasts as long as the model takes, and
                // the client must still be able to cancel it meanwhile.
                try await withThrowingDiscardingTaskGroup { group in
                    for try await line in inbound {
                        let message = Data(line.readableBytesView)
                        group.addTask { await self.process(message, from: client) }
                    }
                    // The client hung up; nobody is left to read the answers.
                    group.cancelAll()
                }
            }
        } catch {
            logger.debug("client connection ended: \(error)")
        }
        await sessions.closeAll(ownedBy: client.id)
        connectedClients -= 1
    }

    private func process(_ message: Data, from client: ClientConnection) async {
        let header: RPCHeader
        do {
            header = try RPCCoding.decoder.decode(RPCHeader.self, from: message)
        } catch {
            await client.send(errorReply(id: nil, code: RPCError.parseError, "invalid JSON"))
            return
        }
        guard let id = header.id, let method = header.method else {
            // A notification needs no reply; the server doesn't accept any yet.
            if header.id != nil {
                await client.send(errorReply(id: header.id, code: RPCError.invalidRequest, "missing method"))
            }
            return
        }

        var shutdownReason: Shutdown.Reason?
        let reply: Data
        do {
            switch method {
            case Hello.name:
                let params = try decodeParams(Hello.self, from: message)
                logger.info("client \(params.build) connected (protocol \(params.protocolVersion))")
                reply = try self.reply(id: id, Hello.Result(
                    build: .current, protocolVersion: pecanProtocolVersion, pid: getpid()))

            case GetStatus.name:
                reply = try self.reply(id: id, GetStatus.Result(
                    build: .current, pid: getpid(), startedAt: startedAt, connectedClients: connectedClients))

            case Shutdown.name:
                shutdownReason = try decodeParams(Shutdown.self, from: message).reason
                reply = try self.reply(id: id, Empty())

            case ListModels.name:
                reply = try self.reply(id: id, await ModelCatalog.list())

            case OpenSession.name:
                let params = try decodeParams(OpenSession.self, from: message)
                reply = try self.reply(id: id, try await sessions.open(params, owner: client.id))

            case ForkSession.name:
                let params = try decodeParams(ForkSession.self, from: message)
                reply = try self.reply(id: id, try await sessions.fork(params, owner: client.id))

            case SendMessage.name:
                let params = try decodeParams(SendMessage.self, from: message)
                let session = try await sessions.session(params.sessionID)
                let result = try await session.send(params.text) { event in
                    await client.notify(SessionEvent.self, .init(sessionID: params.sessionID, event: event))
                }
                reply = try self.reply(id: id, result)

            case SetSessionModel.name:
                let params = try decodeParams(SetSessionModel.self, from: message)
                reply = try self.reply(id: id, try await sessions.setModel(params))

            case CancelTurn.name:
                let params = try decodeParams(CancelTurn.self, from: message)
                try await sessions.session(params.sessionID).cancel()
                reply = try self.reply(id: id, Empty())

            default:
                reply = errorReply(id: id, code: RPCError.methodNotFound, "unknown method '\(method)'")
            }
        } catch let error as RPCError {
            reply = errorReply(id: id, code: error.code, error.message)
        } catch is DecodingError {
            reply = errorReply(id: id, code: RPCError.invalidParams, "invalid params for '\(method)'")
        } catch {
            reply = errorReply(id: id, code: RPCError.internalError, "\(error)")
        }

        await client.send(reply)
        if let shutdownReason {
            shutdown(reason: shutdownReason)
        }
    }

    private nonisolated func decodeParams<M: RPCMethod>(_ method: M.Type, from message: Data) throws -> M.Params {
        try RPCCoding.decoder.decode(RPCRequest<M.Params>.self, from: message).params
    }

    private nonisolated func reply<Result: Codable & Sendable>(id: Int, _ result: Result) throws -> Data {
        try RPCCoding.encoder.encode(RPCResponse(id: id, result: result))
    }

    private nonisolated func errorReply(id: Int?, code: Int, _ message: String) -> Data {
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

/// The server's side of one client connection.
private final class ClientConnection: Sendable {
    let id = UUID()
    private let writer = Mutex<NIOAsyncChannelOutboundWriter<ByteBuffer>?>(nil)

    func attach(_ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        writer.withLock { $0 = outbound }
    }

    /// Sends one message. A client that has gone away just misses it.
    func send(_ message: Data) async {
        guard let outbound = writer.withLock({ $0 }) else { return }
        try? await outbound.write(RPCChannel.frame(message))
    }

    func notify<N: RPCNotificationMethod>(_ type: N.Type, _ params: N.Params) async {
        guard let message = try? RPCCoding.encoder.encode(RPCNotification(method: N.name, params: params)) else { return }
        await send(message)
    }
}
