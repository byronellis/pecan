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

struct TaskRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "tasks"
    var id: Int64?
    var title: String
    var description: String
    var status: String       // todo, implementing, testing, preparing, done, blocked
    var priority: Int        // 1 (critical) to 5 (low)
    var severity: String     // low, normal, high, critical
    var labels: String       // comma-separated
    var dueDate: String      // ISO 8601 or empty
    var dependsOn: String    // comma-separated sessionID:taskID refs
    var focused: Int         // 0 or 1
    var createdAt: String    // ISO 8601
    var updatedAt: String    // ISO 8601

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

struct MemoryRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "memories"
    var id: Int64?
    var content: String
    var createdAt: String
    var updatedAt: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct MemoryTagRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "memory_tags"
    var id: Int64?
    var memoryId: Int64
    var tag: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TriggerRecord: Codable, FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static let databaseTableName = "triggers"
    var id: Int64?
    var instruction: String
    var fireAt: String
    var intervalSeconds: Int
    var status: String
    var pendingDelivery: Int
    var createdAt: String
    var updatedAt: String

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

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'todo',
                    priority INTEGER NOT NULL DEFAULT 3,
                    severity TEXT NOT NULL DEFAULT 'normal',
                    labels TEXT NOT NULL DEFAULT '',
                    dueDate TEXT NOT NULL DEFAULT '',
                    dependsOn TEXT NOT NULL DEFAULT '',
                    focused INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    memoryId INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    tag TEXT NOT NULL,
                    UNIQUE(memoryId, tag)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS triggers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    instruction TEXT NOT NULL,
                    fireAt TEXT NOT NULL,
                    intervalSeconds INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'active',
                    pendingDelivery INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
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

    // MARK: - Tasks

    func createTask(title: String, description: String = "", priority: Int = 3, severity: String = "normal", labels: String = "", dueDate: String = "", dependsOn: String = "") throws -> TaskRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        var record = TaskRecord(
            id: nil, title: title, description: description,
            status: "todo", priority: priority, severity: severity,
            labels: labels, dueDate: dueDate, dependsOn: dependsOn,
            focused: 0, createdAt: now, updatedAt: now
        )
        try dbQueue.write { db in
            try record.insert(db) // didInsert sets record.id
        }
        return record
    }

    func getTask(id: Int64) throws -> TaskRecord? {
        try dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: id)
        }
    }

    func listTasks(status: String? = nil, label: String? = nil, search: String? = nil) throws -> [TaskRecord] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM tasks WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let status = status, !status.isEmpty {
                sql += " AND status = ?"
                args.append(status)
            }
            if let label = label, !label.isEmpty {
                sql += " AND (',' || labels || ',') LIKE '%,' || ? || ',%'"
                args.append(label)
            }
            if let search = search, !search.isEmpty {
                sql += " AND (title LIKE ? OR description LIKE ?)"
                let pattern = "%\(search)%"
                args.append(pattern)
                args.append(pattern)
            }
            sql += " ORDER BY priority ASC, id ASC"
            return try TaskRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func updateTask(id: Int64, fields: [String: Any]) throws -> TaskRecord {
        try dbQueue.write { db in
            guard var record = try TaskRecord.fetchOne(db, key: id) else {
                throw SessionStoreError.taskNotFound(id)
            }
            let now = ISO8601DateFormatter().string(from: Date())
            if let v = fields["title"] as? String { record.title = v }
            if let v = fields["description"] as? String { record.description = v }
            if let v = fields["status"] as? String { record.status = v }
            if let v = fields["priority"] as? Int { record.priority = v }
            if let v = fields["severity"] as? String { record.severity = v }
            if let v = fields["labels"] as? String { record.labels = v }
            if let v = fields["due_date"] as? String { record.dueDate = v }
            if let v = fields["depends_on"] as? String { record.dependsOn = v }
            record.updatedAt = now
            try record.update(db)
            return record
        }
    }

    func setFocused(taskID: Int64) throws {
        try dbQueue.write { db in
            // Clear all focused
            try db.execute(sql: "UPDATE tasks SET focused = 0 WHERE focused = 1")
            if taskID > 0 {
                try db.execute(sql: "UPDATE tasks SET focused = 1 WHERE id = ?", arguments: [taskID])
            }
        }
    }

    func getFocusedTask() throws -> TaskRecord? {
        try dbQueue.read { db in
            try TaskRecord.filter(Column("focused") == 1).fetchOne(db)
        }
    }

    // MARK: - Memories

    func createMemory(content: String, tags: [String] = []) throws -> MemoryRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        var record = MemoryRecord(id: nil, content: content, createdAt: now, updatedAt: now)
        try dbQueue.write { db in
            try record.insert(db)
            for tag in tags {
                try MemoryTagRecord(id: nil, memoryId: record.id!, tag: tag).insert(db)
            }
        }
        return record
    }

    func getMemory(id: Int64) throws -> (MemoryRecord, [String])? {
        try dbQueue.read { db in
            guard let record = try MemoryRecord.fetchOne(db, key: id) else { return nil }
            let tags = try MemoryTagRecord
                .filter(Column("memoryId") == id)
                .fetchAll(db)
                .map(\.tag)
            return (record, tags)
        }
    }

    func listMemories(tag: String? = nil) throws -> [(MemoryRecord, [String])] {
        try dbQueue.read { db in
            let memories: [MemoryRecord]
            if let tag = tag, !tag.isEmpty {
                memories = try MemoryRecord.fetchAll(db, sql: """
                    SELECT m.* FROM memories m
                    JOIN memory_tags mt ON mt.memoryId = m.id
                    WHERE mt.tag = ?
                    ORDER BY m.id ASC
                    """, arguments: [tag])
            } else {
                memories = try MemoryRecord.order(Column("id").asc).fetchAll(db)
            }
            return try memories.map { mem in
                let tags = try MemoryTagRecord
                    .filter(Column("memoryId") == mem.id!)
                    .fetchAll(db)
                    .map(\.tag)
                return (mem, tags)
            }
        }
    }

    func searchMemories(query: String) throws -> [(MemoryRecord, [String])] {
        try dbQueue.read { db in
            let pattern = "%\(query)%"
            let memories = try MemoryRecord.fetchAll(db, sql:
                "SELECT * FROM memories WHERE content LIKE ? ORDER BY id ASC",
                arguments: [pattern])
            return try memories.map { mem in
                let tags = try MemoryTagRecord
                    .filter(Column("memoryId") == mem.id!)
                    .fetchAll(db)
                    .map(\.tag)
                return (mem, tags)
            }
        }
    }

    func updateMemory(id: Int64, content: String) throws -> MemoryRecord {
        try dbQueue.write { db in
            guard var record = try MemoryRecord.fetchOne(db, key: id) else {
                throw SessionStoreError.memoryNotFound(id)
            }
            record.content = content
            record.updatedAt = ISO8601DateFormatter().string(from: Date())
            try record.update(db)
            return record
        }
    }

    func deleteMemory(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
        }
    }

    func addMemoryTag(memoryId: Int64, tag: String) throws {
        try dbQueue.write { db in
            try MemoryTagRecord(id: nil, memoryId: memoryId, tag: tag).insert(db)
        }
    }

    func removeMemoryTag(memoryId: Int64, tag: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ? AND tag = ?", arguments: [memoryId, tag])
        }
    }

    func getCoreMemories() throws -> [MemoryRecord] {
        try dbQueue.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT m.* FROM memories m
                JOIN memory_tags mt ON mt.memoryId = m.id
                WHERE mt.tag = 'core'
                ORDER BY m.id ASC
                """)
        }
    }

    // MARK: - Triggers

    func createTrigger(instruction: String, fireAt: String, intervalSeconds: Int = 0) throws -> TriggerRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        var record = TriggerRecord(
            id: nil, instruction: instruction, fireAt: fireAt,
            intervalSeconds: intervalSeconds, status: "active",
            pendingDelivery: 0, createdAt: now, updatedAt: now
        )
        try dbQueue.write { db in
            try record.insert(db)
        }
        return record
    }

    func listTriggers(status: String? = nil) throws -> [TriggerRecord] {
        try dbQueue.read { db in
            if let status = status, !status.isEmpty {
                return try TriggerRecord
                    .filter(Column("status") == status)
                    .order(Column("fireAt").asc)
                    .fetchAll(db)
            } else {
                return try TriggerRecord.order(Column("fireAt").asc).fetchAll(db)
            }
        }
    }

    func cancelTrigger(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE triggers SET status = 'cancelled', updatedAt = ? WHERE id = ?",
                           arguments: [ISO8601DateFormatter().string(from: Date()), id])
        }
    }

    func getDueTriggers() throws -> [TriggerRecord] {
        let now = ISO8601DateFormatter().string(from: Date())
        return try dbQueue.read { db in
            try TriggerRecord.fetchAll(db, sql: """
                SELECT * FROM triggers
                WHERE fireAt <= ? AND status = 'active' AND pendingDelivery = 0
                ORDER BY fireAt ASC
                """, arguments: [now])
        }
    }

    func markTriggerPending(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE triggers SET pendingDelivery = 1, updatedAt = ? WHERE id = ?",
                           arguments: [ISO8601DateFormatter().string(from: Date()), id])
        }
    }

    func completeTriggerDelivery(id: Int64) throws {
        try dbQueue.write { db in
            guard let trigger = try TriggerRecord.fetchOne(db, key: id) else { return }
            let now = ISO8601DateFormatter().string(from: Date())
            if trigger.intervalSeconds > 0 {
                // Repeating: advance fireAt and clear pending
                let formatter = ISO8601DateFormatter()
                let currentFireAt = formatter.date(from: trigger.fireAt) ?? Date()
                let nextFireAt = currentFireAt.addingTimeInterval(TimeInterval(trigger.intervalSeconds))
                try db.execute(sql: """
                    UPDATE triggers SET pendingDelivery = 0, fireAt = ?, updatedAt = ? WHERE id = ?
                    """, arguments: [formatter.string(from: nextFireAt), now, id])
            } else {
                // One-shot: mark as fired
                try db.execute(sql: "UPDATE triggers SET status = 'fired', pendingDelivery = 0, updatedAt = ? WHERE id = ?",
                               arguments: [now, id])
            }
        }
    }

    enum SessionStoreError: Error, CustomStringConvertible, LocalizedError {
        case sessionNotFound(String)
        case taskNotFound(Int64)
        case memoryNotFound(Int64)

        var description: String {
            switch self {
            case .sessionNotFound(let id): return "Session not found: \(id)"
            case .taskNotFound(let id): return "Task not found: #\(id)"
            case .memoryNotFound(let id): return "Memory not found: #\(id)"
            }
        }

        var errorDescription: String? { description }
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
