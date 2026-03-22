import Foundation
import GRDB

// MARK: - ScopedStore Protocol

/// Protocol for stores that manage tasks, memories, and shares.
/// Conformed to by SessionStore, ProjectStore, and TeamStore.
protocol ScopedStore: Sendable {
    // Tasks
    func createTask(title: String, description: String, priority: Int, severity: String, labels: String, dueDate: String, dependsOn: String) throws -> TaskRecord
    func getTask(id: Int64) throws -> TaskRecord?
    func listTasks(status: String?, label: String?, search: String?) throws -> [TaskRecord]
    func updateTask(id: Int64, fields: [String: Any]) throws -> TaskRecord
    func setFocused(taskID: Int64) throws
    func getFocusedTask() throws -> TaskRecord?

    // Memories
    func createMemory(content: String, tags: [String]) throws -> MemoryRecord
    func getMemory(id: Int64) throws -> (MemoryRecord, [String])?
    func listMemories(tag: String?) throws -> [(MemoryRecord, [String])]
    func searchMemories(query: String) throws -> [(MemoryRecord, [String])]
    func updateMemory(id: Int64, content: String) throws -> MemoryRecord
    func deleteMemory(id: Int64) throws
    func addMemoryTag(memoryId: Int64, tag: String) throws
    func removeMemoryTag(memoryId: Int64, tag: String) throws
    func getCoreMemories() throws -> [MemoryRecord]

    // Shares
    func addShare(hostPath: String, guestPath: String, mode: String) throws
    func removeShare(hostPath: String) throws
    func getShares() throws -> [ShareRecord]

    // Memory FUSE operations
    func listTags() throws -> [String]
    func renderTag(tag: String) throws -> String
    func applyMemoryDiff(tag: String, content: String) throws
    func appendMemory(tag: String, content: String) throws
    func unlinkTag(tag: String) throws
    func renameTag(from: String, to: String) throws
}

// MARK: - ScopedStoreError

enum ScopedStoreError: Error, CustomStringConvertible, LocalizedError {
    case notFound(String)
    case taskNotFound(Int64)
    case memoryNotFound(Int64)

    var description: String {
        switch self {
        case .notFound(let id): return "Store not found: \(id)"
        case .taskNotFound(let id): return "Task not found: #\(id)"
        case .memoryNotFound(let id): return "Memory not found: #\(id)"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - Shared Migration for Tasks/Memories/Shares

/// Creates the common tables used by all scoped stores.
func migrateCommonTables(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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
        CREATE TABLE IF NOT EXISTS shares (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hostPath TEXT NOT NULL,
            guestPath TEXT NOT NULL,
            mode TEXT NOT NULL DEFAULT 'ro'
        )
        """)
}

// MARK: - Shared CRUD Implementations

/// Default implementations for ScopedStore backed by a GRDB DatabaseQueue.
/// Call these from concrete store types that hold a `dbQueue`.
enum ScopedStoreCRUD {

    // MARK: Tasks

    static func createTask(dbQueue: DatabaseQueue, title: String, description: String, priority: Int, severity: String, labels: String, dueDate: String, dependsOn: String) throws -> TaskRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        var record = TaskRecord(
            id: nil, title: title, description: description,
            status: "todo", priority: priority, severity: severity,
            labels: labels, dueDate: dueDate, dependsOn: dependsOn,
            focused: 0, createdAt: now, updatedAt: now
        )
        try dbQueue.write { db in
            try record.insert(db)
        }
        return record
    }

    static func getTask(dbQueue: DatabaseQueue, id: Int64) throws -> TaskRecord? {
        try dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: id)
        }
    }

    static func listTasks(dbQueue: DatabaseQueue, status: String?, label: String?, search: String?) throws -> [TaskRecord] {
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

    static func updateTask(dbQueue: DatabaseQueue, id: Int64, fields: [String: Any]) throws -> TaskRecord {
        try dbQueue.write { db in
            guard var record = try TaskRecord.fetchOne(db, key: id) else {
                throw ScopedStoreError.taskNotFound(id)
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

    static func setFocused(dbQueue: DatabaseQueue, taskID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET focused = 0 WHERE focused = 1")
            if taskID > 0 {
                try db.execute(sql: "UPDATE tasks SET focused = 1 WHERE id = ?", arguments: [taskID])
            }
        }
    }

    static func getFocusedTask(dbQueue: DatabaseQueue) throws -> TaskRecord? {
        try dbQueue.read { db in
            try TaskRecord.filter(Column("focused") == 1).fetchOne(db)
        }
    }

    // MARK: Memories

    static func createMemory(dbQueue: DatabaseQueue, content: String, tags: [String]) throws -> MemoryRecord {
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

    static func getMemory(dbQueue: DatabaseQueue, id: Int64) throws -> (MemoryRecord, [String])? {
        try dbQueue.read { db in
            guard let record = try MemoryRecord.fetchOne(db, key: id) else { return nil }
            let tags = try MemoryTagRecord
                .filter(Column("memoryId") == id)
                .fetchAll(db)
                .map(\.tag)
            return (record, tags)
        }
    }

    static func listMemories(dbQueue: DatabaseQueue, tag: String?) throws -> [(MemoryRecord, [String])] {
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

    static func searchMemories(dbQueue: DatabaseQueue, query: String) throws -> [(MemoryRecord, [String])] {
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

    static func updateMemory(dbQueue: DatabaseQueue, id: Int64, content: String) throws -> MemoryRecord {
        try dbQueue.write { db in
            guard var record = try MemoryRecord.fetchOne(db, key: id) else {
                throw ScopedStoreError.memoryNotFound(id)
            }
            record.content = content
            record.updatedAt = ISO8601DateFormatter().string(from: Date())
            try record.update(db)
            return record
        }
    }

    static func deleteMemory(dbQueue: DatabaseQueue, id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
        }
    }

    static func addMemoryTag(dbQueue: DatabaseQueue, memoryId: Int64, tag: String) throws {
        try dbQueue.write { db in
            try MemoryTagRecord(id: nil, memoryId: memoryId, tag: tag).insert(db)
        }
    }

    static func removeMemoryTag(dbQueue: DatabaseQueue, memoryId: Int64, tag: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ? AND tag = ?", arguments: [memoryId, tag])
        }
    }

    static func getCoreMemories(dbQueue: DatabaseQueue) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT m.* FROM memories m
                JOIN memory_tags mt ON mt.memoryId = m.id
                WHERE mt.tag = 'core'
                ORDER BY m.id ASC
                """)
        }
    }

    // MARK: Shares

    static func addShare(dbQueue: DatabaseQueue, hostPath: String, guestPath: String, mode: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM shares WHERE hostPath = ?", arguments: [hostPath])
            let record = ShareRecord(id: nil, hostPath: hostPath, guestPath: guestPath, mode: mode)
            try record.insert(db)
        }
    }

    static func removeShare(dbQueue: DatabaseQueue, hostPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM shares WHERE hostPath = ?", arguments: [hostPath])
        }
    }

    static func getShares(dbQueue: DatabaseQueue) throws -> [ShareRecord] {
        try dbQueue.read { db in
            try ShareRecord.fetchAll(db)
        }
    }

    // MARK: Memory FUSE operations

    /// Lists all distinct tags that have at least one memory entry.
    static func listTags(dbQueue: DatabaseQueue) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT tag FROM memory_tags ORDER BY tag ASC")
        }
    }

    /// Renders all memories for a tag as a <!-- memory:N --> block formatted string.
    static func renderTag(dbQueue: DatabaseQueue, tag: String) throws -> String {
        let memories = try dbQueue.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT m.* FROM memories m
                JOIN memory_tags mt ON mt.memoryId = m.id
                WHERE mt.tag = ?
                ORDER BY m.id ASC
                """, arguments: [tag])
        }
        guard !memories.isEmpty else { return "" }
        return memories.map { "<!-- memory:\($0.id!) -->\n\($0.content)" }.joined(separator: "\n\n")
    }

    /// Applies a full content replacement for a tag by parsing <!-- memory:N --> blocks.
    /// - Blocks with existing IDs are updated.
    /// - Existing IDs absent from the new content are deleted.
    /// - Blocks without IDs (or with unknown IDs) are inserted as new entries.
    static func applyMemoryDiff(dbQueue: DatabaseQueue, tag: String, content: String) throws {
        struct Block { let id: Int64?; let content: String }
        var blocks: [Block] = []
        var currentID: Int64? = nil
        var currentLines: [String] = []

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("<!-- memory:") && line.hasSuffix(" -->") {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty || currentID != nil {
                    blocks.append(Block(id: currentID, content: text))
                }
                currentLines = []
                let inner = line.dropFirst(12).dropLast(4) // strip "<!-- memory:" and " -->"
                currentID = Int64(inner.trimmingCharacters(in: .whitespaces))
            } else {
                currentLines.append(line)
            }
        }
        let lastText = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastText.isEmpty || currentID != nil {
            blocks.append(Block(id: currentID, content: lastText))
        }

        let existing = try dbQueue.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT m.* FROM memories m
                JOIN memory_tags mt ON mt.memoryId = m.id
                WHERE mt.tag = ?
                ORDER BY m.id ASC
                """, arguments: [tag])
        }
        let existingIDs = Set(existing.compactMap { $0.id })
        let mentionedIDs = Set(blocks.compactMap { $0.id })
        let now = ISO8601DateFormatter().string(from: Date())

        try dbQueue.write { db in
            // Delete memories not present in the new content
            for id in existingIDs where !mentionedIDs.contains(id) {
                try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            }
            // Update or insert
            for block in blocks {
                guard !block.content.isEmpty else { continue }
                if let id = block.id, existingIDs.contains(id) {
                    try db.execute(sql: "UPDATE memories SET content = ?, updatedAt = ? WHERE id = ?",
                        arguments: [block.content, now, id])
                } else {
                    let record = MemoryRecord(id: nil, content: block.content, createdAt: now, updatedAt: now)
                    try record.insert(db)
                    try MemoryTagRecord(id: nil, memoryId: db.lastInsertedRowID, tag: tag).insert(db)
                }
            }
        }
    }

    /// Appends a new memory entry with the given tag.
    static func appendMemory(dbQueue: DatabaseQueue, tag: String, content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            let record = MemoryRecord(id: nil, content: trimmed, createdAt: now, updatedAt: now)
            try record.insert(db)
            try MemoryTagRecord(id: nil, memoryId: db.lastInsertedRowID, tag: tag).insert(db)
        }
    }

    /// Deletes all memories for the given tag.
    static func unlinkTag(dbQueue: DatabaseQueue, tag: String) throws {
        let ids = try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT memoryId FROM memory_tags WHERE tag = ?", arguments: [tag])
        }
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Updates all memory_tags rows for a given tag to a new tag name.
    static func renameTag(dbQueue: DatabaseQueue, from oldTag: String, to newTag: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE memory_tags SET tag = ? WHERE tag = ?", arguments: [newTag, oldTag])
        }
    }
}
