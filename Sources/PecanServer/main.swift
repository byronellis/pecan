import Foundation
import GRPC
import NIO
import PecanShared
import Logging

let logger = Logger(label: "com.pecan.server")

actor SessionManager {
    static let shared = SessionManager()

    // sessionID -> (uiStream, agentStream)
    private var uiStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>] = [:]
    private var agentStreams: [String: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>] = [:]

    // Per-session persistent stores
    private var sessionStores: [String: SessionStore] = [:]

    // Agent idle/busy tracking for trigger delivery
    private var agentBusy: [String: Bool] = [:]

    func registerUI(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>) {
        uiStreams[sessionID] = stream
    }

    func registerAgent(sessionID: String, stream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>) {
        agentStreams[sessionID] = stream
    }

    func setStore(sessionID: String, store: SessionStore) {
        sessionStores[sessionID] = store
    }

    func getStore(sessionID: String) -> SessionStore? {
        sessionStores[sessionID]
    }

    func sendToUI(sessionID: String, message: Pecan_ServerMessage) async throws {
        if let stream = uiStreams[sessionID] {
            try await stream.send(message)
        } else {
            logger.warning("No UI stream found for session \(sessionID)")
        }
    }

    func sendToAgent(sessionID: String, command: Pecan_HostCommand) async throws {
        if let stream = agentStreams[sessionID] {
            try await stream.send(command)
        } else {
            logger.warning("No Agent stream found for session \(sessionID)")
        }
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
        guard let store = sessionStores[sessionID] else {
            logger.warning("No session store for \(sessionID)")
            return
        }
        do {
            try store.addContextMessage(section: sectionToInt(section), role: role, content: content, metadata: metadata)
        } catch {
            logger.error("Failed to persist context message for \(sessionID): \(error)")
        }
    }

    func getContext(sessionID: String) throws -> Data {
        guard let store = sessionStores[sessionID] else {
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
        guard let store = sessionStores[sessionID] else { return }
        do {
            try store.compactContext(section: sectionToInt(section), keepRecent: keepRecent)
        } catch {
            logger.error("Failed to compact context for \(sessionID): \(error)")
        }
    }

    func handleTaskCommand(sessionID: String, action: String, payloadJSON: String) async throws -> String {
        guard let store = sessionStores[sessionID] else {
            throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No session store for \(sessionID)"])
        }

        let payload: [String: Any]
        if let data = payloadJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = obj
        } else {
            payload = [:]
        }

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
            return try taskToJSON(task)

        case "list":
            let tasks = try store.listTasks(
                status: payload["status"] as? String,
                label: payload["label"] as? String,
                search: payload["search"] as? String
            )
            let dicts = tasks.map { taskToDict($0) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "get":
            guard let taskID = taskIDFromPayload(payload) else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing task_id"])
            }
            guard let task = try store.getTask(id: taskID) else {
                throw NSError(domain: "TaskCommand", code: 4, userInfo: [NSLocalizedDescriptionKey: "Task #\(taskID) not found"])
            }
            return try taskToJSON(task)

        case "update":
            guard let taskID = taskIDFromPayload(payload) else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing task_id"])
            }
            var fields = payload
            fields.removeValue(forKey: "task_id")
            let task = try store.updateTask(id: taskID, fields: fields)
            return try taskToJSON(task)

        case "focus":
            let taskID = taskIDFromPayload(payload) ?? 0
            try store.setFocused(taskID: taskID)
            // Send TaskUpdate to UI
            let focused = try store.getFocusedTask()
            try await sendTaskUpdateToUI(sessionID: sessionID, focusedTitle: focused?.title ?? "")
            return "{\"ok\":true}"

        // MARK: Memory actions

        case "memory_create":
            guard let content = payload["content"] as? String, !content.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing content"])
            }
            let tags: [String]
            if let tagArr = payload["tags"] as? [String] {
                tags = tagArr
            } else if let tagStr = payload["tags"] as? String, !tagStr.isEmpty {
                tags = tagStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                tags = []
            }
            let memory = try store.createMemory(content: content, tags: tags)
            return try memoryToJSON(memory, tags: tags)

        case "memory_get":
            guard let memID = idFromPayload(payload, key: "memory_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing memory_id"])
            }
            guard let (memory, tags) = try store.getMemory(id: memID) else {
                throw NSError(domain: "TaskCommand", code: 4, userInfo: [NSLocalizedDescriptionKey: "Memory #\(memID) not found"])
            }
            return try memoryToJSON(memory, tags: tags)

        case "memory_list":
            let tag = payload["tag"] as? String
            let memories = try store.listMemories(tag: tag)
            let dicts = memories.map { memoryToDict($0.0, tags: $0.1) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "memory_search":
            guard let query = payload["query"] as? String, !query.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing query"])
            }
            let memories = try store.searchMemories(query: query)
            let dicts = memories.map { memoryToDict($0.0, tags: $0.1) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "memory_update":
            guard let memID = idFromPayload(payload, key: "memory_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing memory_id"])
            }
            guard let content = payload["content"] as? String else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing content"])
            }
            let updated = try store.updateMemory(id: memID, content: content)
            let (_, tags) = try store.getMemory(id: memID) ?? (updated, [])
            return try memoryToJSON(updated, tags: tags)

        case "memory_delete":
            guard let memID = idFromPayload(payload, key: "memory_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing memory_id"])
            }
            try store.deleteMemory(id: memID)
            return "{\"ok\":true}"

        case "memory_tag":
            guard let memID = idFromPayload(payload, key: "memory_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing memory_id"])
            }
            guard let tag = payload["tag"] as? String, !tag.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing tag"])
            }
            try store.addMemoryTag(memoryId: memID, tag: tag)
            return "{\"ok\":true}"

        case "memory_untag":
            guard let memID = idFromPayload(payload, key: "memory_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing memory_id"])
            }
            guard let tag = payload["tag"] as? String, !tag.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing tag"])
            }
            try store.removeMemoryTag(memoryId: memID, tag: tag)
            return "{\"ok\":true}"

        // MARK: Trigger actions

        case "trigger_create":
            guard let instruction = payload["instruction"] as? String, !instruction.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing instruction"])
            }
            guard let fireAt = payload["fire_at"] as? String, !fireAt.isEmpty else {
                throw NSError(domain: "TaskCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing fire_at"])
            }
            let interval = payload["interval_seconds"] as? Int ?? 0
            let trigger = try store.createTrigger(instruction: instruction, fireAt: fireAt, intervalSeconds: interval)
            return try triggerToJSON(trigger)

        case "trigger_list":
            let status = payload["status"] as? String
            let triggers = try store.listTriggers(status: status)
            let dicts = triggers.map { triggerToDict($0) }
            let data = try JSONSerialization.data(withJSONObject: dicts)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "trigger_cancel":
            guard let triggerID = idFromPayload(payload, key: "trigger_id") else {
                throw NSError(domain: "TaskCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing trigger_id"])
            }
            try store.cancelTrigger(id: triggerID)
            return "{\"ok\":true}"

        default:
            throw NSError(domain: "TaskCommand", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(action)"])
        }
    }

    private func taskIDFromPayload(_ payload: [String: Any]) -> Int64? {
        if let id = payload["task_id"] as? Int64 { return id }
        if let id = payload["task_id"] as? Int { return Int64(id) }
        if let id = payload["task_id"] as? Double { return Int64(id) }
        return nil
    }

    private func taskToDict(_ task: TaskRecord) -> [String: Any] {
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
            "updated_at": task.updatedAt
        ]
    }

    private func taskToJSON(_ task: TaskRecord) throws -> String {
        let dict = taskToDict(task)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func idFromPayload(_ payload: [String: Any], key: String) -> Int64? {
        if let id = payload[key] as? Int64 { return id }
        if let id = payload[key] as? Int { return Int64(id) }
        if let id = payload[key] as? Double { return Int64(id) }
        return nil
    }

    private func memoryToDict(_ memory: MemoryRecord, tags: [String]) -> [String: Any] {
        return [
            "id": Int(memory.id ?? 0),
            "content": memory.content,
            "tags": tags,
            "created_at": memory.createdAt,
            "updated_at": memory.updatedAt
        ]
    }

    private func memoryToJSON(_ memory: MemoryRecord, tags: [String]) throws -> String {
        let dict = memoryToDict(memory, tags: tags)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
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

    func sendTaskUpdateToUI(sessionID: String, focusedTitle: String) async throws {
        var srvMsg = Pecan_ServerMessage()
        var update = Pecan_TaskUpdate()
        update.sessionID = sessionID
        update.focusedTaskTitle = focusedTitle
        srvMsg.taskUpdate = update
        try await sendToUI(sessionID: sessionID, message: srvMsg)
    }

    func setAgentBusy(sessionID: String, busy: Bool) {
        agentBusy[sessionID] = busy
    }

    func isAgentBusy(sessionID: String) -> Bool {
        agentBusy[sessionID] ?? false
    }

    func activeSessionIDs() -> [String] {
        Array(sessionStores.keys)
    }

    /// Check and deliver pending/due triggers for a session. Call when agent becomes idle.
    func checkAndDeliverTriggers(sessionID: String) async {
        guard !isAgentBusy(sessionID: sessionID),
              let store = sessionStores[sessionID] else { return }

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
        guard let store = sessionStores[sessionID] else { return }

        var cmdMsg = Pecan_HostCommand()
        var processInput = Pecan_ProcessInput()
        processInput.text = "[Scheduled Trigger #\(trigger.id ?? 0)] \(trigger.instruction)"
        cmdMsg.processInput = processInput
        try await sendToAgent(sessionID: sessionID, command: cmdMsg)

        setAgentBusy(sessionID: sessionID, busy: true)
        try store.completeTriggerDelivery(id: trigger.id!)
    }

    func removeSession(sessionID: String) async {
        uiStreams.removeValue(forKey: sessionID)
        agentStreams.removeValue(forKey: sessionID)
        sessionStores.removeValue(forKey: sessionID)

        do {
            try await SpawnerFactory.shared.terminate(sessionID: sessionID)
        } catch {
            logger.error("Failed to terminate agent VM for session \(sessionID): \(error)")
        }
    }

    /// Restart the container for a session with updated mounts, preserving context.
    func restartContainer(sessionID: String) async throws {
        guard let store = sessionStores[sessionID] else {
            throw NSError(domain: "SessionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "No session store for \(sessionID)"])
        }

        // Notify UI
        var statusMsg = Pecan_ServerMessage()
        var out = Pecan_AgentOutput()
        out.sessionID = sessionID
        out.text = "Reconfiguring environment..."
        statusMsg.agentOutput = out
        try await sendToUI(sessionID: sessionID, message: statusMsg)

        // Terminate current container
        try await SpawnerFactory.shared.terminate(sessionID: sessionID)

        // Read current state from SQLite
        let agentName = try store.name
        let shares = try store.getShares()
        let shareMounts = shares.map { MountSpec(source: $0.hostPath, destination: $0.guestPath, readOnly: $0.mode == "ro") }

        // Respawn with updated mounts
        try await SpawnerFactory.shared.spawn(
            sessionID: sessionID,
            agentName: agentName,
            workspacePath: store.workspacePath.path,
            shares: shareMounts
        )

        // Notify UI
        var readyMsg = Pecan_ServerMessage()
        var readyOut = Pecan_AgentOutput()
        readyOut.sessionID = sessionID
        readyOut.text = "Environment ready."
        readyMsg.agentOutput = readyOut
        try await sendToUI(sessionID: sessionID, message: readyMsg)
    }
}

final class ClientServiceProvider: Pecan_ClientServiceAsyncProvider {
    func streamEvents(
        requestStream: GRPCAsyncRequestStream<Pecan_ClientMessage>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        logger.info("UI Client connected.")
        var activeSessions: Set<String> = []

        do {
            for try await message in requestStream {
                switch message.payload {
                case .startTask(let startReq):
                    let sessionID = UUID().uuidString
                    activeSessions.insert(sessionID)

                    let agentName = AgentNames.randomName()

                    // Create persistent session store
                    let store: SessionStore
                    do {
                        store = try SessionStore(sessionID: sessionID, name: agentName)
                    } catch {
                        logger.error("Failed to create session store: \(error)")
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sessionID
                        out.text = "System Error: Failed to create session store. (\(error.localizedDescription))"
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                        continue
                    }

                    // Fork: copy context and shares from source session
                    var shareMounts: [MountSpec] = []
                    if !startReq.forkSessionID.isEmpty {
                        if let sourceStore = await SessionManager.shared.getStore(sessionID: startReq.forkSessionID) {
                            // Copy context messages
                            if let contextMessages = try? sourceStore.getContextMessages() {
                                for msg in contextMessages {
                                    try? store.addContextMessage(
                                        section: msg.section,
                                        role: msg.role,
                                        content: msg.content,
                                        metadata: msg.metadataJson
                                    )
                                }
                            }
                            // Copy shares
                            if let shares = try? sourceStore.getShares() {
                                for share in shares {
                                    try? store.addShare(hostPath: share.hostPath, guestPath: share.guestPath, mode: share.mode)
                                }
                                shareMounts = shares.map { MountSpec(source: $0.hostPath, destination: $0.guestPath, readOnly: $0.mode == "ro") }
                            }
                            logger.info("Forked session \(startReq.forkSessionID) -> \(sessionID)")
                        } else {
                            logger.warning("Fork source session \(startReq.forkSessionID) not found, starting fresh")
                        }
                    }

                    await SessionManager.shared.setStore(sessionID: sessionID, store: store)
                    await SessionManager.shared.registerUI(sessionID: sessionID, stream: responseStream)

                    // Notify UI that session started
                    var response = Pecan_ServerMessage()
                    var started = Pecan_SessionStarted()
                    started.sessionID = sessionID
                    started.agentName = agentName
                    response.sessionStarted = started
                    try await responseStream.send(response)

                    // Spawn the agent using the Pluggable VM architecture
                    do {
                        if shareMounts.isEmpty {
                            try await SpawnerFactory.shared.spawn(
                                sessionID: sessionID,
                                agentName: agentName,
                                workspacePath: store.workspacePath.path
                            )
                        } else {
                            try await SpawnerFactory.shared.spawn(
                                sessionID: sessionID,
                                agentName: agentName,
                                workspacePath: store.workspacePath.path,
                                shares: shareMounts
                            )
                        }
                    } catch {
                        logger.error("Failed to spawn agent: \(error)")
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sessionID
                        out.text = "System Error: Failed to spawn isolated agent VM. (\(error.localizedDescription))"
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                    }

                case .userInput(let req):
                    let text = req.text.trimmingCharacters(in: .whitespaces)

                    // Intercept /share and /unshare commands
                    if text.hasPrefix("/share ") || text.hasPrefix("/unshare ") {
                        do {
                            try await Self.handleShareCommand(sessionID: req.sessionID, text: text)
                        } catch {
                            logger.error("Share command failed: \(error)")
                            var errorMsg = Pecan_ServerMessage()
                            var out = Pecan_AgentOutput()
                            out.sessionID = req.sessionID
                            out.text = "Error: \(error.localizedDescription)"
                            errorMsg.agentOutput = out
                            try await SessionManager.shared.sendToUI(sessionID: req.sessionID, message: errorMsg)
                        }
                    } else if text.hasPrefix("/task") {
                        do {
                            try await Self.handleTaskUICommand(sessionID: req.sessionID, text: text)
                        } catch {
                            logger.error("Task command failed: \(error)")
                            var errorMsg = Pecan_ServerMessage()
                            var out = Pecan_AgentOutput()
                            out.sessionID = req.sessionID
                            out.text = "Error: \(error.localizedDescription)"
                            errorMsg.agentOutput = out
                            try await SessionManager.shared.sendToUI(sessionID: req.sessionID, message: errorMsg)
                        }
                    } else {
                        logger.debug("Routing user input to agent for session \(req.sessionID)")
                        await SessionManager.shared.setAgentBusy(sessionID: req.sessionID, busy: true)
                        var cmdMsg = Pecan_HostCommand()
                        var processInput = Pecan_ProcessInput()
                        processInput.text = req.text
                        cmdMsg.processInput = processInput
                        try await SessionManager.shared.sendToAgent(sessionID: req.sessionID, command: cmdMsg)
                    }

                case .toolApproval(let req):
                    logger.info("Received tool approval: \(req.approved) for \(req.toolCallID)")
                    await Self.handleToolApproval(req)
                case nil:
                    break
                }
            }
        } catch {
            logger.error("UI Stream error or disconnected: \(error)")
        }
        
        for sid in activeSessions {
            await SessionManager.shared.removeSession(sessionID: sid)
        }
        logger.info("UI Client disconnected.")
    }
}

extension ClientServiceProvider {
    /// Parse and execute /share or /unshare commands.
    static func handleShareCommand(sessionID: String, text: String) async throws {
        guard let store = await SessionManager.shared.getStore(sessionID: sessionID) else {
            throw NSError(domain: "ShareCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session"])
        }

        if text.hasPrefix("/unshare ") {
            let hostPath = String(text.dropFirst("/unshare ".count)).trimmingCharacters(in: .whitespaces)
            guard !hostPath.isEmpty else {
                throw NSError(domain: "ShareCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: /unshare <host_path>"])
            }
            try store.removeShare(hostPath: hostPath)
            logger.info("Removed share \(hostPath) for session \(sessionID)")
        } else {
            // /share [-rw] <host_path>[:<guest_path>]
            var args = String(text.dropFirst("/share ".count)).trimmingCharacters(in: .whitespaces)
            var mode = "ro"
            if args.hasPrefix("-rw ") {
                mode = "rw"
                args = String(args.dropFirst("-rw ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !args.isEmpty else {
                throw NSError(domain: "ShareCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Usage: /share [-rw] <host_path>[:<guest_path>]"])
            }
            let parts = args.split(separator: ":", maxSplits: 1)
            let hostPath = String(parts[0])
            let guestPath = parts.count > 1 ? String(parts[1]) : hostPath
            try store.addShare(hostPath: hostPath, guestPath: guestPath, mode: mode)
            logger.info("Added share \(hostPath) -> \(guestPath) (\(mode)) for session \(sessionID)")
        }

        // Restart container with updated mounts
        try await SessionManager.shared.restartContainer(sessionID: sessionID)
    }
}

extension ClientServiceProvider {
    /// Parse and execute /task and /tasks commands from the UI.
    static func handleTaskUICommand(sessionID: String, text: String) async throws {
        guard let store = await SessionManager.shared.getStore(sessionID: sessionID) else {
            throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session"])
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Helper to send output back to UI
        func sendOutput(_ msg: String) async throws {
            var srvMsg = Pecan_ServerMessage()
            var out = Pecan_AgentOutput()
            out.sessionID = sessionID
            out.text = msg
            srvMsg.agentOutput = out
            try await SessionManager.shared.sendToUI(sessionID: sessionID, message: srvMsg)
        }

        // /tasks or /tasks <status>
        if trimmed == "/tasks" || trimmed.hasPrefix("/tasks ") {
            let statusFilter = trimmed == "/tasks" ? nil : String(trimmed.dropFirst("/tasks ".count)).trimmingCharacters(in: .whitespaces)
            let tasks = try store.listTasks(status: statusFilter?.isEmpty == true ? nil : statusFilter)
            if tasks.isEmpty {
                try await sendOutput("No tasks found.")
                return
            }
            var lines = "**Tasks**\n"
            for task in tasks {
                let focusMarker = task.focused == 1 ? " ★" : ""
                let priorityStr = "P\(task.priority)"
                lines += "  #\(task.id ?? 0) [\(task.status)] \(priorityStr) \(task.title)\(focusMarker)\n"
            }
            try await sendOutput(lines)
            return
        }

        // /task #<id> ... or /task <text>
        if trimmed == "/task" {
            try await sendOutput("Usage: /task <instruction> or /task #<id> [field value]")
            return
        }

        let rest = String(trimmed.dropFirst("/task ".count)).trimmingCharacters(in: .whitespaces)

        // /task #<id> ...
        if rest.hasPrefix("#") {
            let parts = rest.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            guard let idStr = parts.first, let taskID = Int64(idStr) else {
                try await sendOutput("Invalid task ID.")
                return
            }

            if parts.count == 1 {
                // /task #<id> — show detail
                guard let task = try store.getTask(id: taskID) else {
                    try await sendOutput("Task #\(taskID) not found.")
                    return
                }
                let focusStr = task.focused == 1 ? " ★ focused" : ""
                var detail = "**Task #\(task.id ?? 0)**: \(task.title)\(focusStr)\n"
                detail += "  Status: \(task.status)  Priority: \(task.priority)  Severity: \(task.severity)\n"
                if !task.labels.isEmpty { detail += "  Labels: \(task.labels)\n" }
                if !task.dueDate.isEmpty { detail += "  Due: \(task.dueDate)\n" }
                if !task.dependsOn.isEmpty { detail += "  Depends: \(task.dependsOn)\n" }
                if !task.description.isEmpty { detail += "  Description: \(task.description)\n" }
                detail += "  Created: \(task.createdAt)  Updated: \(task.updatedAt)"
                try await sendOutput(detail)
                return
            }

            // /task #<id> <field> <value>
            let fieldAndValue = parts[1]
            let fieldParts = fieldAndValue.split(separator: " ", maxSplits: 1).map(String.init)
            let field = fieldParts[0].lowercased()

            if field == "focus" {
                try store.setFocused(taskID: taskID)
                let focused = try store.getFocusedTask()
                try await SessionManager.shared.sendTaskUpdateToUI(sessionID: sessionID, focusedTitle: focused?.title ?? "")
                try await sendOutput("Task #\(taskID) is now focused.")
                return
            }

            guard fieldParts.count > 1 else {
                try await sendOutput("Missing value for field '\(field)'.")
                return
            }

            let value = fieldParts[1]
            var fields: [String: Any] = [:]
            switch field {
            case "priority":
                guard let p = Int(value), (1...5).contains(p) else {
                    try await sendOutput("Priority must be 1-5.")
                    return
                }
                fields["priority"] = p
            case "severity":
                let valid = ["low", "normal", "high", "critical"]
                guard valid.contains(value.lowercased()) else {
                    try await sendOutput("Severity must be: \(valid.joined(separator: ", "))")
                    return
                }
                fields["severity"] = value.lowercased()
            case "status":
                let valid = ["todo", "implementing", "testing", "preparing", "done", "blocked"]
                guard valid.contains(value.lowercased()) else {
                    try await sendOutput("Status must be: \(valid.joined(separator: ", "))")
                    return
                }
                fields["status"] = value.lowercased()
            case "label", "labels":
                fields["labels"] = value
            case "due":
                fields["due_date"] = value
            case "depends":
                fields["depends_on"] = value
            case "description":
                fields["description"] = value
            default:
                try await sendOutput("Unknown field '\(field)'. Use: priority, severity, status, label, due, depends, description, focus")
                return
            }

            let updated = try store.updateTask(id: taskID, fields: fields)
            try await sendOutput("Updated task #\(updated.id ?? 0): \(field) → \(value)")
            return
        }

        // /task <text> — create task
        let task = try store.createTask(title: rest)
        try await sendOutput("Created task #\(task.id ?? 0): \(task.title)")
    }
}

// MARK: - HTTP Proxy Manager

actor HttpProxyManager {
    static let shared = HttpProxyManager()

    struct PendingRequest {
        let sessionID: String
        let request: Pecan_HttpProxyRequest
        let responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>
    }

    private var pending: [String: PendingRequest] = [:]

    func storePending(
        requestID: String,
        sessionID: String,
        request: Pecan_HttpProxyRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>
    ) {
        pending[requestID] = PendingRequest(sessionID: sessionID, request: request, responseStream: responseStream)
    }

    func removePending(requestID: String) -> PendingRequest? {
        pending.removeValue(forKey: requestID)
    }
}

final class AgentServiceProvider: Pecan_AgentServiceAsyncProvider {
    let config: Config
    
    init(config: Config) {
        self.config = config
    }
    
    func connect(
        requestStream: GRPCAsyncRequestStream<Pecan_AgentEvent>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        logger.info("Agent Client connected.")
        var activeSessionID: String? = nil
        
        do {
            for try await event in requestStream {
                switch event.payload {
                case .register(let reg):
                    logger.info("Agent \(reg.agentID) registered for session \(reg.sessionID)")
                    activeSessionID = reg.sessionID
                    
                    await SessionManager.shared.registerAgent(sessionID: reg.sessionID, stream: responseStream)
                    
                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_RegistrationResponse()
                    resp.success = true
                    cmdMsg.registrationResponse = resp
                    try await responseStream.send(cmdMsg)
                    
                case .progress(let prog):
                    guard let sid = activeSessionID else { continue }
                    logger.debug("Progress from agent: \(prog.statusMessage)")
                    // Route to UI
                    var srvMsg = Pecan_ServerMessage()
                    var out = Pecan_AgentOutput()
                    out.sessionID = sid
                    out.text = prog.statusMessage
                    srvMsg.agentOutput = out
                    try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)

                    // Detect idle transition: agent sent a "response" type progress
                    if let data = prog.statusMessage.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String, type == "response" {
                        await SessionManager.shared.setAgentBusy(sessionID: sid, busy: false)
                        await SessionManager.shared.checkAndDeliverTriggers(sessionID: sid)
                    }
                    
                case .getModels(let req):
                    logger.debug("Agent requested models list.")
                    var cmdMsg = Pecan_HostCommand()
                    var resp = Pecan_GetModelsResponse()
                    resp.requestID = req.requestID
                    for (key, modelConfig) in config.models {
                        var info = Pecan_GetModelsResponse.ModelInfo()
                        info.key = key
                        info.name = modelConfig.name ?? key
                        info.description_p = modelConfig.description ?? "No description"
                        resp.models.append(info)
                    }
                    cmdMsg.modelsResponse = resp
                    try await responseStream.send(cmdMsg)
                    
                case .contextCommand(let cmd):
                    guard let sid = activeSessionID else { continue }
                    switch cmd.action {
                    case .addMessage(let addMsg):
                        await SessionManager.shared.addContextMessage(sessionID: sid, section: addMsg.section, role: addMsg.role, content: addMsg.content, metadata: addMsg.metadataJson)
                    case .compact(let compact):
                        await SessionManager.shared.compactContext(sessionID: sid, section: compact.section, keepRecent: Int(compact.keepRecentMessages))
                    case .getInfo(_):
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_ContextResponse()
                        resp.requestID = cmd.requestID
                        resp.infoJson = "{\"status\": \"info not fully implemented\"}"
                        cmdMsg.contextResponse = resp
                        try await responseStream.send(cmdMsg)
                    case nil: break
                    }

                case .completionRequest(let req):
                    guard let sid = activeSessionID else { continue }
                    let modelKey = req.modelKey.isEmpty ? (config.defaultModel ?? config.models.keys.first ?? "") : req.modelKey
                    logger.info("LLM Request from agent: \(req.requestID) using model: \(modelKey)")
                    
                    if let modelConfig = config.models[modelKey] {
                        let provider = ProviderFactory.create(config: modelConfig)
                        do {
                            let contextData = try await SessionManager.shared.getContext(sessionID: sid)
                            var contextMessages: [[String: Any]] = []
                            if let decoded = try JSONSerialization.jsonObject(with: contextData) as? [[String: Any]] {
                                contextMessages = decoded
                            }
                            
                            var payload: [String: Any] = ["messages": contextMessages]
                            
                            // Tools are now injected by the agent directly via paramsJson
                            if !req.paramsJson.isEmpty {
                                if let data = req.paramsJson.data(using: .utf8),
                                   let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    for (k, v) in params {
                                        payload[k] = v
                                    }
                                }
                            }
                            let payloadData = try JSONSerialization.data(withJSONObject: payload)
                            let payloadString = String(data: payloadData, encoding: .utf8)!
                            
                            let responseString = try await provider.complete(payloadJSON: payloadString)
                            var cmdMsg = Pecan_HostCommand()
                            var compResp = Pecan_LLMCompletionResponse()
                            compResp.requestID = req.requestID
                            compResp.responseJson = responseString
                            cmdMsg.completionResponse = compResp
                            try await responseStream.send(cmdMsg)
                        } catch {
                            logger.error("Provider error: \(error)")
                            var cmdMsg = Pecan_HostCommand()
                            var compResp = Pecan_LLMCompletionResponse()
                            compResp.requestID = req.requestID
                            compResp.errorMessage = error.localizedDescription
                            cmdMsg.completionResponse = compResp
                            try await responseStream.send(cmdMsg)
                        }
                    } else {
                        logger.error("Error: No valid model configuration found for key \(modelKey).")
                        var cmdMsg = Pecan_HostCommand()
                        var compResp = Pecan_LLMCompletionResponse()
                        compResp.requestID = req.requestID
                        compResp.errorMessage = "No valid model configuration found for key \(modelKey)."
                        cmdMsg.completionResponse = compResp
                        try await responseStream.send(cmdMsg)
                    }
                    
                case .taskCommand(let cmd):
                    guard let sid = activeSessionID else { continue }
                    do {
                        let result = try await SessionManager.shared.handleTaskCommand(sessionID: sid, action: cmd.action, payloadJSON: cmd.payloadJson)
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_TaskResponse()
                        resp.requestID = cmd.requestID
                        resp.resultJson = result
                        cmdMsg.taskResponse = resp
                        try await responseStream.send(cmdMsg)
                    } catch {
                        var cmdMsg = Pecan_HostCommand()
                        var resp = Pecan_TaskResponse()
                        resp.requestID = cmd.requestID
                        resp.errorMessage = error.localizedDescription
                        cmdMsg.taskResponse = resp
                        try await responseStream.send(cmdMsg)
                    }

                case .httpRequest(let req):
                    guard let sid = activeSessionID else { continue }
                    logger.info("HTTP proxy request from agent: \(req.method) \(req.url) (approval: \(req.requiresApproval))")

                    if req.requiresApproval {
                        // Send approval request to UI, store pending continuation
                        await HttpProxyManager.shared.storePending(
                            requestID: req.requestID,
                            sessionID: sid,
                            request: req,
                            responseStream: responseStream
                        )

                        // Send approval request to UI
                        var srvMsg = Pecan_ServerMessage()
                        var approval = Pecan_ToolApprovalRequest()
                        approval.sessionID = sid
                        approval.toolCallID = req.requestID
                        approval.toolName = "http_request"
                        let details: [String: Any] = [
                            "method": req.method,
                            "url": req.url,
                            "body": req.body
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: details),
                           let str = String(data: data, encoding: .utf8) {
                            approval.argumentsJson = str
                        }
                        srvMsg.approvalRequest = approval
                        try await SessionManager.shared.sendToUI(sessionID: sid, message: srvMsg)
                    } else {
                        // Execute immediately
                        let httpResp = await Self.executeHttpRequest(req)
                        var cmdMsg = Pecan_HostCommand()
                        cmdMsg.httpResponse = httpResp
                        try await responseStream.send(cmdMsg)
                    }

                case .toolRequest(let req):
                    logger.info("Tool Request from agent: \(req.toolName)")
                    // Server-side tools to be implemented later if needed.
                    var cmdMsg = Pecan_HostCommand()
                    var toolResp = Pecan_ToolExecutionResponse()
                    toolResp.requestID = req.requestID
                    toolResp.errorMessage = "Server-side tools are not currently implemented. Agent should execute tools locally."
                    cmdMsg.toolResponse = toolResp
                    try await responseStream.send(cmdMsg)

                case nil:
                    break
                }
            }
        } catch {
            logger.error("Agent Stream error or disconnected: \(error)")
        }
        
        logger.info("Agent Client disconnected.")
    }
}

extension AgentServiceProvider {
    /// Execute an HTTP request on behalf of the agent.
    static func executeHttpRequest(_ req: Pecan_HttpProxyRequest) async -> Pecan_HttpProxyResponse {
        var resp = Pecan_HttpProxyResponse()
        resp.requestID = req.requestID

        // Build URL with query params
        guard var components = URLComponents(string: req.url) else {
            resp.errorMessage = "Invalid URL: \(req.url)"
            return resp
        }

        if !req.queryParams.isEmpty {
            var items = components.queryItems ?? []
            for qp in req.queryParams {
                items.append(URLQueryItem(name: qp.name, value: qp.value))
            }
            components.queryItems = items
        }

        guard let url = components.url else {
            resp.errorMessage = "Could not construct URL from components"
            return resp
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method
        urlRequest.timeoutInterval = 30

        for h in req.headers {
            urlRequest.setValue(h.value, forHTTPHeaderField: h.name)
        }

        if !req.body.isEmpty {
            urlRequest.httpBody = req.body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse {
                resp.statusCode = Int32(httpResponse.statusCode)
                for (key, value) in httpResponse.allHeaderFields {
                    var header = Pecan_HttpHeader()
                    header.name = "\(key)"
                    header.value = "\(value)"
                    resp.responseHeaders.append(header)
                }
            }
            resp.body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? "(binary data, \(data.count) bytes)"
        } catch {
            resp.errorMessage = error.localizedDescription
        }

        return resp
    }
}

extension ClientServiceProvider {
    /// Handle tool approval responses from the UI for HTTP proxy requests.
    static func handleToolApproval(_ approval: Pecan_ToolApproval) async {
        guard let pending = await HttpProxyManager.shared.removePending(requestID: approval.toolCallID) else {
            logger.warning("No pending HTTP request for approval ID \(approval.toolCallID)")
            return
        }

        var resp: Pecan_HttpProxyResponse
        if approval.approved {
            resp = await AgentServiceProvider.executeHttpRequest(pending.request)
        } else {
            resp = Pecan_HttpProxyResponse()
            resp.requestID = pending.request.requestID
            let reason = approval.rejectReason.isEmpty ? "User rejected the request" : "Request rejected by user: \(approval.rejectReason)"
            resp.errorMessage = reason
        }

        var cmdMsg = Pecan_HostCommand()
        cmdMsg.httpResponse = resp
        do {
            try await pending.responseStream.send(cmdMsg)
        } catch {
            logger.error("Failed to send HTTP proxy response: \(error)")
        }
    }
}

func main() async throws {

    let config = try Config.load()

    // Launch the vm-launcher subprocess and wait for it to be ready
    let launcher = try LauncherProcessManager()
    try launcher.waitForSocket()

    // Switch to container-based execution
    await SpawnerFactory.shared.useVirtualizationFramework(launcher: launcher)

    // Ensure launcher is terminated on exit
    defer {
        Task { await SpawnerFactory.shared.shutdownLauncher() }
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let providers = [ClientServiceProvider(), AgentServiceProvider(config: config)] as [CallHandlerProvider]

    // TCP server for UI clients
    let tcpServer = try await Server.insecure(group: group)
        .withServiceProviders(providers)
        .bind(host: "0.0.0.0", port: 3000)
        .get()

    // Unix socket server for containerized agents (relayed via vsock)
    let runDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".run")
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let socketPath = runDir.appendingPathComponent("grpc.sock").path
    // Remove stale socket file if it exists
    try? FileManager.default.removeItem(atPath: socketPath)

    let udsServer = try await Server.insecure(group: group)
        .withServiceProviders(providers)
        .bind(unixDomainSocketPath: socketPath)
        .get()

    logger.info("Pecan Server started on port \(tcpServer.channel.localAddress?.port ?? 3000) and Unix socket \(socketPath) with default model: \(config.defaultModel ?? "unknown")")

    // Background trigger timer: check for due triggers every 10 seconds
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            let sessionIDs = await SessionManager.shared.activeSessionIDs()
            for sid in sessionIDs {
                await SessionManager.shared.checkAndDeliverTriggers(sessionID: sid)
            }
        }
    }

    // Handle SIGINT/SIGTERM for clean shutdown
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            Task {
                await SpawnerFactory.shared.shutdownLauncher()
            }
            exit(0)
        }
    }

    // Wait for either server to close
    try await tcpServer.onClose.get()
    try await udsServer.onClose.get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        logger.critical("Server error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
