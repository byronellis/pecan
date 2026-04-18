import Foundation

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

// MARK: - AppendFileTool

public struct AppendFileTool: PecanTool, Sendable {
    public let name = "append_file"
    public let description = "Append content to a file. For /memory/TAG.md files this creates a new memory entry. The file is created if it does not exist."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "path": { "type": "string", "description": "Absolute path to the file." },
            "content": { "type": "string", "description": "Content to append." }
        },
        "required": ["path", "content"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let path = args["path"] as? String else { throw ToolError.invalidArguments("Missing path") }
        guard let content = args["content"] as? String else { throw ToolError.invalidArguments("Missing content") }

        let resolved = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: resolved) {
            let dir = (resolved as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: resolved, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: resolved) else {
            throw ToolError.executionFailed("Cannot open \(path) for writing")
        }
        defer { fh.closeFile() }
        fh.seekToEndOfFile()
        guard let data = content.data(using: .utf8) else {
            throw ToolError.executionFailed("Cannot encode content as UTF-8")
        }
        fh.write(data)
        return "Appended \(data.count) bytes to \(path)"
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
