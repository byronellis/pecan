import Foundation
import GRPC
import NIO
import PecanShared
import PecanServerCore
import Logging

actor SessionManager {
    static let shared = SessionManager()

    // MARK: - Internal grouped state

    /// Per-session stream and transient communication state.
    private struct StreamState {
        var uiStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>?
        var agentStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>?
        var pendingCommands: [Pecan_HostCommand] = []
        var isBusy: Bool = false
    }

    /// All durable metadata for a session — replaces 11 separate flat dictionaries.
    private struct SessionRecord {
        var store: SessionStore
        var agentName: String = ""
        var projectName: String?
        var teamName: String?
        var networkEnabled: Bool = false
        var persistent: Bool = false
        var mergeID: String?
        var gitBaseCommit: String?
        var startTime: Date = Date()
        var lastPromptTokens: Int = 0
        var knownContextWindow: Int = 0
        var lastModelKey: String = ""
        var modelOverride: String? = nil  // user-set override for this session
        var agentNumber: Int32 = 0
    }

    // 4 dictionaries instead of 15
    private var sessions: [String: SessionRecord] = [:]
    private var nextAgentNumber: Int32 = 1
    private var streams: [String: StreamState] = [:]

    // Shared stores keyed by name (multiple sessions can reference the same project/team)
    private var projectStores: [String: ProjectStore] = [:]
    private var teamStores: [String: TeamStore] = [:]  // keyed by team name (flat model)

    // MARK: - Stream registration

    func registerUI(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>) {
        streams[sessionID, default: StreamState()].uiStream = stream
    }

    func registerAgent(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>) {
        var state = streams[sessionID] ?? StreamState()
        let queued = state.pendingCommands
        state.agentStream = stream
        state.isBusy = false
        state.pendingCommands = []
        streams[sessionID] = state

        if !queued.isEmpty {
            logger.info("Delivering \(queued.count) queued command(s) to newly registered agent for session \(sessionID)")
            Task {
                for cmd in queued {
                    try? await stream.send(cmd)
                }
            }
        }
    }

    // MARK: - Session store

    func setStore(sessionID: String, store: SessionStore) {
        let agentName = (try? store.name) ?? ""
        if sessions[sessionID] != nil {
            sessions[sessionID]!.store = store
            if !agentName.isEmpty { sessions[sessionID]!.agentName = agentName }
        } else {
            // Restore persisted agent number, or assign a new one
            let existingNumber = store.getAgentNumber()
            let assignedNumber: Int32
            if let n = existingNumber, n > 0 {
                assignedNumber = n
                if n >= nextAgentNumber { nextAgentNumber = n + 1 }
            } else {
                assignedNumber = nextAgentNumber
                nextAgentNumber += 1
                try? store.setAgentNumber(assignedNumber)
            }
            var record = SessionRecord(store: store, agentName: agentName)
            record.agentNumber = assignedNumber
            sessions[sessionID] = record
            streams[sessionID] = StreamState()
        }
    }

    func getAgentNumber(sessionID: String) -> Int32 {
        sessions[sessionID]?.agentNumber ?? 0
    }

    func renumberSession(sessionID: String, newNumber: Int32) {
        guard sessions[sessionID] != nil else { return }
        // Swap with any session that already holds newNumber
        if let conflictID = sessions.first(where: { $0.value.agentNumber == newNumber && $0.key != sessionID })?.key {
            let oldNumber = sessions[sessionID]!.agentNumber
            sessions[conflictID]!.agentNumber = oldNumber
            try? sessions[conflictID]!.store.setAgentNumber(oldNumber)
        }
        sessions[sessionID]!.agentNumber = newNumber
        try? sessions[sessionID]!.store.setAgentNumber(newNumber)
        // Keep nextAgentNumber ahead of all assigned numbers
        if newNumber >= nextAgentNumber { nextAgentNumber = newNumber + 1 }
    }

    func getStore(sessionID: String) -> SessionStore? {
        sessions[sessionID]?.store
    }

    // MARK: - Project / team associations

    func setProjectForSession(sessionID: String, projectName: String, store: ProjectStore) {
        sessions[sessionID]?.projectName = projectName
        projectStores[projectName] = store
    }

    /// Set the team for a session (flat model: team IS the project workspace).
    func setTeamForSession(sessionID: String, teamName: String, store: TeamStore) {
        sessions[sessionID]?.teamName = teamName
        sessions[sessionID]?.projectName = teamName  // team name == project name
        teamStores[teamName] = store
    }

    /// Legacy overload — kept for call sites that still pass projectName.
    func setTeamForSession(sessionID: String, teamName: String, projectName: String, store: TeamStore) {
        sessions[sessionID]?.teamName = teamName
        sessions[sessionID]?.projectName = teamName  // team name IS the project now
        teamStores[teamName] = store
    }

    func getProjectName(sessionID: String) -> String? {
        sessions[sessionID]?.projectName
    }

    func getTeamName(sessionID: String) -> String? {
        sessions[sessionID]?.teamName
    }

    func getProjectStore(sessionID: String) -> ProjectStore? {
        guard let name = sessions[sessionID]?.projectName else { return nil }
        return projectStores[name]
    }

    func getProjectDirectory(sessionID: String) -> String? {
        // In the flat model, the project directory is stored in the team store.
        if let dir = getTeamStore(sessionID: sessionID)?.projectDirectory { return dir }
        // Fall back to legacy ProjectStore.
        return getProjectStore(sessionID: sessionID)?.directory
    }

    func getTeamStore(sessionID: String) -> TeamStore? {
        guard let teamName = sessions[sessionID]?.teamName else { return nil }
        return teamStores[teamName]
    }

    func clearProjectForSession(sessionID: String) {
        sessions[sessionID]?.projectName = nil
        sessions[sessionID]?.teamName = nil
    }

    func clearTeamForSession(sessionID: String) {
        sessions[sessionID]?.teamName = nil
    }

    /// Resolve a store for a given scope, with optional explicit target name.
    /// scope "t", "team", "p", or "project" -> team store (team IS the project workspace)
    /// empty or "agent" -> session store
    func resolveStore(sessionID: String, scope: String, target: String? = nil) -> ScopedStore? {
        switch scope {
        case "p", "project", "t", "team":
            if let target = target, !target.isEmpty {
                // Look up the named team store directly
                return teamStores[target]
            }
            return getTeamStore(sessionID: sessionID)
        default:
            return sessions[sessionID]?.store
        }
    }

    /// Returns the appropriate store for the given scope relative to a session.
    func storeForScope(sessionID: String, scope: String) -> ScopedStore? {
        switch scope {
        case "project", "team":
            // Team IS the project workspace in the flat model.
            return getTeamStore(sessionID: sessionID)
        default:
            return sessions[sessionID]?.store
        }
    }

    // MARK: - Messaging

    func sendToUI(sessionID: String, message: Pecan_ServerMessage) async throws {
        if let stream = streams[sessionID]?.uiStream {
            try await stream.send(message)
        } else {
            logger.warning("No UI stream found for session \(sessionID)")
        }
    }

    func sendToAgent(sessionID: String, command: Pecan_HostCommand) async throws {
        if let stream = streams[sessionID]?.agentStream {
            try await stream.send(command)
        } else {
            logger.warning("No Agent stream yet for session \(sessionID) — queuing command for delivery on connect")
            streams[sessionID, default: StreamState()].pendingCommands.append(command)
        }
    }

    // MARK: - Agent state

    func hasAgent(sessionID: String) -> Bool {
        streams[sessionID]?.agentStream != nil
    }

    func setAgentBusy(sessionID: String, busy: Bool) {
        streams[sessionID]?.isBusy = busy
    }

    func isAgentBusy(sessionID: String) -> Bool {
        streams[sessionID]?.isBusy ?? false
    }

    // MARK: - Token usage tracking

    func updateTokenUsage(sessionID: String, promptTokens: Int, contextWindow: Int, modelKey: String = "") {
        sessions[sessionID]?.lastPromptTokens = promptTokens
        if contextWindow > 0 { sessions[sessionID]?.knownContextWindow = contextWindow }
        if !modelKey.isEmpty { sessions[sessionID]?.lastModelKey = modelKey }
    }

    func getTokenUsage(sessionID: String) -> (promptTokens: Int, contextWindow: Int) {
        guard let record = sessions[sessionID] else { return (0, 0) }
        return (record.lastPromptTokens, record.knownContextWindow)
    }

    func setModelOverride(sessionID: String, modelKey: String?) {
        sessions[sessionID]?.modelOverride = modelKey
    }

    func getModelOverride(sessionID: String) -> String? {
        return sessions[sessionID]?.modelOverride
    }

    // MARK: - Context inspection

    struct ContextSectionStats: Sendable {
        var messageCount: Int = 0
        var characterCount: Int = 0
    }

    struct ContextStats: Sendable {
        var sections: [Int: ContextSectionStats] = [:]
    }

    struct ContextMessage: Sendable {
        let role: String
        let content: String
    }

    func getContextStats(sessionID: String) -> ContextStats {
        guard let store = sessions[sessionID]?.store,
              let records = try? store.getContextMessages() else { return ContextStats() }
        var stats = ContextStats()
        for msg in records {
            stats.sections[msg.section, default: ContextSectionStats()].messageCount += 1
            stats.sections[msg.section, default: ContextSectionStats()].characterCount += msg.content.count
        }
        return stats
    }

    func getSystemMessages(sessionID: String) -> [ContextMessage] {
        guard let store = sessions[sessionID]?.store,
              let records = try? store.getContextMessages() else { return [] }
        return records.filter { $0.section == 0 }.map { ContextMessage(role: $0.role, content: $0.content) }
    }

    func getSessionMeta(sessionID: String) -> (agentName: String, teamName: String?, projectDir: String?, networkEnabled: Bool, persistent: Bool, startTime: Date, lastModelKey: String) {
        guard let record = sessions[sessionID] else {
            return ("", nil, nil, false, false, Date(), "")
        }
        let projectDir: String?
        if let teamStore = getTeamStore(sessionID: sessionID) {
            projectDir = teamStore.projectDirectory
        } else if let projectStore = getProjectStore(sessionID: sessionID) {
            projectDir = projectStore.directory
        } else {
            projectDir = nil
        }
        return (record.agentName, record.teamName, projectDir, record.networkEnabled, record.persistent, record.startTime, record.lastModelKey)
    }

    // MARK: - Merge state

    func isMerging(sessionID: String) -> Bool {
        sessions[sessionID]?.mergeID != nil
    }

    func setMerging(sessionID: String, mergeID: String) {
        sessions[sessionID]?.mergeID = mergeID
    }

    func clearMerging(sessionID: String, mergeStatus: String) {
        sessions[sessionID]?.mergeID = nil
        Task {
            try? await self.sendSessionUpdateToUI(sessionID: sessionID, mergeStatus: mergeStatus)
        }
    }

    // MARK: - Git / network / persistence flags

    func setGitBase(sessionID: String, commit: String?) {
        sessions[sessionID]?.gitBaseCommit = commit
    }

    func gitBase(sessionID: String) -> String? {
        sessions[sessionID]?.gitBaseCommit
    }

    func setNetworkEnabled(sessionID: String, enabled: Bool) {
        sessions[sessionID]?.networkEnabled = enabled
    }

    func isNetworkEnabled(sessionID: String) -> Bool {
        sessions[sessionID]?.networkEnabled ?? false
    }

    func markPersistent(_ sessionID: String) {
        sessions[sessionID]?.persistent = true
    }

    func isPersistent(_ sessionID: String) -> Bool {
        sessions[sessionID]?.persistent ?? false
    }

    func detachUI(sessionID: String) {
        streams[sessionID]?.uiStream = nil
    }

    // MARK: - Env snapshot paths

    /// Returns (creating if needed) the host directory mounted read-only at /tmp/pecan-mounts.
    /// Contains env.tar if a snapshot has been saved. Per-team when active; per-session otherwise.
    func persistEnvDir(sessionID: String) -> String? {
        let fm = FileManager.default
        let path: String
        if let teamStore = getTeamStore(sessionID: sessionID) {
            path = teamStore.teamDir.appendingPathComponent("env").path
        } else if let projectStore = getProjectStore(sessionID: sessionID) {
            // Legacy fallback
            path = projectStore.projectDir.appendingPathComponent("env").path
        } else if let store = sessions[sessionID]?.store {
            path = store.workspacePath.appendingPathComponent(".pecan/env").path
        } else {
            return nil
        }
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        return path
    }

    /// Returns the host path for the saved env.tar snapshot, or nil if no session found.
    func persistEnvTarPath(sessionID: String) -> String? {
        guard let dir = persistEnvDir(sessionID: sessionID) else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent("env.tar").path
    }

    private func sectionToInt(_ section: Pecan_ContextSection) -> Int {
        switch section {
        case .system: return 0
        case .conversation: return 1
        case .tools: return 2
        case .UNRECOGNIZED(let v): return v
        }
    }

    func addContextMessage(sessionID: String, section: Pecan_ContextSection, role: String, content: String, metadata: String) {
        guard let store = sessions[sessionID]?.store else {
            logger.warning("No session store for \(sessionID)")
            return
        }
        do {
            try store.addContextMessage(section: sectionToInt(section), role: role, content: content, metadata: metadata)
        } catch {
            logger.error("Failed to persist context message for \(sessionID): \(error)")
        }
    }

    func getContext(sessionID: String) async throws -> Data {
        guard let store = sessions[sessionID]?.store else {
            return try JSONSerialization.data(withJSONObject: [] as [[String: Any]])
        }
        let records = try store.getContextMessages()
        var messages: [[String: Any]] = []
        for msg in records {
            var dict: [String: Any] = ["role": msg.role, "content": msg.content]
            if !msg.metadataJson.isEmpty,
               let data = msg.metadataJson.data(using: .utf8),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in meta {
                    dict[k] = v
                }
            }
            messages.append(dict)
        }
        return try JSONSerialization.data(withJSONObject: messages)
    }

    func compactContext(sessionID: String, section: Pecan_ContextSection, keepRecent: Int) {
        guard let store = sessions[sessionID]?.store else { return }
        do {
            try store.compactContext(section: sectionToInt(section), keepRecent: keepRecent)
        } catch {
            logger.error("Failed to compact context for \(sessionID): \(error)")
        }
    }

    func handleTaskCommand(sessionID: String, action: String, payloadJSON: String, scope: String = "") async throws -> String {
        let payload: [String: Any]
        if let data = payloadJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = obj
        } else {
            payload = [:]
        }

        // Handle project/team management actions (not scoped to a store)
        switch action {
        case "project_create":
            guard let name = payload["name"] as? String, !name.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project/team name"])
            }
            let directory = payload["directory"] as? String
            let store = try TeamStore(name: name, projectDirectory: directory)
            teamStores[name] = store
            let result: [String: Any] = ["name": name, "directory": directory ?? "", "ok": true]
            let data = try JSONSerialization.data(withJSONObject: result)
            return String(data: data, encoding: .utf8) ?? "{}"

        case "project_list":
            let names = TeamRegistry.listAllTeamNames()
            var projects: [[String: Any]] = []
            for name in names {
                var info: [String: Any] = ["name": name]
                if let store = teamStores[name] {
                    info["directory"] = store.projectDirectory ?? ""
                } else if let store = try? TeamStore(name: name) {
                    info["directory"] = store.projectDirectory ?? ""
                }
                projects.append(info)
            }
            let data = try JSONSerialization.data(withJSONObject: projects)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "project_get":
            guard let name = payload["name"] as? String, !name.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project/team name"])
            }
            let store = try TeamStore(name: name)
            let result: [String: Any] = ["name": name, "directory": store.projectDirectory ?? ""]
            let data = try JSONSerialization.data(withJSONObject: result)
            return String(data: data, encoding: .utf8) ?? "{}"

        case "team_create":
            guard let teamName = payload["name"] as? String, !teamName.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing team name"])
            }
            let directory = payload["directory"] as? String
            let store = try TeamStore(name: teamName, projectDirectory: directory)
            teamStores[teamName] = store
            let result: [String: Any] = ["name": teamName, "ok": true]
            let data = try JSONSerialization.data(withJSONObject: result)
            return String(data: data, encoding: .utf8) ?? "{}"

        case "team_list":
            let names = TeamRegistry.listAllTeamNames()
            let teams = names.map { ["name": $0] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: teams)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "team_get":
            guard let teamName = payload["name"] as? String, !teamName.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing team name"])
            }
            let store = try TeamStore(name: teamName)
            let result: [String: Any] = ["name": teamName, "directory": store.projectDirectory ?? "", "workspace": store.workspacePath.path]
            let data = try JSONSerialization.data(withJSONObject: result)
            return String(data: data, encoding: .utf8) ?? "{}"

        default:
            break  // Fall through to scoped store dispatch below
        }

        // For "list" action with no explicit scope, merge results from all available scopes
        if action == "list" && (scope.isEmpty || scope == "agent") {
            return try handleMergedTaskList(sessionID: sessionID, payload: payload)
        }
        // Resolve store by scope
        let resolvedScope = scope.isEmpty ? "agent" : scope
        guard let store = storeForScope(sessionID: sessionID, scope: resolvedScope) else {
            if resolvedScope == "project" {
                throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No project context for this session"])
            } else if resolvedScope == "team" {
                throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No team context for this session"])
            }
            throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No session store for \(sessionID)"])
        }

        return try await dispatchToStore(store: store, sessionID: sessionID, action: action, payload: payload, scope: resolvedScope)
    }

    /// Dispatch a task/memory/trigger action to a specific ScopedStore.
    private func dispatchToStore(store: ScopedStore, sessionID: String, action: String, payload: [String: Any], scope: String) async throws -> String {
        switch action {
        case "create":
            guard let title = payload["title"] as? String, !title.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing title"])
            }
            let task = try store.createTask(
                title: title,
                description: payload["description"] as? String ?? "",
                priority: payload["priority"] as? Int ?? 3,
                severity: payload["severity"] as? String ?? "normal",
                labels: payload["labels"] as? String ?? "",
                dueDate: payload["due_date"] as? String ?? "",
                dependsOn: payload["depends_on"] as? String ?? ""
            )
            return try taskToJSON(task, scope: scope)

        case "list":
            let tasks = try store.listTasks(
                status: payload["status"] as? String,
                label: payload["label"] as? String,
                search: payload["search"] as? String
            )
            let dicts = tasks.map { taskToDict($0, scope: scope) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "get":
            guard let taskID = taskIDFromPayload(payload) else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing task_id"])
            }
            guard let task = try store.getTask(id: taskID) else {
                throw NSError(domain: "TaskCommand", code: 4, userInfo: [NSLocalizedDescriptionKey: "Task #\(taskID) not found"])
            }
            return try taskToJSON(task, scope: scope)

        case "update":
            guard let taskID = taskIDFromPayload(payload) else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing task_id"])
            }
            var fields = payload
            fields.removeValue(forKey: "task_id")
            let task = try store.updateTask(id: taskID, fields: fields)
            return try taskToJSON(task, scope: scope)

        case "focus":
            let taskID = taskIDFromPayload(payload) ?? 0
            try store.setFocused(taskID: taskID)
            let focused = try store.getFocusedTask()
            try await sendTaskUpdateToUI(sessionID: sessionID, focusedTitle: focused?.title ?? "")
            return "{\"ok\":true}"

        // MARK: Trigger actions (session-only)

        case "trigger_create":
            guard let sessionStore = store as? SessionStore else {
                throw NSError(domain: "TaskCommand", code: 5, userInfo: [NSLocalizedDescriptionKey: "Triggers are only available at agent scope"])
            }
            guard let instruction = payload["instruction"] as? String, !instruction.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing instruction"])
            }
            guard let fireAt = payload["fire_at"] as? String, !fireAt.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing fire_at"])
            }
            let interval = payload["interval_seconds"] as? Int ?? 0
            let trigger = try sessionStore.createTrigger(instruction: instruction, fireAt: fireAt, intervalSeconds: interval)
            return try triggerToJSON(trigger)

        case "trigger_list":
            guard let sessionStore = store as? SessionStore else {
                throw NSError(domain: "TaskCommand", code: 5, userInfo: [NSLocalizedDescriptionKey: "Triggers are only available at agent scope"])
            }
            let status = payload["status"] as? String
            let triggers = try sessionStore.listTriggers(status: status)
            let dicts = triggers.map { triggerToDict($0) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "trigger_cancel":
            guard let sessionStore = store as? SessionStore else {
                throw NSError(domain: "TaskCommand", code: 5, userInfo: [NSLocalizedDescriptionKey: "Triggers are only available at agent scope"])
            }
            guard let triggerID = idFromPayload(payload, key: "trigger_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing trigger_id"])
            }
            try sessionStore.cancelTrigger(id: triggerID)
            return "{\"ok\":true}"

        default:
            throw NSError(domain: "TaskCommand", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(action)"])
        }
    }

    /// Merged task list: collects tasks from agent, team, and project scopes.
    private func handleMergedTaskList(sessionID: String, payload: [String: Any]) throws -> String {
        var allTasks: [[String: Any]] = []

        if let store = sessions[sessionID]?.store {
            let tasks = try store.listTasks(
                status: payload["status"] as? String,
                label: payload["label"] as? String,
                search: payload["search"] as? String
            )
            allTasks.append(contentsOf: tasks.map { taskToDict($0, scope: "agent") })
        }

        // Team IS the project workspace — query once under the "team" scope label.
        if let store = getTeamStore(sessionID: sessionID) {
            let tasks = try store.listTasks(
                status: payload["status"] as? String,
                label: payload["label"] as? String,
                search: payload["search"] as? String
            )
            allTasks.append(contentsOf: tasks.map { taskToDict($0, scope: "team") })
        }

        let data = try JSONSerialization.data(withJSONObject: allTasks)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Merged memory list: collects memories from agent, team, and project scopes.
    private func taskIDFromPayload(_ payload: [String: Any]) -> Int64? {
        if let id = payload["task_id"] as? Int64 { return id }
        if let id = payload["task_id"] as? Int { return Int64(id) }
        if let id = payload["task_id"] as? Double { return Int64(id) }
        return nil
    }

    private func taskToDict(_ task: TaskRecord, scope: String = "agent") -> [String: Any] {
        return [
            "id": Int(task.id ?? 0),
            "title": task.title,
            "description": task.description,
            "status": task.status,
            "priority": task.priority,
            "severity": task.severity,
            "labels": task.labels,
            "due_date": task.dueDate,
            "depends_on": task.dependsOn,
            "focused": task.focused == 1,
            "created_at": task.createdAt,
            "updated_at": task.updatedAt,
            "scope": scope
        ]
    }

    private func taskToJSON(_ task: TaskRecord, scope: String = "agent") throws -> String {
        let dict = taskToDict(task, scope: scope)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func idFromPayload(_ payload: [String: Any], key: String) -> Int64? {
        if let id = payload[key] as? Int64 { return id }
        if let id = payload[key] as? Int { return Int64(id) }
        if let id = payload[key] as? Double { return Int64(id) }
        return nil
    }

    private func triggerToDict(_ trigger: TriggerRecord) -> [String: Any] {
        return [
            "id": Int(trigger.id ?? 0),
            "instruction": trigger.instruction,
            "fire_at": trigger.fireAt,
            "interval_seconds": trigger.intervalSeconds,
            "status": trigger.status,
            "pending_delivery": trigger.pendingDelivery == 1,
            "created_at": trigger.createdAt,
            "updated_at": trigger.updatedAt
        ]
    }

    private func triggerToJSON(_ trigger: TriggerRecord) throws -> String {
        let dict = triggerToDict(trigger)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func sendSessionUpdateToUI(sessionID: String, mergeStatus: String = "") async throws {
        let projectName = sessions[sessionID]?.projectName ?? ""
        let teamName = sessions[sessionID]?.teamName ?? ""
        var srvMsg = Pecan_ServerMessage()
        var update = Pecan_SessionUpdate()
        update.sessionID = sessionID
        update.projectName = projectName
        update.teamName = teamName
        update.mergeStatus = mergeStatus
        srvMsg.sessionUpdate = update
        try await sendToUI(sessionID: sessionID, message: srvMsg)
    }

    func sendTaskUpdateToUI(sessionID: String, focusedTitle: String) async throws {
        var srvMsg = Pecan_ServerMessage()
        var update = Pecan_TaskUpdate()
        update.sessionID = sessionID
        update.focusedTaskTitle = focusedTitle
        srvMsg.taskUpdate = update
        try await sendToUI(sessionID: sessionID, message: srvMsg)
    }

    func activeSessionIDs() -> [String] {
        Array(sessions.keys)
    }

    /// Check and deliver pending/due triggers for a session. Call when agent becomes idle.
    func checkAndDeliverTriggers(sessionID: String) async {
        guard !isAgentBusy(sessionID: sessionID),
              let store = sessions[sessionID]?.store else { return }

        do {
            // First check for already-pending triggers
            let pending = try store.listTriggers(status: "active").filter { $0.pendingDelivery == 1 }
            if let trigger = pending.first {
                try await deliverTrigger(sessionID: sessionID, trigger: trigger)
                return
            }

            // Then check for newly-due triggers
            let due = try store.getDueTriggers()
            if let trigger = due.first {
                try store.markTriggerPending(id: trigger.id!)
                try await deliverTrigger(sessionID: sessionID, trigger: trigger)
            }
        } catch {
            logger.error("Trigger check failed for session \(sessionID): \(error)")
        }
    }

    private func deliverTrigger(sessionID: String, trigger: TriggerRecord) async throws {
        guard let store = sessions[sessionID]?.store else { return }

        var cmdMsg = Pecan_HostCommand()
        var processInput = Pecan_ProcessInput()
        processInput.text = "[Scheduled Trigger #\(trigger.id ?? 0)] \(trigger.instruction)"
        cmdMsg.processInput = processInput
        try await sendToAgent(sessionID: sessionID, command: cmdMsg)

        setAgentBusy(sessionID: sessionID, busy: true)
        try store.completeTriggerDelivery(id: trigger.id!)
    }

    func getAgentName(sessionID: String) -> String? {
        sessions[sessionID]?.agentName
    }

    func allLiveSessions() -> [Pecan_SessionInfo] {
        let iso = ISO8601DateFormatter()
        return sessions.map { (sid, record) in
            var info = Pecan_SessionInfo()
            info.sessionID = sid
            info.agentName = record.agentName
            info.projectName = record.projectName ?? ""
            info.teamName = record.teamName ?? ""
            info.isBusy = streams[sid]?.isBusy ?? false
            info.startedAt = iso.string(from: record.startTime)
            info.agentNumber = record.agentNumber
            return info
        }.sorted { $0.agentNumber < $1.agentNumber }
    }

    func broadcastSessionList() async throws {
        var msg = Pecan_ServerMessage()
        var list = Pecan_SessionList()
        list.sessions = allLiveSessions()
        msg.sessionList = list
        for sid in sessions.keys {
            try? await sendToUI(sessionID: sid, message: msg)
        }
    }

    /// Build the running-sessions index for pecan-shell name lookup.
    func flushRunningIndex() {
        let iso = ISO8601DateFormatter()
        let metas = sessions.map { (sid, record) in
            SessionMeta(
                sessionID: sid,
                agentName: record.agentName,
                projectName: record.projectName ?? "",
                teamName: record.teamName ?? "",
                networkEnabled: record.networkEnabled,
                persistent: record.persistent,
                startedAt: iso.string(from: record.startTime)
            )
        }
        SessionMeta.writeRunningIndex(metas)
    }

    func removeSession(sessionID: String) async {
        sessions.removeValue(forKey: sessionID)
        streams.removeValue(forKey: sessionID)

        // Remove persisted metadata so this session won't be respawned after restart
        SessionMeta.delete(sessionID: sessionID)
        flushRunningIndex()

        do {
            try await SpawnerFactory.shared.terminate(sessionID: sessionID)
        } catch {
            logger.error("Failed to terminate agent VM for session \(sessionID): \(error)")
        }
    }

    /// Restart the container for a session with updated mounts, preserving context.
    /// Compute mounts from current session state and call SpawnerFactory.
    /// Shared by `restartContainer` and `spawnIfNeeded`.
    private func spawnContainer(sessionID: String) async throws {
        guard let record = sessions[sessionID] else {
            throw NSError(domain: "SessionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No session record for \(sessionID)"])
        }
        let store = record.store
        let agentName = try store.name
        let shares = try store.getShares()
        var shareMounts = shares.map { MountSpec(source: $0.hostPath, destination: $0.guestPath, readOnly: $0.mode == "ro") }

        if let teamStore = getTeamStore(sessionID: sessionID) {
            if let dir = teamStore.projectDirectory {
                shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
                setGitBase(sessionID: sessionID, commit: gitHead(for: dir))
            } else if let projectStore = getProjectStore(sessionID: sessionID), let dir = projectStore.directory {
                shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
                setGitBase(sessionID: sessionID, commit: gitHead(for: dir))
            }
            shareMounts.append(MountSpec(source: teamStore.workspacePath.path, destination: "/team", readOnly: false))
        } else if let projectStore = getProjectStore(sessionID: sessionID), let dir = projectStore.directory {
            shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
            setGitBase(sessionID: sessionID, commit: gitHead(for: dir))
        }

        try await SpawnerFactory.shared.spawn(
            sessionID: sessionID,
            agentName: agentName,
            workspacePath: store.workspacePath.path,
            shares: shareMounts,
            networkEnabled: isNetworkEnabled(sessionID: sessionID),
            envMountPath: persistEnvTarPath(sessionID: sessionID) ?? ""
        )
    }

    /// Spawn the container for a session if it doesn't already have a live agent.
    /// Called on reattach for sessions that were loaded at startup but not yet running.
    /// If networking is enabled but vmnet fails, retries without networking and notifies the UI.
    func spawnIfNeeded(sessionID: String) async throws {
        guard !hasAgent(sessionID: sessionID) else { return }
        streams[sessionID, default: StreamState()].agentStream = nil
        streams[sessionID]?.pendingCommands = []
        streams[sessionID]?.isBusy = false

        do {
            try await spawnContainer(sessionID: sessionID)
        } catch where isNetworkEnabled(sessionID: sessionID)
                      && error.localizedDescription.lowercased().contains("vmnet") {
            logger.warning("[\(sessionID)] vmnet error, retrying without network: \(error)")
            sessions[sessionID]?.networkEnabled = false
            try await spawnContainer(sessionID: sessionID)
            var warnMsg = Pecan_ServerMessage()
            var wOut = Pecan_AgentOutput()
            wOut.sessionID = sessionID
            wOut.text = "{\"type\":\"response\",\"text\":\"⚠️ Network unavailable (vmnet error) — started without network access.\"}"
            warnMsg.agentOutput = wOut
            try? await sendToUI(sessionID: sessionID, message: warnMsg)
        }
    }

    func restartContainer(sessionID: String) async throws {
        // Notify UI
        var statusMsg = Pecan_ServerMessage()
        var out = Pecan_AgentOutput()
        out.sessionID = sessionID
        out.text = "Reconfiguring environment..."
        statusMsg.agentOutput = out
        try await sendToUI(sessionID: sessionID, message: statusMsg)

        // Clear stale agent stream and any pending commands so the new agent starts fresh
        streams[sessionID]?.agentStream = nil
        streams[sessionID]?.pendingCommands = []
        streams[sessionID]?.isBusy = false

        try await spawnContainer(sessionID: sessionID)

        // Notify UI
        var readyMsg = Pecan_ServerMessage()
        var readyOut = Pecan_AgentOutput()
        readyOut.sessionID = sessionID
        readyOut.text = "Environment ready."
        readyMsg.agentOutput = readyOut
        try await sendToUI(sessionID: sessionID, message: readyMsg)

        // The old container is cleaned up by the spawner — when spawn is called
        // for a session that already has a running container, it tears down the old one
        // in the background after the new one is up.
    }
}
