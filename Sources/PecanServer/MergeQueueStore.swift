import Foundation
import GRDB
import Logging

/// Persistent merge history stored in .run/mergequeue.db.
/// Records the outcome of every changeset merge triggered by /changeset:submit.
/// Statuses: "merging" (in progress), "merged" (success), "failed" (unresolvable).
actor MergeQueueStore {
    static let shared = MergeQueueStore()

    private var db: DatabaseQueue?

    private init() {}

    private func queue() throws -> DatabaseQueue {
        if let existing = db { return existing }
        let runDir = FileManager.default.currentDirectoryPath + "/.run"
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        let dbPath = runDir + "/mergequeue.db"
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS merge_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    merge_id TEXT NOT NULL DEFAULT '',
                    session_id TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    project_name TEXT NOT NULL DEFAULT '',
                    note TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'merging',
                    submitted_at TEXT NOT NULL,
                    resolved_at TEXT,
                    result_message TEXT NOT NULL DEFAULT ''
                )
            """)
        }
        db = q
        return q
    }

    struct Entry: Codable {
        var id: Int64
        var mergeID: String
        var sessionID: String
        var agentName: String
        var projectName: String
        var note: String
        var status: String       // "merging", "merged", "failed"
        var submittedAt: String
        var resolvedAt: String?
        var resultMessage: String

        enum CodingKeys: String, CodingKey {
            case id, note, status
            case mergeID = "merge_id"
            case sessionID = "session_id"
            case agentName = "agent_name"
            case projectName = "project_name"
            case submittedAt = "submitted_at"
            case resolvedAt = "resolved_at"
            case resultMessage = "result_message"
        }
    }

    func begin(mergeID: String, sessionID: String, agentName: String, projectName: String, note: String) throws -> Entry {
        let q = try queue()
        let now = ISO8601DateFormatter().string(from: Date())
        var newID: Int64 = 0
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO merge_queue (merge_id, session_id, agent_name, project_name, note, status, submitted_at)
                VALUES (?, ?, ?, ?, ?, 'merging', ?)
            """, arguments: [mergeID, sessionID, agentName, projectName, note, now])
            newID = db.lastInsertedRowID
        }
        return Entry(id: newID, mergeID: mergeID, sessionID: sessionID, agentName: agentName,
                     projectName: projectName, note: note, status: "merging",
                     submittedAt: now, resolvedAt: nil, resultMessage: "")
    }

    func finish(mergeID: String, status: String, message: String) throws {
        let q = try queue()
        let now = ISO8601DateFormatter().string(from: Date())
        try q.write { db in
            try db.execute(sql: """
                UPDATE merge_queue SET status = ?, resolved_at = ?, result_message = ? WHERE merge_id = ?
            """, arguments: [status, now, message, mergeID])
        }
    }

    func list(status: String? = nil) throws -> [Entry] {
        let q = try queue()
        return try q.read { db in
            let sql = status != nil
                ? "SELECT * FROM merge_queue WHERE status = ? ORDER BY submitted_at DESC"
                : "SELECT * FROM merge_queue ORDER BY submitted_at DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: status.map { [DatabaseValue(value: $0)] } ?? [])
            return rows.map { row in
                Entry(
                    id: row["id"],
                    mergeID: row["merge_id"] ?? "",
                    sessionID: row["session_id"],
                    agentName: row["agent_name"],
                    projectName: row["project_name"],
                    note: row["note"],
                    status: row["status"],
                    submittedAt: row["submitted_at"],
                    resolvedAt: row["resolved_at"],
                    resultMessage: row["result_message"] ?? ""
                )
            }
        }
    }
}
