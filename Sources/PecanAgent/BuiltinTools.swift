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

// MARK: - CreateLuaToolTool

public struct CreateLuaToolTool: PecanTool, Sendable {
    public let name = "create_lua_tool"
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
