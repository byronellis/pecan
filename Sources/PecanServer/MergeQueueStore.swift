import Foundation
import GRDB
import Logging

/// Persistent merge queue stored in .run/mergequeue.db.
/// Tracks overlay changesets submitted for review across all sessions.
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
                    session_id TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    project_name TEXT NOT NULL DEFAULT '',
                    note TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'pending',
                    submitted_at TEXT NOT NULL,
                    resolved_at TEXT
                )
            """)
        }
        db = q
        return q
    }

    struct Entry: Codable {
        var id: Int64
        var sessionID: String
        var agentName: String
        var projectName: String
        var note: String
        var status: String
        var submittedAt: String
        var resolvedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, note, status
            case sessionID = "session_id"
            case agentName = "agent_name"
            case projectName = "project_name"
            case submittedAt = "submitted_at"
            case resolvedAt = "resolved_at"
        }
    }

    func submit(sessionID: String, agentName: String, projectName: String, note: String) throws -> Entry {
        let q = try queue()
        let now = ISO8601DateFormatter().string(from: Date())
        var newID: Int64 = 0
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO merge_queue (session_id, agent_name, project_name, note, status, submitted_at)
                VALUES (?, ?, ?, ?, 'pending', ?)
            """, arguments: [sessionID, agentName, projectName, note, now])
            newID = db.lastInsertedRowID
        }
        return Entry(id: newID, sessionID: sessionID, agentName: agentName,
                     projectName: projectName, note: note, status: "pending",
                     submittedAt: now, resolvedAt: nil)
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
                    sessionID: row["session_id"],
                    agentName: row["agent_name"],
                    projectName: row["project_name"],
                    note: row["note"],
                    status: row["status"],
                    submittedAt: row["submitted_at"],
                    resolvedAt: row["resolved_at"]
                )
            }
        }
    }

    func get(id: Int64) throws -> Entry? {
        let q = try queue()
        return try q.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM merge_queue WHERE id = ?", arguments: [id]) else { return nil }
            return Entry(
                id: row["id"],
                sessionID: row["session_id"],
                agentName: row["agent_name"],
                projectName: row["project_name"],
                note: row["note"],
                status: row["status"],
                submittedAt: row["submitted_at"],
                resolvedAt: row["resolved_at"]
            )
        }
    }

    func resolve(id: Int64, status: String) throws {
        let q = try queue()
        let now = ISO8601DateFormatter().string(from: Date())
        try q.write { db in
            try db.execute(sql: "UPDATE merge_queue SET status = ?, resolved_at = ? WHERE id = ?",
                           arguments: [status, now, id])
        }
    }
}
