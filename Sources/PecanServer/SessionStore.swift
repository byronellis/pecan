import Foundation
import GRDB

// MARK: - Database Records

struct MetadataRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "metadata"
    var key: String
    var value: String
}

struct ContextMessageRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "context_messages"
    var id: Int64?
    var section: Int
    var role: String
    var content: String
    var metadataJson: String
    var seq: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ShareRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "shares"
    var id: Int64?
    var hostPath: String
    var guestPath: String
    var mode: String // "ro" or "rw"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - SessionStore

/// Manages a single session's SQLite database at ~/.pecan/sessions/{sessionID}/session.db
final class SessionStore: Sendable {
    let sessionID: String
    let sessionDir: URL
    let workspacePath: URL
    private let dbQueue: DatabaseQueue

    /// Create a new session store (new session).
    init(sessionID: String, name: String) throws {
        self.sessionID = sessionID
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.sessionDir = homeDir.appendingPathComponent(".pecan/sessions/\(sessionID)")
        self.workspacePath = sessionDir.appendingPathComponent("workspace")

        let fm = FileManager.default
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)

        let dbPath = sessionDir.appendingPathComponent("session.db").path
        self.dbQueue = try DatabaseQueue(path: dbPath)

        try migrate()
        try writeMetadata(name: name)
    }

    /// Open an existing session store (resume).
    init(sessionID: String) throws {
        self.sessionID = sessionID
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.sessionDir = homeDir.appendingPathComponent(".pecan/sessions/\(sessionID)")
        self.workspacePath = sessionDir.appendingPathComponent("workspace")

        let dbPath = sessionDir.appendingPathComponent("session.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        self.dbQueue = try DatabaseQueue(path: dbPath)
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS context_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    section INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    metadataJson TEXT NOT NULL DEFAULT '',
                    seq INTEGER NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS shares (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    hostPath TEXT NOT NULL,
                    guestPath TEXT NOT NULL,
                    mode TEXT NOT NULL DEFAULT 'ro'
                )
                """)
        }
    }

    private func writeMetadata(name: String) throws {
        try dbQueue.write { db in
            try MetadataRecord(key: "name", value: name).insert(db)
            try MetadataRecord(key: "created_at", value: ISO8601DateFormatter().string(from: Date())).insert(db)
            try MetadataRecord(key: "status", value: "active").insert(db)
        }
    }

    // MARK: - Metadata

    var name: String {
        get throws {
            try dbQueue.read { db in
                let record = try MetadataRecord.fetchOne(db, key: "name")
                return record?.value ?? "unknown"
            }
        }
    }

    // MARK: - Context Messages

    func addContextMessage(section: Int, role: String, content: String, metadata: String) throws {
        try dbQueue.write { db in
            let maxSeq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), -1) FROM context_messages WHERE section = ?", arguments: [section]) ?? -1
            let record = ContextMessageRecord(
                id: nil,
                section: section,
                role: role,
                content: content,
                metadataJson: metadata,
                seq: maxSeq + 1
            )
            try record.insert(db)
        }
    }

    func getContextMessages() throws -> [ContextMessageRecord] {
        try dbQueue.read { db in
            try ContextMessageRecord
                .order(Column("section").asc, Column("seq").asc)
                .fetchAll(db)
        }
    }

    func compactContext(section: Int, keepRecent: Int) throws {
        try dbQueue.write { db in
            let count = try ContextMessageRecord.filter(Column("section") == section).fetchCount(db)
            if count > keepRecent {
                let deleteCount = count - keepRecent
                try db.execute(sql: """
                    DELETE FROM context_messages WHERE id IN (
                        SELECT id FROM context_messages WHERE section = ? ORDER BY seq ASC LIMIT ?
                    )
                    """, arguments: [section, deleteCount])
            }
        }
    }

    // MARK: - Shares

    func addShare(hostPath: String, guestPath: String, mode: String = "ro") throws {
        try dbQueue.write { db in
            // Remove existing share for same host path
            try db.execute(sql: "DELETE FROM shares WHERE hostPath = ?", arguments: [hostPath])
            let record = ShareRecord(id: nil, hostPath: hostPath, guestPath: guestPath, mode: mode)
            try record.insert(db)
        }
    }

    func removeShare(hostPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM shares WHERE hostPath = ?", arguments: [hostPath])
        }
    }

    func getShares() throws -> [ShareRecord] {
        try dbQueue.read { db in
            try ShareRecord.fetchAll(db)
        }
    }

    enum SessionStoreError: Error, CustomStringConvertible {
        case sessionNotFound(String)

        var description: String {
            switch self {
            case .sessionNotFound(let id): return "Session not found: \(id)"
            }
        }
    }
}

// MARK: - SessionRegistry

/// Lightweight registry that scans ~/.pecan/sessions/ to list available sessions.
struct SessionRegistry {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/sessions")
    }

    static func listSessionIDs() -> [String] {
        let fm = FileManager.default
        let dir = sessionsDir
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return contents.filter { name in
            let dbPath = dir.appendingPathComponent(name).appendingPathComponent("session.db").path
            return fm.fileExists(atPath: dbPath)
        }
    }
}
