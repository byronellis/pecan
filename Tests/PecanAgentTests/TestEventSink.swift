import Foundation
import PecanShared
import PecanAgentCore

/// An in-memory AgentEventSink that captures all outbound events.
/// Tests create a fresh instance, drive the handler, then inspect `sent`.
actor TestEventSink: AgentEventSink {
    private(set) var sent: [Pecan_AgentEvent] = []

    func send(_ msg: Pecan_AgentEvent) async throws {
        sent.append(msg)
    }

    func finish() {}

    /// Poll until at least `count` events are captured or the timeout elapses.
    func waitForEvents(count: Int, timeout: TimeInterval = 5.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sent.count >= count { return }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
        throw TestSinkError.timeout("Expected ≥\(count) events, got \(sent.count)")
    }

    enum TestSinkError: Error {
        case timeout(String)
    }
}

// MARK: - Convenience accessors

extension TestEventSink {
    /// Return all progress events whose JSON `type` field matches `value`.
    func progressEvents(type value: String) -> [Pecan_AgentEvent] {
        sent.filter { event in
            guard case .progress(let p) = event.payload,
                  let data = p.statusMessage.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return false }
            return dict["type"] == value
        }
    }

    /// Return all context-command events whose addMessage role matches.
    func contextMessages(role: String) -> [Pecan_AgentEvent] {
        sent.filter { event in
            guard case .contextCommand(let c) = event.payload else { return false }
            return c.addMessage.role == role
        }
    }

    /// Decode the progress status-message JSON of an event (must be a progress event).
    static func decodeProgressJSON(_ event: Pecan_AgentEvent) throws -> [String: String] {
        guard case .progress(let p) = event.payload,
              let data = p.statusMessage.data(using: .utf8) else {
            throw DecodingError.valueNotFound(String.self, .init(codingPath: [], debugDescription: "Not a progress event"))
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
