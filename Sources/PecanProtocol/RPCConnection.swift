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

/// Client side of a connection to the pecan server.
public actor RPCConnection {
    private var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextID = 1
    private var channelTask: Task<Void, Never>?

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

    public func call<M: RPCMethod>(
        _ method: M.Type,
        _ params: M.Params,
        timeout: Duration = .seconds(30)
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
            Task {
                try? await Task.sleep(for: timeout)
                self.fail(id, with: RPCConnectionError.timedOut(method: M.name))
            }
        }

        let response = try RPCCoding.decoder.decode(RPCResponse<M.Result>.self, from: reply)
        if let error = response.error { throw error }
        guard let result = response.result else { throw RPCConnectionError.emptyResult(method: M.name) }
        return result
    }

    private func receive(_ message: Data) {
        guard let header = try? RPCCoding.decoder.decode(RPCHeader.self, from: message),
              let id = header.id,
              let continuation = pending.removeValue(forKey: id)
        else { return }
        continuation.resume(returning: message)
    }

    private func fail(_ id: Int, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func didClose() {
        writer = nil
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
