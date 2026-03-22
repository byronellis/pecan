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
final class SessionStore: ScopedStore, Sendable {
    let sessionID: String
    let sessionDir: URL
    let workspacePath: URL
    let memoryDir: URL
    var dbPath: String { sessionDir.appendingPathComponent("session.db").path }
    let dbQueue: DatabaseQueue

    /// Create a new session store (new session).
    init(sessionID: String, name: String) throws {
        self.sessionID = sessionID
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.sessionDir = homeDir.appendingPathComponent(".pecan/sessions/\(sessionID)")
        self.workspacePath = sessionDir.appendingPathComponent("workspace")
        self.memoryDir = sessionDir.appendingPathComponent("memory")

        let fm = FileManager.default
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)

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
        self.memoryDir = sessionDir.appendingPathComponent("memory")

        let dbPath = sessionDir.appendingPathComponent("session.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        self.dbQueue = try DatabaseQueue(path: dbPath)
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try migrateCommonTables(db)

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

    // MARK: - ScopedStore: Tasks

    func createTask(title: String, description: String = "", priority: Int = 3, severity: String = "normal", labels: String = "", dueDate: String = "", dependsOn: String = "") throws -> TaskRecord {
        try ScopedStoreCRUD.createTask(dbQueue: dbQueue, title: title, description: description, priority: priority, severity: severity, labels: labels, dueDate: dueDate, dependsOn: dependsOn)
    }

    func getTask(id: Int64) throws -> TaskRecord? {
        try ScopedStoreCRUD.getTask(dbQueue: dbQueue, id: id)
    }

    func listTasks(status: String? = nil, label: String? = nil, search: String? = nil) throws -> [TaskRecord] {
        try ScopedStoreCRUD.listTasks(dbQueue: dbQueue, status: status, label: label, search: search)
    }

    func updateTask(id: Int64, fields: [String: Any]) throws -> TaskRecord {
        try ScopedStoreCRUD.updateTask(dbQueue: dbQueue, id: id, fields: fields)
    }

    func setFocused(taskID: Int64) throws {
        try ScopedStoreCRUD.setFocused(dbQueue: dbQueue, taskID: taskID)
    }

    func getFocusedTask() throws -> TaskRecord? {
        try ScopedStoreCRUD.getFocusedTask(dbQueue: dbQueue)
    }

    // MARK: - ScopedStore: Memories

    func createMemory(content: String, tags: [String] = []) throws -> MemoryRecord {
        try ScopedStoreCRUD.createMemory(dbQueue: dbQueue, content: content, tags: tags)
    }

    func getMemory(id: Int64) throws -> (MemoryRecord, [String])? {
        try ScopedStoreCRUD.getMemory(dbQueue: dbQueue, id: id)
    }

    func listMemories(tag: String? = nil) throws -> [(MemoryRecord, [String])] {
        try ScopedStoreCRUD.listMemories(dbQueue: dbQueue, tag: tag)
    }

    func searchMemories(query: String) throws -> [(MemoryRecord, [String])] {
        try ScopedStoreCRUD.searchMemories(dbQueue: dbQueue, query: query)
    }

    func updateMemory(id: Int64, content: String) throws -> MemoryRecord {
        try ScopedStoreCRUD.updateMemory(dbQueue: dbQueue, id: id, content: content)
    }

    func deleteMemory(id: Int64) throws {
        try ScopedStoreCRUD.deleteMemory(dbQueue: dbQueue, id: id)
    }

    func addMemoryTag(memoryId: Int64, tag: String) throws {
        try ScopedStoreCRUD.addMemoryTag(dbQueue: dbQueue, memoryId: memoryId, tag: tag)
    }

    func removeMemoryTag(memoryId: Int64, tag: String) throws {
        try ScopedStoreCRUD.removeMemoryTag(dbQueue: dbQueue, memoryId: memoryId, tag: tag)
    }

    func getCoreMemories() throws -> [MemoryRecord] {
        try ScopedStoreCRUD.getCoreMemories(dbQueue: dbQueue)
    }

    // MARK: - ScopedStore: Shares

    func addShare(hostPath: String, guestPath: String, mode: String = "ro") throws {
        try ScopedStoreCRUD.addShare(dbQueue: dbQueue, hostPath: hostPath, guestPath: guestPath, mode: mode)
    }

    func removeShare(hostPath: String) throws {
        try ScopedStoreCRUD.removeShare(dbQueue: dbQueue, hostPath: hostPath)
    }

    func getShares() throws -> [ShareRecord] {
        try ScopedStoreCRUD.getShares(dbQueue: dbQueue)
    }

    // MARK: - Triggers (session-specific)

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
                let formatter = ISO8601DateFormatter()
                let currentFireAt = formatter.date(from: trigger.fireAt) ?? Date()
                let nextFireAt = currentFireAt.addingTimeInterval(TimeInterval(trigger.intervalSeconds))
                try db.execute(sql: """
                    UPDATE triggers SET pendingDelivery = 0, fireAt = ?, updatedAt = ? WHERE id = ?
                    """, arguments: [formatter.string(from: nextFireAt), now, id])
            } else {
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
