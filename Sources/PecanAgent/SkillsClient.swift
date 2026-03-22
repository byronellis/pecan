import Foundation
import PecanShared

/// gRPC client for skills directory access. The server serves files from ~/.pecan/skills/;
/// this actor sends SkillsCommand requests and routes SkillsResponse replies.
actor SkillsClient {
    static let shared = SkillsClient()

    struct DirEntry: Sendable {
        let name: String
        let isDir: Bool
        let isExecutable: Bool
    }

    private var pendingRequests: [String: CheckedContinuation<Pecan_SkillsResponse, Error>] = [:]
    private var sendCallback: (@Sendable (Pecan_AgentEvent) async throws -> Void)?

    func configure(send: @escaping @Sendable (Pecan_AgentEvent) async throws -> Void) {
        self.sendCallback = send
    }

    func handleResponse(_ response: Pecan_SkillsResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(
                domain: "SkillsClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage]))
        } else {
            continuation.resume(returning: response)
        }
    }

    private func sendCommand(action: String, path: String) async throws -> Pecan_SkillsResponse {
        guard let send = sendCallback else {
            throw NSError(domain: "SkillsClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "SkillsClient not configured"])
        }
        let requestID = UUID().uuidString
        var msg = Pecan_AgentEvent()
        var cmd = Pecan_SkillsCommand()
        cmd.requestID = requestID
        cmd.action = action
        cmd.path = path
        msg.skillsCommand = cmd
        try await send(msg)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }

    /// Lists entries in a skills directory path (e.g. "/" for top-level, "/web" for a skill bundle).
    func listDir(path: String) async throws -> [DirEntry] {
        let resp = try await sendCommand(action: "list_dir", path: path)
        guard let data = resp.content.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return DirEntry(
                name: name,
                isDir: dict["isDir"] as? Bool ?? false,
                isExecutable: dict["isExecutable"] as? Bool ?? false
            )
        }
    }

    /// Reads the content of a skills file (e.g. "/web/SKILL.md" or "/web/scripts/http_request").
    func readFile(path: String) async throws -> (content: Data, isExecutable: Bool) {
        let resp = try await sendCommand(action: "read_file", path: path)
        let data = resp.content.data(using: .utf8) ?? Data()
        return (content: data, isExecutable: resp.isExecutable)
    }
}
