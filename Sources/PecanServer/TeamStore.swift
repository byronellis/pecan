import Foundation
import GRDB

/// Manages a team's SQLite database at ~/.pecan/projects/{projectName}/teams/{teamName}/team.db
/// Teams belong to projects and have their own workspace, tasks, memories, and shares.
final class TeamStore: ScopedStore, Sendable {
    let teamName: String
    let projectName: String
    let teamDir: URL
    let workspacePath: URL
    let memoryDir: URL
    var dbPath: String { teamDir.appendingPathComponent("team.db").path }
    let dbQueue: DatabaseQueue

    /// Create or open a team store within a project.
    init(teamName: String, projectName: String) throws {
        self.teamName = teamName
        self.projectName = projectName
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let teamDir = homeDir.appendingPathComponent(".pecan/projects/\(projectName)/teams/\(teamName)")
        self.teamDir = teamDir
        self.workspacePath = teamDir.appendingPathComponent("workspace")
        self.memoryDir = teamDir.appendingPathComponent("memory")

        let fm = FileManager.default
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        let dbPath = teamDir.appendingPathComponent("team.db").path
        let isNew = !fm.fileExists(atPath: dbPath)
        self.dbQueue = try DatabaseQueue(path: dbPath)

        if isNew {
            try migrate()
            try writeMetadata()
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try migrateCommonTables(db)
        }
    }

    private func writeMetadata() throws {
        try dbQueue.write { db in
            try MetadataRecord(key: "name", value: teamName).insert(db)
            try MetadataRecord(key: "project", value: projectName).insert(db)
            try MetadataRecord(key: "created_at", value: ISO8601DateFormatter().string(from: Date())).insert(db)
        }
    }

    // MARK: - Metadata

    var name: String {
        get throws {
            try dbQueue.read { db in
                let record = try MetadataRecord.fetchOne(db, key: "name")
                return record?.value ?? teamName
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
}

// MARK: - TeamRegistry

/// Scans teams within a project directory.
struct TeamRegistry {
    static func teamsDir(projectName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/projects/\(projectName)/teams")
    }

    static func listTeamNames(projectName: String) -> [String] {
        let fm = FileManager.default
        let dir = teamsDir(projectName: projectName)
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return contents.filter { name in
            let dbPath = dir.appendingPathComponent(name).appendingPathComponent("team.db").path
            return fm.fileExists(atPath: dbPath)
        }.sorted()
    }
}
