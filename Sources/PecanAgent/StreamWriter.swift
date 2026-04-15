import Foundation
import GRPC
import PecanShared
import PecanAgentCore

// MARK: - StreamWriter

/// Serializes all writes to the gRPC request stream to prevent concurrent send crashes.
public actor StreamWriter: AgentEventSink {
    private let stream: GRPCAsyncRequestStreamWriter<Pecan_AgentEvent>

    public init(_ stream: GRPCAsyncRequestStreamWriter<Pecan_AgentEvent>) {
        self.stream = stream
    }

    public func send(_ msg: Pecan_AgentEvent) async throws {
        try await stream.send(msg)
    }

    public func finish() {
        stream.finish()
    }
}
