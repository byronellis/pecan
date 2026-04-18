import Foundation

// MARK: - TaskCreateTool

public struct TaskCreateTool: PecanTool, Sendable {
    public let name = "task_create"
    public let description = "Create a new task to track work. Returns the created task as JSON."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "title": { "type": "string", "description": "Short task title/instruction." },
            "description": { "type": "string", "description": "Optional longer description." },
            "priority": { "type": "integer", "description": "1 (critical) to 5 (low). Default 3." },
            "severity": { "type": "string", "description": "low, normal, high, or critical. Default normal." },
            "labels": { "type": "string", "description": "Comma-separated labels." },
            "due_date": { "type": "string", "description": "ISO 8601 due date or empty." },
            "scope": { "type": "string", "description": "Where to create: 'agent' (default), 'team', or 'project'." }
        },
        "required": ["title"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        var payload: [String: Any] = ["title": args["title"] as? String ?? ""]
        if let v = args["description"] as? String { payload["description"] = v }
        if let v = args["priority"] as? Int { payload["priority"] = v }
        if let v = args["severity"] as? String { payload["severity"] = v }
        if let v = args["labels"] as? String { payload["labels"] = v }
        if let v = args["due_date"] as? String { payload["due_date"] = v }
        let scope = args["scope"] as? String ?? ""
        let result = try await TaskClient.shared.sendCommand(action: "create", payload: payload, scope: scope)
        if let data = result.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            await HookManager.shared.fire(event: "task.created", data: obj)
        }
        return result
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = obj["id"] ?? "?"
        let title = obj["title"] as? String ?? ""
        return "Created task #\(id): \(title)"
    }
}

// MARK: - TaskListTool

public struct TaskListTool: PecanTool, Sendable {
    public let name = "task_list"
    public let description = "List tasks. By default merges agent, team, and project tasks. Use scope to filter to a single level."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "status": { "type": "string", "description": "Filter by status (todo, implementing, testing, preparing, done, blocked)." },
            "label": { "type": "string", "description": "Filter by label." },
            "search": { "type": "string", "description": "Search in title and description." },
            "scope": { "type": "string", "description": "Filter to scope: 'agent', 'team', 'project', or empty for all (default)." }
        }
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = (try? parseArguments(argumentsJSON)) ?? [:]
        var payload: [String: Any] = [:]
        if let v = args["status"] as? String { payload["status"] = v }
        if let v = args["label"] as? String { payload["label"] = v }
        if let v = args["search"] as? String { payload["search"] = v }
        let scope = args["scope"] as? String ?? ""
        return try await TaskClient.shared.sendCommand(action: "list", payload: payload, scope: scope)
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        if arr.isEmpty { return "(no tasks)" }

        // Build table rows
        var rows: [(id: String, scope: String, status: String, priority: String, title: String, labels: String)] = []
        for task in arr {
            let id = "#\(task["id"] ?? "?")"
            let scope = task["scope"] as? String ?? "agent"
            let status = task["status"] as? String ?? ""
            let priority = "P\(task["priority"] ?? 3)"
            let title = task["title"] as? String ?? ""
            let labels = task["labels"] as? String ?? ""
            rows.append((id: id, scope: scope, status: status, priority: priority, title: title, labels: labels))
        }

        // Check if we have mixed scopes
        let scopes = Set(rows.map(\.scope))
        let showScope = scopes.count > 1

        // Calculate column widths
        let idW = max(2, rows.map(\.id.count).max() ?? 2)
        let scopeW = showScope ? max(5, rows.map(\.scope.count).max() ?? 5) : 0
        let statusW = max(6, rows.map(\.status.count).max() ?? 6)
        let prioW = max(4, rows.map(\.priority.count).max() ?? 4)
        let titleW = max(5, rows.map(\.title.count).max() ?? 5)

        func pad(_ s: String, _ w: Int) -> String {
            s.padding(toLength: w, withPad: " ", startingAt: 0)
        }

        var lines: [String] = []
        if showScope {
            lines.append("\(pad("ID", idW)) | \(pad("Scope", scopeW)) | \(pad("Status", statusW)) | \(pad("Pri", prioW)) | \(pad("Title", titleW)) | Labels")
            lines.append(String(repeating: "-", count: idW) + "-+-" + String(repeating: "-", count: scopeW) + "-+-" + String(repeating: "-", count: statusW) + "-+-" + String(repeating: "-", count: prioW) + "-+-" + String(repeating: "-", count: titleW) + "-+-------")
            for r in rows {
                lines.append("\(pad(r.id, idW)) | \(pad(r.scope, scopeW)) | \(pad(r.status, statusW)) | \(pad(r.priority, prioW)) | \(pad(r.title, titleW)) | \(r.labels)")
            }
        } else {
            lines.append("\(pad("ID", idW)) | \(pad("Status", statusW)) | \(pad("Pri", prioW)) | \(pad("Title", titleW)) | Labels")
            lines.append(String(repeating: "-", count: idW) + "-+-" + String(repeating: "-", count: statusW) + "-+-" + String(repeating: "-", count: prioW) + "-+-" + String(repeating: "-", count: titleW) + "-+-------")
            for r in rows {
                lines.append("\(pad(r.id, idW)) | \(pad(r.status, statusW)) | \(pad(r.priority, prioW)) | \(pad(r.title, titleW)) | \(r.labels)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - TaskGetTool

public struct TaskGetTool: PecanTool, Sendable {
    public let name = "task_get"
    public let description = "Get details of a specific task by ID."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "task_id": { "type": "integer", "description": "The task ID." }
        },
        "required": ["task_id"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        let taskID = args["task_id"] as? Int ?? 0
        return try await TaskClient.shared.sendCommand(action: "get", payload: ["task_id": taskID])
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var lines: [String] = []
        let id = obj["id"] ?? "?"
        let title = obj["title"] as? String ?? ""
        lines.append("Task #\(id): \(title)")
        if let status = obj["status"] as? String { lines.append("  Status:   \(status)") }
        if let priority = obj["priority"] { lines.append("  Priority: P\(priority)") }
        if let severity = obj["severity"] as? String, !severity.isEmpty { lines.append("  Severity: \(severity)") }
        if let labels = obj["labels"] as? String, !labels.isEmpty { lines.append("  Labels:   \(labels)") }
        if let dueDate = obj["due_date"] as? String, !dueDate.isEmpty { lines.append("  Due:      \(dueDate)") }
        if let desc = obj["description"] as? String, !desc.isEmpty { lines.append("  ---\n  \(desc)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - TaskUpdateTool

public struct TaskUpdateTool: PecanTool, Sendable {
    public let name = "task_update"
    public let description = "Update fields on an existing task. Only provided fields are changed."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "task_id": { "type": "integer", "description": "The task ID to update." },
            "title": { "type": "string", "description": "New title." },
            "description": { "type": "string", "description": "New description." },
            "status": { "type": "string", "description": "New status: todo, implementing, testing, preparing, done, blocked." },
            "priority": { "type": "integer", "description": "New priority 1-5." },
            "severity": { "type": "string", "description": "New severity: low, normal, high, critical." },
            "labels": { "type": "string", "description": "New labels (comma-separated)." },
            "due_date": { "type": "string", "description": "New due date (ISO 8601)." },
            "depends_on": { "type": "string", "description": "Dependencies (comma-separated sessionID:taskID)." }
        },
        "required": ["task_id"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        var payload: [String: Any] = ["task_id": args["task_id"] as? Int ?? 0]
        for key in ["title", "description", "status", "severity", "labels", "due_date", "depends_on"] {
            if let v = args[key] as? String { payload[key] = v }
        }
        if let v = args["priority"] as? Int { payload["priority"] = v }
        let result = try await TaskClient.shared.sendCommand(action: "update", payload: payload)
        if let data = result.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            await HookManager.shared.fire(event: "task.updated", data: obj)
        }
        return result
    }
}

// MARK: - TaskFocusTool

public struct TaskFocusTool: PecanTool, Sendable {
    public let name = "task_focus"
    public let description = "Set a task as the focused task shown in the UI chrome. Pass task_id 0 to unfocus all."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "task_id": { "type": "integer", "description": "The task ID to focus, or 0 to unfocus." }
        },
        "required": ["task_id"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        let taskID = args["task_id"] as? Int ?? 0
        let result = try await TaskClient.shared.sendCommand(action: "focus", payload: ["task_id": taskID])
        await HookManager.shared.fire(event: "task.focused", data: ["task_id": taskID])
        return result
    }
}
