import Foundation
import Logging
import PecanShared

/// Server-side client for querying the agent's overlay changeset.
/// Sends ChangesetCommand to the agent and correlates responses via request ID.
actor ChangesetClient {
    static let shared = ChangesetClient()

    private var pending: [String: CheckedContinuation<Pecan_ChangesetResponse, Error>] = [:]

    /// Send a changeset action to the given session's agent and await the response.
    func request(sessionID: String, action: String, path: String = "", patterns: [String] = []) async throws -> Pecan_ChangesetResponse {
        let requestID = UUID().uuidString

        var hostCmd = Pecan_HostCommand()
        var cmd = Pecan_ChangesetCommand()
        cmd.requestID = requestID
        cmd.action = action
        cmd.path = path
        cmd.patterns = patterns
        hostCmd.changesetCommand = cmd
        try await SessionManager.shared.sendToAgent(sessionID: sessionID, command: hostCmd)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
        }
    }

    /// Called by the agent event loop when a ChangesetResponse arrives.
    func handleResponse(_ response: Pecan_ChangesetResponse) {
        guard let continuation = pending.removeValue(forKey: response.requestID) else {
            logger.warning("ChangesetClient: no pending request for \(response.requestID)")
            return
        }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(
                domain: "ChangesetClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage]
            ))
        } else {
            continuation.resume(returning: response)
        }
    }
}
