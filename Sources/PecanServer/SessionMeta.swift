import Foundation

/// Lightweight metadata persisted alongside each session's SQLite store.
/// Written to ~/.pecan/sessions/{id}/meta.json so sessions marked persistent
/// can be respawned after a server restart.
struct SessionMeta: Codable, Sendable {
    var sessionID: String
    var agentName: String
    var projectName: String
    var teamName: String
    var networkEnabled: Bool
    var persistent: Bool
    var startedAt: String   // ISO 8601

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agentName = "agent_name"
        case projectName = "project_name"
        case teamName = "team_name"
        case networkEnabled = "network_enabled"
        case persistent
        case startedAt = "started_at"
    }

    // MARK: - Per-session file

    static func url(sessionID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pecan/sessions/\(sessionID)/meta.json")
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url(sessionID: sessionID))
    }

    static func load(sessionID: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: url(sessionID: sessionID)) else { return nil }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    static func delete(sessionID: String) {
        try? FileManager.default.removeItem(at: url(sessionID: sessionID))
    }

    // MARK: - All persistent sessions

    /// Scans ~/.pecan/sessions/ for meta.json files flagged persistent=true.
    static func allPersistent() -> [SessionMeta] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pecan/sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) else {
            return []
        }
        return entries.compactMap { entry in
            guard let meta = load(sessionID: entry), meta.persistent else { return nil }
            return meta
        }
    }

    // MARK: - Running sessions index (.run/sessions.json)

    /// Path to the running-sessions index written by the server.
    /// pecan-shell reads this for name-based session lookup.
    static func runningIndexURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".run/sessions.json")
    }

    static func writeRunningIndex(_ sessions: [SessionMeta]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(sessions) else { return }
        let url = runningIndexURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    static func readRunningIndex() -> [SessionMeta] {
        guard let data = try? Data(contentsOf: runningIndexURL()) else { return [] }
        return (try? JSONDecoder().decode([SessionMeta].self, from: data)) ?? []
    }
}
