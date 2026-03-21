import Foundation
import Lua

// MARK: - JSON Argument Parsing Helpers

private func parseArguments(_ json: String) throws -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.invalidArguments("Could not parse arguments JSON.")
    }
    return dict
}

private enum ToolError: LocalizedError {
    case invalidArguments(String)
    case fileNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return msg
        case .fileNotFound(let msg): return msg
        case .executionFailed(let msg): return msg
        }
    }
}

// MARK: - ReadFileTool

public struct ReadFileTool: PecanTool, Sendable {
    public let name = "read_file"
    public let description = "Read the contents of a file. Returns file content with line numbers."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "path": { "type": "string", "description": "Absolute or relative path to the file to read." },
            "offset": { "type": "integer", "description": "1-based line number to start reading from." },
            "limit": { "type": "integer", "description": "Maximum number of lines to return." }
        },
        "required": ["path"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let path = args["path"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: path")
        }

        let resolvedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw ToolError.fileNotFound("File not found: \(path)")
        }

        let content: String
        do {
            content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            throw ToolError.executionFailed("Cannot read file: \(error.localizedDescription)")
        }

        var lines = content.components(separatedBy: "\n")

        let offset = (args["offset"] as? Int) ?? 1
        let startIndex = max(0, offset - 1)

        if startIndex > 0 {
            lines = Array(lines.dropFirst(startIndex))
        }

        if let limit = args["limit"] as? Int, limit > 0 {
            lines = Array(lines.prefix(limit))
        }

        var result = ""
        for (i, line) in lines.enumerated() {
            let lineNum = startIndex + i + 1
            result += "\(lineNum)\t\(line)\n"
        }

        return result.isEmpty ? "(empty file)" : result
    }
}

// MARK: - WriteFileTool

public struct WriteFileTool: PecanTool, Sendable {
    public let name = "write_file"
    public let description = "Write content to a file. Creates intermediate directories if needed. Overwrites existing content."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "path": { "type": "string", "description": "Absolute or relative path to the file to write." },
            "content": { "type": "string", "description": "The content to write to the file." }
        },
        "required": ["path", "content"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let path = args["path"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: path")
        }
        guard let content = args["content"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: content")
        }

        let resolvedPath = (path as NSString).expandingTildeInPath
        let dir = (resolvedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

        let byteCount = content.utf8.count
        return "Successfully wrote \(byteCount) bytes to \(path)"
    }
}

// MARK: - EditFileTool

public struct EditFileTool: PecanTool, Sendable {
    public let name = "edit_file"
    public let description = "Edit a file by replacing an exact string match. The old_string must appear exactly once in the file."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "path": { "type": "string", "description": "Path to the file to edit." },
            "old_string": { "type": "string", "description": "The exact string to find and replace. Must appear exactly once." },
            "new_string": { "type": "string", "description": "The replacement string." }
        },
        "required": ["path", "old_string", "new_string"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let path = args["path"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: path")
        }
        guard let oldString = args["old_string"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: old_string")
        }
        guard let newString = args["new_string"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: new_string")
        }

        let resolvedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw ToolError.fileNotFound("File not found: \(path)")
        }

        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)

        let occurrences = content.components(separatedBy: oldString).count - 1
        if occurrences == 0 {
            throw ToolError.executionFailed("old_string not found in file.")
        }
        if occurrences > 1 {
            throw ToolError.executionFailed("old_string found \(occurrences) times — must appear exactly once. Provide more context to make it unique.")
        }

        let newContent = content.replacingOccurrences(of: oldString, with: newString)
        try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

        return "Successfully edited \(path)"
    }
}

// MARK: - SearchFilesTool

public struct SearchFilesTool: PecanTool, Sendable {
    public let name = "search_files"
    public let description = "Search file contents using grep. Returns matching lines with file paths and line numbers."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "pattern": { "type": "string", "description": "Regex pattern to search for." },
            "path": { "type": "string", "description": "Directory or file to search in. Defaults to current directory." },
            "include": { "type": "string", "description": "Glob pattern to filter files, e.g. '*.swift'." }
        },
        "required": ["pattern"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let pattern = args["pattern"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: pattern")
        }

        let searchPath = (args["path"] as? String) ?? "."

        var grepArgs = ["-rn", pattern]
        if let include = args["include"] as? String {
            grepArgs.insert(contentsOf: ["--include", include], at: 0)
        }
        grepArgs.append(searchPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = grepArgs

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Limit to first 100 lines
        let lines = output.components(separatedBy: "\n")
        let limited = lines.prefix(100)
        let result = limited.joined(separator: "\n")

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches found."
        }

        let suffix = lines.count > 100 ? "\n... (truncated, \(lines.count) total matches)" : ""
        return result + suffix
    }
}

// MARK: - BashTool

public struct BashTool: PecanTool, Sendable {
    public let name = "shell"
    public let description = "Execute a shell command and return its output. Use for running shell commands, build tools, git, etc."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "command": { "type": "string", "description": "The bash command to execute." }
        },
        "required": ["command"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let command = args["command"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 120-second timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 120_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        var result = ""
        if !stdout.isEmpty {
            result += stdout
        }
        if !stderr.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += "STDERR:\n\(stderr)"
        }

        result += "\n(exit code: \(process.terminationStatus))"

        return result
    }
}

// MARK: - Task Tools

public struct TaskCreateTool: PecanTool, Sendable {
    public let name = "task_create"
    public let description = "Create a new task to track work. Returns the created task as JSON."
    public let tags: Set<String> = ["tasks"]
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

public struct TaskListTool: PecanTool, Sendable {
    public let name = "task_list"
    public let description = "List tasks. By default merges agent, team, and project tasks. Use scope to filter to a single level."
    public let tags: Set<String> = ["tasks"]
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

public struct TaskGetTool: PecanTool, Sendable {
    public let name = "task_get"
    public let description = "Get details of a specific task by ID."
    public let tags: Set<String> = ["tasks"]
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

public struct TaskUpdateTool: PecanTool, Sendable {
    public let name = "task_update"
    public let description = "Update fields on an existing task. Only provided fields are changed."
    public let tags: Set<String> = ["tasks"]
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

public struct TaskFocusTool: PecanTool, Sendable {
    public let name = "task_focus"
    public let description = "Set a task as the focused task shown in the UI chrome. Pass task_id 0 to unfocus all."
    public let tags: Set<String> = ["tasks"]
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

// MARK: - WebFetchTool

public struct WebFetchTool: PecanTool, Sendable {
    public let name = "web_fetch"
    public let description = "Fetch a web page via HTTP GET. Returns the status code and response body."
    public let tags: Set<String> = ["web"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "url": { "type": "string", "description": "The URL to fetch." },
            "headers": {
                "type": "array",
                "description": "Optional HTTP headers.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            },
            "query_params": {
                "type": "array",
                "description": "Optional query parameters appended to the URL.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            }
        },
        "required": ["url"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let url = args["url"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: url")
        }

        let headers = parseHeaderArray(args["headers"])
        let queryParams = parseHeaderArray(args["query_params"])

        let resp = try await HttpClient.shared.sendRequest(
            method: "GET",
            url: url,
            headers: headers,
            queryParams: queryParams,
            requiresApproval: false
        )

        var body = resp.body
        // Truncate to 50KB
        if body.utf8.count > 50_000 {
            body = String(body.prefix(50_000)) + "\n... (truncated)"
        }

        return "HTTP \(resp.statusCode)\n\(body)"
    }

    public func formatResult(_ result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 21 { return nil }
        let truncated = lines.prefix(21).joined(separator: "\n")
        return truncated + "\n... (\(lines.count) lines total, truncated)"
    }
}

// MARK: - WebSearchTool

public struct WebSearchTool: PecanTool, Sendable {
    public let name = "web_search"
    public let description = "Search the web using DuckDuckGo. Returns a list of result titles, URLs, and snippets."
    public let tags: Set<String> = ["web"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "query": { "type": "string", "description": "The search query." },
            "num_results": { "type": "integer", "description": "Maximum number of results to return. Default 5." }
        },
        "required": ["query"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let query = args["query"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: query")
        }

        let numResults = args["num_results"] as? Int ?? 5

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ToolError.invalidArguments("Could not encode query.")
        }

        let searchURL = "https://html.duckduckgo.com/html/?q=\(encoded)"

        let resp = try await HttpClient.shared.sendRequest(
            method: "GET",
            url: searchURL,
            requiresApproval: false
        )

        let results = parseSearchResults(html: resp.body, maxResults: numResults)

        let data = try JSONSerialization.data(withJSONObject: results)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return nil }
        if arr.isEmpty { return "(no results)" }
        var lines: [String] = []
        for (i, item) in arr.enumerated() {
            let title = item["title"] ?? ""
            let url = item["url"] ?? ""
            let snippet = item["snippet"] ?? ""
            lines.append("\(i + 1). [\(title)](\(url))\n   \(snippet)")
        }
        return lines.joined(separator: "\n")
    }

    private func parseSearchResults(html: String, maxResults: Int) -> [[String: String]] {
        var results: [[String: String]] = []

        // Parse DuckDuckGo HTML results
        // Results are in <a class="result__a" href="...">title</a>
        // Snippets in <a class="result__snippet" ...>text</a>
        let resultPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#

        guard let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: .dotMatchesLineSeparators),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .dotMatchesLineSeparators) else {
            return results
        }

        let range = NSRange(html.startIndex..., in: html)
        let resultMatches = resultRegex.matches(in: html, range: range)
        let snippetMatches = snippetRegex.matches(in: html, range: range)

        for (i, match) in resultMatches.prefix(maxResults).enumerated() {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var url = String(html[urlRange])
            let title = stripHTML(String(html[titleRange]))

            // DuckDuckGo wraps URLs in a redirect; extract the actual URL
            if url.contains("uddg="), let extracted = extractDDGURL(url) {
                url = extracted
            }

            var snippet = ""
            if i < snippetMatches.count {
                let sm = snippetMatches[i]
                if let snippetRange = Range(sm.range(at: 1), in: html) {
                    snippet = stripHTML(String(html[snippetRange]))
                }
            }

            results.append(["title": title, "url": url, "snippet": snippet])
        }

        return results
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractDDGURL(_ redirect: String) -> String? {
        guard let components = URLComponents(string: redirect),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return nil
        }
        return uddg.removingPercentEncoding ?? uddg
    }
}

// MARK: - HttpRequestTool

public struct HttpRequestTool: PecanTool, Sendable {
    public let name = "http_request"
    public let description = "Make an HTTP request (POST, PUT, PATCH, DELETE). Requires user approval before execution."
    public let tags: Set<String> = ["web"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "method": { "type": "string", "description": "HTTP method: POST, PUT, PATCH, or DELETE." },
            "url": { "type": "string", "description": "The URL to send the request to." },
            "headers": {
                "type": "array",
                "description": "Optional HTTP headers.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            },
            "query_params": {
                "type": "array",
                "description": "Optional query parameters.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            },
            "body": { "type": "string", "description": "Request body content." }
        },
        "required": ["method", "url"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let method = args["method"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: method")
        }
        guard let url = args["url"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: url")
        }

        let allowed = ["POST", "PUT", "PATCH", "DELETE"]
        let upperMethod = method.uppercased()
        guard allowed.contains(upperMethod) else {
            throw ToolError.invalidArguments("Method must be one of: \(allowed.joined(separator: ", ")). Use web_fetch for GET requests.")
        }

        let headers = parseHeaderArray(args["headers"])
        let queryParams = parseHeaderArray(args["query_params"])
        let body = args["body"] as? String ?? ""

        let resp = try await HttpClient.shared.sendRequest(
            method: upperMethod,
            url: url,
            headers: headers,
            queryParams: queryParams,
            body: body,
            requiresApproval: true
        )

        var responseHeaders = ""
        for h in resp.responseHeaders {
            responseHeaders += "\(h.name): \(h.value)\n"
        }

        var respBody = resp.body
        if respBody.utf8.count > 50_000 {
            respBody = String(respBody.prefix(50_000)) + "\n... (truncated)"
        }

        return "HTTP \(resp.statusCode)\n\(responseHeaders)\n\(respBody)"
    }

    public func formatResult(_ result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        let bodyLength = result.utf8.count
        return "\(firstLine) — \(bodyLength) bytes"
    }
}

// MARK: - Trigger Tools

public struct TriggerCreateTool: PecanTool, Sendable {
    public let name = "trigger_create"
    public let description = "Schedule a future instruction to yourself. One-shot by default; set interval_seconds for repeating."
    public let tags: Set<String> = ["triggers"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "instruction": { "type": "string", "description": "The instruction to deliver when the trigger fires." },
            "fire_at": { "type": "string", "description": "ISO 8601 datetime for when to fire the trigger." },
            "interval_seconds": { "type": "integer", "description": "If set, trigger repeats at this interval after firing. 0 means one-shot." }
        },
        "required": ["instruction", "fire_at"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        var payload: [String: Any] = [
            "instruction": args["instruction"] as? String ?? "",
            "fire_at": args["fire_at"] as? String ?? ""
        ]
        if let interval = args["interval_seconds"] as? Int { payload["interval_seconds"] = interval }
        return try await TaskClient.shared.sendCommand(action: "trigger_create", payload: payload)
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = obj["id"] ?? "?"
        let fireAt = obj["fire_at"] as? String ?? ""
        let interval = obj["interval_seconds"] as? Int ?? 0
        let repeatStr = interval > 0 ? " (repeats every \(interval)s)" : " (one-shot)"
        return "Trigger #\(id) scheduled for \(fireAt)\(repeatStr)"
    }
}

public struct TriggerListTool: PecanTool, Sendable {
    public let name = "trigger_list"
    public let description = "List scheduled triggers. Defaults to active triggers."
    public let tags: Set<String> = ["triggers"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "status": { "type": "string", "description": "Filter by status: active, fired, cancelled. Default: active." }
        }
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = (try? parseArguments(argumentsJSON)) ?? [:]
        var payload: [String: Any] = [:]
        if let status = args["status"] as? String { payload["status"] = status }
        else { payload["status"] = "active" }
        return try await TaskClient.shared.sendCommand(action: "trigger_list", payload: payload)
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        if arr.isEmpty { return "(no triggers)" }
        var lines: [String] = []
        for t in arr {
            let id = t["id"] ?? "?"
            let instruction = t["instruction"] as? String ?? ""
            let fireAt = t["fire_at"] as? String ?? ""
            let interval = t["interval_seconds"] as? Int ?? 0
            let preview = instruction.count > 60 ? String(instruction.prefix(60)) + "..." : instruction
            let repeatStr = interval > 0 ? " (every \(interval)s)" : ""
            lines.append("#\(id) \(fireAt)\(repeatStr): \(preview)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct TriggerCancelTool: PecanTool, Sendable {
    public let name = "trigger_cancel"
    public let description = "Cancel an active trigger."
    public let tags: Set<String> = ["triggers"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "trigger_id": { "type": "integer", "description": "The trigger ID to cancel." }
        },
        "required": ["trigger_id"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        let triggerID = args["trigger_id"] as? Int ?? 0
        return try await TaskClient.shared.sendCommand(action: "trigger_cancel", payload: ["trigger_id": triggerID])
    }

    public func formatResult(_ result: String) -> String? { "Trigger cancelled." }
}

// MARK: - HTTP Tool Helpers

private func parseHeaderArray(_ value: Any?) -> [(name: String, value: String)] {
    guard let arr = value as? [[String: Any]] else { return [] }
    return arr.compactMap { dict in
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String else { return nil }
        return (name: name, value: value)
    }
}

// MARK: - ActivateSkillTool

public struct ActivateSkillTool: PecanTool, Sendable {
    public let name = "activate_skill"
    public let tags: Set<String> = ["skills"]
    public let description = "Load a skill's full instructions into context. Use when a task matches a skill's description from the catalog."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "name": { "type": "string", "description": "The name of the skill to activate, as shown in the skill catalog." }
        },
        "required": ["name"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let skillName = args["name"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: name")
        }

        guard let result = await SkillManager.shared.activate(name: skillName) else {
            throw ToolError.invalidArguments("Skill '\(skillName)' not found. Use the skill catalog to see available skills.")
        }

        return result
    }

    public func formatResult(_ result: String) -> String? {
        // Extract skill name from the XML tag
        if let range = result.range(of: "name=\""),
           let endRange = result[range.upperBound...].range(of: "\"") {
            let name = result[range.upperBound..<endRange.lowerBound]
            return "Activated skill: \(name)"
        }
        return "Skill activated"
    }
}

// MARK: - CreateLuaToolTool

public struct CreateLuaToolTool: PecanTool, Sendable {
    public let name = "create_lua_tool"
    public let tags: Set<String> = ["meta"]
    public let description = """
        Dynamically create and register a new tool by providing a Lua script and JSON schema. \
        The new tool becomes available immediately for subsequent tool calls. \
        Lua scripts receive arguments as a table and must return a string result. \
        Optionally persist the tool to ~/.pecan/tools/ so it survives across sessions.
        """
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "tool_name": { "type": "string", "description": "Name for the new tool (alphanumeric and underscores only)." },
            "tool_description": { "type": "string", "description": "Description of what the tool does." },
            "parameters_schema": { "type": "string", "description": "JSON schema string describing the tool's parameters." },
            "lua_script": { "type": "string", "description": "Lua script that implements the tool. Receives args as a table parameter, must return a string." },
        },
        "required": ["tool_name", "tool_description", "parameters_schema", "lua_script"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let toolName = args["tool_name"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: tool_name")
        }
        guard let toolDescription = args["tool_description"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: tool_description")
        }
        guard let parametersSchema = args["parameters_schema"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: parameters_schema")
        }
        guard let luaScript = args["lua_script"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: lua_script")
        }

        // Validate tool name
        let nameRegex = try NSRegularExpression(pattern: "^[a-zA-Z_][a-zA-Z0-9_]*$")
        let nameRange = NSRange(toolName.startIndex..., in: toolName)
        guard nameRegex.firstMatch(in: toolName, range: nameRange) != nil else {
            throw ToolError.invalidArguments("tool_name must contain only alphanumeric characters and underscores, and start with a letter or underscore.")
        }

        // Validate the Lua script compiles
        let validationHandle = Task.detached {
            let L = LuaState(libraries: .all)
            defer { L.close() }
            try L.load(string: luaScript, name: toolName)
            return true
        }
        do {
            _ = try await validationHandle.value
        } catch {
            throw ToolError.executionFailed("Lua script failed to compile: \(error.localizedDescription)")
        }

        // Validate JSON schema parses
        guard let schemaData = parametersSchema.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: schemaData)) != nil else {
            throw ToolError.invalidArguments("parameters_schema is not valid JSON.")
        }

        // Create and register the tool
        let tool = LuaTool(
            name: toolName,
            description: toolDescription,
            parametersJSONSchema: parametersSchema,
            script: luaScript
        )
        await ToolManager.shared.register(tool: tool)

        return "Tool '\(toolName)' created and registered. It is available for use immediately in this session."
    }
}
