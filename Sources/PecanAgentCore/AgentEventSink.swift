import Foundation
import PecanShared

/// A sink that accepts outbound agent events. Implemented by StreamWriter (gRPC) and
/// TestEventSink (tests). All conforming types are actors.
public protocol AgentEventSink: Actor {
    func send(_ msg: Pecan_AgentEvent) async throws
    func finish()
}
