import Foundation
import GRDB

/// Manages a team's SQLite database.
///
/// New model (flat): stored at ~/.pecan/teams/{name}/team.db — team IS the project workspace.
/// Legacy model: stored at ~/.pecan/projects/{projectName}/teams/{teamName}/team.db
///
/// Teams own an optional project directory (e.g. a git repo root) rather than belonging to a project.
final class TeamStore: ScopedStore, Sendable {
    let teamName: String
    let projectName: String
    let teamDir: URL
    let workspacePath: URL
    /// The project directory this team is associated with (e.g. a git repo root), if any.
    let projectDirectory: String?
    var dbPath: String { teamDir.appendingPathComponent("team.db").path }
    let dbQueue: DatabaseQueue

    /// Create or open a team using the flat model: ~/.pecan/teams/{name}/
    /// In this model, the team IS the project workspace. `projectDirectory` is stored in metadata.
    init(name: String, projectDirectory: String? = nil) throws {
        self.teamName = name
        self.projectName = name  // team name == project name in flat model
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let teamDir = homeDir.appendingPathComponent(".pecan/teams/\(name)")
        self.teamDir = teamDir
        self.workspacePath = teamDir.appendingPathComponent("workspace")

        let fm = FileManager.default
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)

        let dbPath = teamDir.appendingPathComponent("team.db").path
        let isNew = !fm.fileExists(atPath: dbPath)
        self.dbQueue = try DatabaseQueue(path: dbPath)

        if isNew {
            self.projectDirectory = projectDirectory
            try migrate()
            try writeMetadata(projectDirectory: projectDirectory)
        } else {
            self.projectDirectory = try dbQueue.read { db in
                try MetadataRecord.fetchOne(db, key: "project_directory")?.value
            }
        }
    }

    /// Create or open a team store within a project (legacy nested model).
    /// Stored at ~/.pecan/projects/{projectName}/teams/{teamName}/team.db
    init(teamName: String, projectName: String) throws {
        self.teamName = teamName
        self.projectName = projectName
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let teamDir = homeDir.appendingPathComponent(".pecan/projects/\(projectName)/teams/\(teamName)")
        self.teamDir = teamDir
        self.workspacePath = teamDir.appendingPathComponent("workspace")

        let fm = FileManager.default
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)

        let dbPath = teamDir.appendingPathComponent("team.db").path
        let isNew = !fm.fileExists(atPath: dbPath)
        self.dbQueue = try DatabaseQueue(path: dbPath)
        self.projectDirectory = nil  // legacy model: directory comes from ProjectStore

        if isNew {
            try migrate()
            try writeLegacyMetadata()
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try migrateCommonTables(db)
        }
    }

    private func writeMetadata(projectDirectory: String?) throws {
        try dbQueue.write { db in
            try MetadataRecord(key: "name", value: teamName).insert(db)
            try MetadataRecord(key: "created_at", value: ISO8601DateFormatter().string(from: Date())).insert(db)
            if let dir = projectDirectory {
                try MetadataRecord(key: "project_directory", value: dir).insert(db)
            }
        }
    }

    private func writeLegacyMetadata() throws {
        try dbQueue.write { db in
            try MetadataRecord(key: "name", value: teamName).insert(db)
            try MetadataRecord(key: "project", value: projectName).insert(db)
            try MetadataRecord(key: "created_at", value: ISO8601DateFormatter().string(from: Date())).insert(db)
        }
    }

    /// Update the project directory associated with this team.
    func setProjectDirectory(_ path: String) throws {
        try dbQueue.write { db in
            let existing = try MetadataRecord.fetchOne(db, key: "project_directory")
            if existing != nil {
                try db.execute(sql: "UPDATE metadata SET value = ? WHERE key = 'project_directory'", arguments: [path])
            } else {
                try MetadataRecord(key: "project_directory", value: path).insert(db)
            }
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

    // MARK: - ScopedStore: Memory FUSE

    func listTags() throws -> [String] {
        try ScopedStoreCRUD.listTags(dbQueue: dbQueue)
    }

    func renderTag(tag: String) throws -> String {
        try ScopedStoreCRUD.renderTag(dbQueue: dbQueue, tag: tag)
    }

    func applyMemoryDiff(tag: String, content: String) throws {
        try ScopedStoreCRUD.applyMemoryDiff(dbQueue: dbQueue, tag: tag, content: content)
    }

    func appendMemory(tag: String, content: String) throws {
        try ScopedStoreCRUD.appendMemory(dbQueue: dbQueue, tag: tag, content: content)
    }

    func unlinkTag(tag: String) throws {
        try ScopedStoreCRUD.unlinkTag(dbQueue: dbQueue, tag: tag)
    }

    func renameTag(from: String, to: String) throws {
        try ScopedStoreCRUD.renameTag(dbQueue: dbQueue, from: from, to: to)
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

struct TeamRegistry {
    /// Flat teams directory (new model: team = project workspace).
    static var teamsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/teams")
    }

    /// List all teams in the flat ~/.pecan/teams/ directory.
    static func listAllTeamNames() -> [String] {
        let fm = FileManager.default
        let dir = teamsDir
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return contents.filter { name in
            let dbPath = dir.appendingPathComponent(name).appendingPathComponent("team.db").path
            return fm.fileExists(atPath: dbPath)
        }.sorted()
    }

    /// Legacy: scan teams within a project directory.
    static func legacyTeamsDir(projectName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/projects/\(projectName)/teams")
    }

    /// Legacy: list team names nested under a project.
    static func listTeamNames(projectName: String) -> [String] {
        let fm = FileManager.default
        let dir = legacyTeamsDir(projectName: projectName)
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return contents.filter { name in
            let dbPath = dir.appendingPathComponent(name).appendingPathComponent("team.db").path
            return fm.fileExists(atPath: dbPath)
        }.sorted()
    }
}
