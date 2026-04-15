import Foundation
import PecanShared

public actor TaskClient {
    public static let shared = TaskClient()

    private var pendingRequests: [String: CheckedContinuation<String, Error>] = [:]
    private var sendCallback: (@Sendable (Pecan_AgentEvent) async throws -> Void)?

    public func configure(send: @escaping @Sendable (Pecan_AgentEvent) async throws -> Void) {
        self.sendCallback = send
    }

    public func handleResponse(_ response: Pecan_TaskResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(domain: "TaskClient", code: 1, userInfo: [NSLocalizedDescriptionKey: response.errorMessage]))
        } else {
            continuation.resume(returning: response.resultJson)
        }
    }

    public func sendCommand(action: String, payload: [String: Any], scope: String = "") async throws -> String {
        guard let send = sendCallback else {
            throw NSError(domain: "TaskClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "TaskClient not configured"])
        }
        let requestID = UUID().uuidString
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"

        var msg = Pecan_AgentEvent()
        var cmd = Pecan_TaskCommand()
        cmd.requestID = requestID
        cmd.action = action
        cmd.payloadJson = payloadJSON
        cmd.scope = scope
        msg.taskCommand = cmd

        // Send the message first, then wait for the response
        try await send(msg)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }
}
