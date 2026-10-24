import Foundation
import NIOCore
import NIOPosix

public enum RPCConnectionError: Error, CustomStringConvertible {
    case closed
    case timedOut(method: String)
    case emptyResult(method: String)

    public var description: String {
        switch self {
        case .closed: "connection to the pecan server closed"
        case .timedOut(let method): "pecan server did not answer '\(method)' in time"
        case .emptyResult(let method): "pecan server sent no result for '\(method)'"
        }
    }
}

/// A notification from the server: its method name and the full message, for decoding with
/// `decode(_:)` once the method is known.
public struct InboundNotification: Sendable {
    public var method: String
    public var message: Data

    public func decode<N: RPCNotificationMethod>(_ type: N.Type) throws -> N.Params {
        try RPCCoding.decoder.decode(RPCNotification<N.Params>.self, from: message).params
    }
}

/// Client side of a connection to the pecan server.
public actor RPCConnection {
    private var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextID = 1
    private var channelTask: Task<Void, Never>?
    private let notificationSink: AsyncStream<InboundNotification>.Continuation

    /// Server notifications, in arrival order. Finishes when the connection closes.
    public nonisolated let notifications: AsyncStream<InboundNotification>

    private init() {
        (notifications, notificationSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public static func open(socketPath: String) async throws -> RPCConnection {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(unixDomainSocketPath: socketPath, channelInitializer: RPCChannel.configure)
        let connection = RPCConnection()
        await connection.start(channel)
        return connection
    }

    /// Runs the channel for the life of the connection and returns once it can send.
    private func start(_ channel: RPCChannel.Async) async {
        let (ready, signalReady) = AsyncStream<Void>.makeStream()
        channelTask = Task {
            do {
                try await channel.executeThenClose { inbound, outbound in
                    self.attach(outbound)
                    signalReady.finish()
                    for try await line in inbound {
                        self.receive(Data(line.readableBytesView))
                    }
                }
            } catch {
                // Surfaces to callers as `.closed` on their pending requests.
            }
            signalReady.finish()
            self.didClose()
        }
        for await _ in ready {}
    }

    private func attach(_ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        writer = outbound
    }

    /// Sends a request and waits for its reply. A nil `timeout` waits as long as the call takes,
    /// for requests such as `SendMessage` that last a whole model turn.
    public func call<M: RPCMethod>(
        _ method: M.Type,
        _ params: M.Params,
        timeout: Duration? = .seconds(30)
    ) async throws -> M.Result {
        guard let writer else { throw RPCConnectionError.closed }
        let id = nextID
        nextID += 1
        let request = try RPCCoding.encoder.encode(RPCRequest(id: id, method: M.name, params: params))

        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await writer.write(RPCChannel.frame(request))
                } catch {
                    self.fail(id, with: error)
                }
            }
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    self.fail(id, with: RPCConnectionError.timedOut(method: M.name))
                }
            }
        }

        let response = try RPCCoding.decoder.decode(RPCResponse<M.Result>.self, from: reply)
        if let error = response.error { throw error }
        guard let result = response.result else { throw RPCConnectionError.emptyResult(method: M.name) }
        return result
    }

    private func receive(_ message: Data) {
        guard let header = try? RPCCoding.decoder.decode(RPCHeader.self, from: message) else { return }
        if let id = header.id {
            pending.removeValue(forKey: id)?.resume(returning: message)
        } else if let method = header.method {
            notificationSink.yield(InboundNotification(method: method, message: message))
        }
    }

    private func fail(_ id: Int, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func didClose() {
        writer = nil
        notificationSink.finish()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: RPCConnectionError.closed)
        }
    }

    /// Closes the connection and waits for the channel to shut down.
    public func close() async {
        writer?.finish()
        await channelTask?.value
    }
}
