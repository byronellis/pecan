import Foundation
import NIOCore

/// Newline-delimited JSON over a unix socket: one message per line.
public enum RPCChannel {
    public typealias Async = NIOAsyncChannel<ByteBuffer, ByteBuffer>

    /// Installs framing and wraps a freshly connected or accepted channel for async use.
    @Sendable
    public static func configure(_ channel: any Channel) -> EventLoopFuture<Async> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineFrameDecoder()))
            // Half-closure lets finishing the writer send EOF, which is how either side ends a connection.
            return try Async(
                wrappingChannelSynchronously: channel,
                configuration: .init(isOutboundHalfClosureEnabled: true))
        }
    }

    public static func frame(_ message: Data) -> ByteBuffer {
        var buffer = ByteBuffer(bytes: message)
        buffer.writeInteger(UInt8(ascii: "\n"))
        return buffer
    }
}

/// Splits inbound bytes into lines, dropping the newline.
struct NewlineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
        let line = buffer.readSlice(length: view.distance(from: view.startIndex, to: newline))!
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}
