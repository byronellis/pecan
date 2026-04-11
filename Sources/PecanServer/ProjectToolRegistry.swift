import Foundation
import Logging
import PecanShared

private let registryLogger = Logger(label: "com.pecan.project-tool-registry")

/// A project tool definition as stored in ~/.pecan/projects/{name}/tools.json.
/// Includes the full command — kept server-side, never sent to the agent.
struct ProjectToolConfig: Codable, Sendable {
    let name: String
    let description: String
    let command: [String]
    let workingDirectory: String
    let environment: [String: String]
    let timeout: Int
    let parametersSchema: String?

    enum CodingKeys: String, CodingKey {
        case name, description, command, environment, timeout
        case workingDirectory = "working_directory"
        case parametersSchema = "parameters_schema"
    }

    init(
        name: String,
        description: String,
        command: [String],
        workingDirectory: String = ".",
        environment: [String: String] = [:],
        timeout: Int = 300,
        parametersSchema: String? = nil
    ) {
        self.name = name
        self.description = description
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.parametersSchema = parametersSchema
    }
}

struct ProjectToolsFile: Codable, Sendable {
    let tools: [ProjectToolConfig]
}

/// Manages per-session project tool definitions: auto-detected from project type
/// plus custom overrides from ~/.pecan/projects/{name}/tools.json.
actor ProjectToolRegistry {
    static let shared = ProjectToolRegistry()

    private var sessionTools: [String: [ProjectToolConfig]] = [:]

    // MARK: - Session lifecycle

    func registerSession(sessionID: String, projectName: String, projectDirectory: String) {
        let tools = loadTools(projectName: projectName, projectDirectory: projectDirectory)
        sessionTools[sessionID] = tools
        registryLogger.info("Registered \(tools.count) project tool(s) for session \(sessionID) (project: \(projectName))")
    }

    func clearSession(_ sessionID: String) {
        sessionTools.removeValue(forKey: sessionID)
    }

    // MARK: - Queries

    func getTool(sessionID: String, name: String) -> ProjectToolConfig? {
        sessionTools[sessionID]?.first { $0.name == name }
    }

    func getAllTools(sessionID: String) -> [ProjectToolConfig] {
        sessionTools[sessionID] ?? []
    }

    // MARK: - Execution

    func executeTool(sessionID: String, name: String, projectDirectory: String, requestID: String) async -> Pecan_ToolExecutionResponse {
        var resp = Pecan_ToolExecutionResponse()
        resp.requestID = requestID

        guard let tool = getTool(sessionID: sessionID, name: name) else {
            resp.errorMessage = "Unknown project tool: '\(name)'. Available: \(getAllTools(sessionID: sessionID).map(\.name).joined(separator: ", "))"
            return resp
        }

        let workingDir: URL
        if tool.workingDirectory.isEmpty || tool.workingDirectory == "." {
            workingDir = URL(fileURLWithPath: projectDirectory)
        } else if tool.workingDirectory.hasPrefix("/") {
            workingDir = URL(fileURLWithPath: tool.workingDirectory)
        } else {
            workingDir = URL(fileURLWithPath: projectDirectory).appendingPathComponent(tool.workingDirectory)
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = tool.command
            process.currentDirectoryURL = workingDir

            var env = ProcessInfo.processInfo.environment
            for (k, v) in tool.environment { env[k] = v }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            registryLogger.info("Executing project tool '\(name)': \(tool.command.joined(separator: " ")) in \(workingDir.path)")
            try process.run()

            let timeout = tool.timeout > 0 ? tool.timeout : 300
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))

            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    resp.errorMessage = "Tool '\(name)' timed out after \(timeout)s"
                    return resp
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let exitCode = process.terminationStatus

            let (displayOutput, outputFile) = Self.processOutput(
                output, toolName: name, requestID: requestID, projectDirectory: projectDirectory
            )

            var result: [String: Any] = [
                "output": displayOutput,
                "exit_code": Int(exitCode),
                "success": exitCode == 0,
            ]
            if let outputFile { result["output_file"] = outputFile }
            let resultData = try JSONSerialization.data(withJSONObject: result)
            resp.resultJson = String(data: resultData, encoding: .utf8) ?? "{}"
        } catch {
            resp.errorMessage = "Failed to execute '\(name)': \(error.localizedDescription)"
        }

        return resp
    }

    // MARK: - Output processing

    /// If output exceeds the inline threshold, writes it to a file in the project's
    /// `.pecan/tool-output/` directory and returns a truncated summary + the agent-side path.
    /// Returns (displayOutput, agentFilePath?).
    private static let inlineThreshold = 8 * 1024  // 8 KB
    private static let headLines = 30
    private static let tailLines = 60

    private static func processOutput(
        _ output: String,
        toolName: String,
        requestID: String,
        projectDirectory: String
    ) -> (display: String, filePath: String?) {
        guard output.utf8.count > inlineThreshold else {
            return (output, nil)
        }

        // Write full output to .pecan/tool-output/ inside the project directory
        let outputDir = URL(fileURLWithPath: projectDirectory).appendingPathComponent(".pecan/tool-output")
        let fileName = "\(toolName)-\(requestID.prefix(8)).txt"
        let outputFile = outputDir.appendingPathComponent(fileName)
        let agentPath = "/project/.pecan/tool-output/\(fileName)"

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try output.write(to: outputFile, atomically: true, encoding: .utf8)
        } catch {
            registryLogger.warning("Could not write tool output file: \(error)")
            // Fall back to returning the full output rather than silently dropping it
            return (output, nil)
        }

        let lines = output.components(separatedBy: "\n")
        let totalLines = lines.count
        let head = lines.prefix(headLines).joined(separator: "\n")
        let tail = lines.suffix(tailLines).joined(separator: "\n")
        let skipped = max(0, totalLines - headLines - tailLines)

        let display: String
        if skipped > 0 {
            display = """
            \(head)

            ... [\(skipped) lines omitted — full output (\(output.utf8.count) bytes) at \(agentPath)] ...

            \(tail)
            """
        } else {
            // head + tail together cover all lines (small file just over threshold)
            display = output
        }

        return (display, agentPath)
    }

    // MARK: - Loading

    private func loadTools(projectName: String, projectDirectory: String) -> [ProjectToolConfig] {
        var detected = detectTools(in: URL(fileURLWithPath: projectDirectory))

        // Load custom tools from ~/.pecan/projects/{name}/tools.json
        let customPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pecan/projects/\(projectName)/tools.json")

        if let data = try? Data(contentsOf: customPath),
           let file = try? JSONDecoder().decode(ProjectToolsFile.self, from: data)
        {
            // Custom tools override detected ones by name, additional ones are appended
            var byName: [String: ProjectToolConfig] = Dictionary(
                uniqueKeysWithValues: detected.map { ($0.name, $0) }
            )
            for tool in file.tools {
                byName[tool.name] = tool
            }
            detected = byName.values.sorted { $0.name < $1.name }
            registryLogger.info("Loaded custom project tools from \(customPath.path)")
        }

        return detected
    }

    private func detectTools(in directory: URL) -> [ProjectToolConfig] {
        var tools: [ProjectToolConfig] = []
        let fm = FileManager.default

        // Swift Package Manager
        if fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            tools += swiftPackageTools()
        }

        // Xcode project/workspace (only if no SPM; many SPM projects also have .xcodeproj)
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let xcodeItems = contents.filter { $0.hasSuffix(".xcworkspace") }
            + contents.filter { $0.hasSuffix(".xcodeproj") && !$0.contains(".xcodeproj/project.xcworkspace") }
        if tools.isEmpty, let xcodeItem = xcodeItems.first {
            let schemeName = (xcodeItem as NSString).deletingPathExtension
            tools += xcodeTools(schemeName: schemeName)
        }

        // npm / yarn / pnpm
        if fm.fileExists(atPath: directory.appendingPathComponent("package.json").path) {
            tools += npmTools(in: directory)
        }

        // Go
        if fm.fileExists(atPath: directory.appendingPathComponent("go.mod").path) {
            tools += goTools()
        }

        // Rust / Cargo
        if fm.fileExists(atPath: directory.appendingPathComponent("Cargo.toml").path) {
            tools += rustTools()
        }

        // CMake (check before Make since CMake projects often have a wrapper Makefile)
        if fm.fileExists(atPath: directory.appendingPathComponent("CMakeLists.txt").path) {
            tools += cmakeTools()
        }

        // Make (add make targets if not already covered)
        if fm.fileExists(atPath: directory.appendingPathComponent("Makefile").path) {
            // Only add make tools if we don't already have build/test from the above
            let hasBuild = tools.contains { $0.name == "build" }
            tools += makeTools(addDefaultTargets: !hasBuild)
        }

        return tools
    }

    // MARK: - Per-ecosystem tool sets

    private func swiftPackageTools() -> [ProjectToolConfig] {
        [
            ProjectToolConfig(
                name: "build",
                description: "Build the Swift package (debug configuration)",
                command: ["swift", "build"],
                timeout: 600
            ),
            ProjectToolConfig(
                name: "build_release",
                description: "Build the Swift package (release configuration)",
                command: ["swift", "build", "-c", "release"],
                timeout: 600
            ),
            ProjectToolConfig(
                name: "test",
                description: "Run the Swift package test suite",
                command: ["swift", "test"],
                timeout: 600
            ),
        ]
    }

    private func xcodeTools(schemeName: String) -> [ProjectToolConfig] {
        [
            ProjectToolConfig(
                name: "build",
                description: "Build the Xcode project (scheme: \(schemeName))",
                command: ["xcodebuild", "-scheme", schemeName, "build"],
                timeout: 900
            ),
            ProjectToolConfig(
                name: "test",
                description: "Run the Xcode test suite (scheme: \(schemeName))",
                command: ["xcodebuild", "-scheme", schemeName, "test"],
                timeout: 900
            ),
        ]
    }

    private func npmTools(in directory: URL) -> [ProjectToolConfig] {
        // Detect package manager from lock file
        let fm = FileManager.default
        let usePnpm = fm.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path)
        let useYarn = fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path)
        let pm = usePnpm ? "pnpm" : (useYarn ? "yarn" : "npm")
        let runPrefix: [String] = pm == "npm" ? [pm, "run"] : [pm]

        // Read available scripts from package.json
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else {
            // Fallback to common defaults
            return [
                ProjectToolConfig(name: "build", description: "Build the \(pm) project", command: runPrefix + ["build"]),
                ProjectToolConfig(name: "test", description: "Run the \(pm) test suite", command: pm == "npm" ? ["npm", "test"] : runPrefix + ["test"]),
            ]
        }

        // Well-known scripts keep their name; others get prefixed to avoid collisions
        let wellKnown: Set<String> = ["build", "test", "start", "dev", "lint", "format", "check", "clean", "typecheck"]
        return scripts.keys.sorted().map { scriptName in
            let toolName = wellKnown.contains(scriptName) ? scriptName : "\(pm)_\(scriptName)"
            let runCmd: [String] = scriptName == "test" && pm == "npm"
                ? ["npm", "test"]
                : runPrefix + [scriptName]
            return ProjectToolConfig(
                name: toolName,
                description: "Run the '\(scriptName)' script via \(pm)",
                command: runCmd,
                timeout: 300
            )
        }
    }

    private func goTools() -> [ProjectToolConfig] {
        [
            ProjectToolConfig(
                name: "build",
                description: "Build the Go project (all packages)",
                command: ["go", "build", "./..."]
            ),
            ProjectToolConfig(
                name: "test",
                description: "Run the Go test suite",
                command: ["go", "test", "./..."]
            ),
            ProjectToolConfig(
                name: "vet",
                description: "Run go vet static analysis",
                command: ["go", "vet", "./..."]
            ),
        ]
    }

    private func rustTools() -> [ProjectToolConfig] {
        [
            ProjectToolConfig(
                name: "build",
                description: "Build the Rust project with cargo",
                command: ["cargo", "build"],
                timeout: 600
            ),
            ProjectToolConfig(
                name: "build_release",
                description: "Build the Rust project in release mode",
                command: ["cargo", "build", "--release"],
                timeout: 600
            ),
            ProjectToolConfig(
                name: "test",
                description: "Run the Rust test suite with cargo",
                command: ["cargo", "test"],
                timeout: 600
            ),
            ProjectToolConfig(
                name: "check",
                description: "Type-check the Rust project (faster than build)",
                command: ["cargo", "check"]
            ),
            ProjectToolConfig(
                name: "clippy",
                description: "Run the Clippy linter on the Rust project",
                command: ["cargo", "clippy"]
            ),
        ]
    }

    private func cmakeTools() -> [ProjectToolConfig] {
        [
            ProjectToolConfig(
                name: "cmake_configure",
                description: "Configure the CMake build (creates build/ directory)",
                command: ["cmake", "-B", "build", "-S", "."]
            ),
            ProjectToolConfig(
                name: "build",
                description: "Build the CMake project",
                command: ["cmake", "--build", "build"],
                timeout: 900
            ),
            ProjectToolConfig(
                name: "test",
                description: "Run CTest test suite",
                command: ["ctest", "--test-dir", "build", "--output-on-failure"],
                timeout: 600
            ),
        ]
    }

    private func makeTools(addDefaultTargets: Bool) -> [ProjectToolConfig] {
        var tools: [ProjectToolConfig] = []
        if addDefaultTargets {
            tools.append(ProjectToolConfig(
                name: "build",
                description: "Run the default Make target",
                command: ["make"],
                timeout: 600
            ))
            tools.append(ProjectToolConfig(
                name: "test",
                description: "Run 'make test'",
                command: ["make", "test"],
                timeout: 600
            ))
        }
        tools.append(ProjectToolConfig(
            name: "make_clean",
            description: "Run 'make clean'",
            command: ["make", "clean"]
        ))
        return tools
    }
}
