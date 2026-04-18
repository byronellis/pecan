import Foundation

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
