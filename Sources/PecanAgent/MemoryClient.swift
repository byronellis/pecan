import Foundation
import PecanShared

/// gRPC client for memory operations. The server handles DB reads/writes;
/// this actor sends MemoryCommand requests and routes MemoryResponse replies.
actor MemoryClient {
    static let shared = MemoryClient()

    private var pendingRequests: [String: CheckedContinuation<Pecan_MemoryResponse, Error>] = [:]
    private var sendCallback: (@Sendable (Pecan_AgentEvent) async throws -> Void)?

    func configure(send: @escaping @Sendable (Pecan_AgentEvent) async throws -> Void) {
        self.sendCallback = send
    }

    func handleResponse(_ response: Pecan_MemoryResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(
                domain: "MemoryClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage]))
        } else {
            continuation.resume(returning: response)
        }
    }

    private func sendCommand(
        action: String, scope: String,
        tag: String = "", content: String = "", newTag: String = ""
    ) async throws -> Pecan_MemoryResponse {
        guard let send = sendCallback else {
            throw NSError(domain: "MemoryClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "MemoryClient not configured"])
        }
        let requestID = UUID().uuidString
        var msg = Pecan_AgentEvent()
        var cmd = Pecan_MemoryCommand()
        cmd.requestID = requestID
        cmd.action = action
        cmd.scope = scope
        cmd.tag = tag
        cmd.content = content
        cmd.newTag = newTag
        msg.memoryCommand = cmd
        try await send(msg)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }

    /// Returns all distinct tags in the store for the given scope.
    func listTags(scope: String) async throws -> [String] {
        let resp = try await sendCommand(action: "list_tags", scope: scope)
        return resp.content.isEmpty ? [] : resp.content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Returns the rendered markdown content for all memories with the given tag.
    func readTag(scope: String, tag: String) async throws -> String {
        let resp = try await sendCommand(action: "read_tag", scope: scope, tag: tag)
        return resp.content
    }

    /// Replaces all memories for a tag by applying a diff from the full file content.
    /// The content should be in <!-- memory:N --> block format.
    func writeTag(scope: String, tag: String, content: String) async throws {
        _ = try await sendCommand(action: "write_tag", scope: scope, tag: tag, content: content)
    }

    /// Appends a new memory entry for the given tag.
    func appendTag(scope: String, tag: String, content: String) async throws {
        _ = try await sendCommand(action: "append_tag", scope: scope, tag: tag, content: content)
    }

    /// Deletes all memories for the given tag.
    func unlinkTag(scope: String, tag: String) async throws {
        _ = try await sendCommand(action: "unlink_tag", scope: scope, tag: tag)
    }

    /// Renames a tag across all memories that have it.
    func renameTag(scope: String, from: String, to: String) async throws {
        _ = try await sendCommand(action: "rename_tag", scope: scope, tag: from, newTag: to)
    }
}
