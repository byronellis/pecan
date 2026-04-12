import Foundation
import Testing

/// Manages subprocess lifecycle (mock LLM + pecan-server) for integration tests.
///
/// Usage:
/// ```swift
/// let h = try await TestHarness.start()
/// defer { await h.stop() }
/// // ... run test against h.mockLLM and h.serverPort
/// ```
actor TestHarness {

    let tempDir: URL
    let mockLLM: MockLLMClient
    let serverPort: Int
    let serverWorkDir: URL

    private let mockLLMProcess: Process
    private let serverProcess: Process

    // MARK: - Factory

    static func start(mockLLMPort: Int = 0) async throws -> TestHarness {
        let buildDir = Self.buildDirectory()

        // 1. Create isolated temp work dirs.
        // Use short paths under /tmp to stay within Unix socket path limit (104 chars).
        // sockaddr_un.sun_path max = 104; "/tmp/pt-XXXXXXXX/.run/launcher.sock" = ~40 chars ✓
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let tempDir = URL(fileURLWithPath: "/tmp/pt-\(shortID)")
        let homeDir = tempDir.appendingPathComponent("h")
        let serverWorkDir = tempDir.appendingPathComponent("s")

        for dir in [homeDir, serverWorkDir,
                    homeDir.appendingPathComponent(".pecan"),
                    serverWorkDir.appendingPathComponent(".run")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 2. Start mock LLM on a free port
        let llmProcess = Process()
        let mockLLMExe = buildDir.appendingPathComponent("pecan-mock-llm")
        guard FileManager.default.fileExists(atPath: mockLLMExe.path) else {
            throw TestError.processLaunchFailed("pecan-mock-llm not found at \(mockLLMExe.path). Run 'swift build' first.")
        }
        llmProcess.executableURL = mockLLMExe

        let llmPort: Int
        if mockLLMPort != 0 {
            llmProcess.arguments = ["--port", "\(mockLLMPort)"]
            llmPort = mockLLMPort
        } else {
            // Use a port in the ephemeral range offset by PID to reduce collisions
            let base = 19000 + (Int(ProcessInfo.processInfo.processIdentifier) % 1000)
            llmProcess.arguments = ["--port", "\(base)"]
            llmPort = base
        }

        let llmPipe = Pipe()
        llmProcess.standardOutput = llmPipe
        llmProcess.standardError = FileHandle.nullDevice
        try llmProcess.run()

        // 3. Write pecan config pointing to mock LLM
        let config = """
        models:
          default:
            provider: openai
            url: http://127.0.0.1:\(llmPort)
            api_key: none
            model_id: mock
        default_model: default
        """
        try config.write(
            to: homeDir.appendingPathComponent(".pecan/config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // 4. Wait for mock LLM
        let llmClient = MockLLMClient(port: llmPort)
        try await llmClient.waitUntilReady(timeout: 10)

        // 5. Start pecan-server
        let serverExe = buildDir.appendingPathComponent("pecan-server")
        guard FileManager.default.fileExists(atPath: serverExe.path) else {
            llmProcess.terminate()
            throw TestError.processLaunchFailed("pecan-server not found at \(serverExe.path). Run 'swift build' first.")
        }

        let srvLogPath = tempDir.appendingPathComponent("server.log").path
        let srvLogHandle = FileHandle(forWritingAtPath: srvLogPath) ?? {
            FileManager.default.createFile(atPath: srvLogPath, contents: nil)
            return FileHandle(forWritingAtPath: srvLogPath)!
        }()

        let srvProcess = Process()
        srvProcess.executableURL = serverExe
        srvProcess.currentDirectoryURL = serverWorkDir
        // Inherit env so TMPDIR, XPC vars etc. are present; override config path
        var srvEnv = ProcessInfo.processInfo.environment
        srvEnv["HOME"] = homeDir.path
        srvEnv["PECAN_CONFIG_PATH"] = homeDir.appendingPathComponent(".pecan/config.yaml").path
        srvProcess.environment = srvEnv
        srvProcess.standardOutput = srvLogHandle
        srvProcess.standardError = srvLogHandle
        try srvProcess.run()

        // 6. Wait for server status file
        let statusPath = serverWorkDir.appendingPathComponent(".run/server.json").path
        let serverPort = try await waitForServerStatus(atPath: statusPath, timeout: 15)

        return TestHarness(
            tempDir: tempDir,
            mockLLM: llmClient,
            serverPort: serverPort,
            serverWorkDir: serverWorkDir,
            mockLLMProcess: llmProcess,
            serverProcess: srvProcess
        )
    }

    // MARK: - Init

    private init(tempDir: URL, mockLLM: MockLLMClient, serverPort: Int,
                 serverWorkDir: URL, mockLLMProcess: Process, serverProcess: Process) {
        self.tempDir = tempDir
        self.mockLLM = mockLLM
        self.serverPort = serverPort
        self.serverWorkDir = serverWorkDir
        self.mockLLMProcess = mockLLMProcess
        self.serverProcess = serverProcess
    }

    // MARK: - Teardown

    func stop() {
        serverProcess.terminate()
        mockLLMProcess.terminate()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Poll for .run/server.json and extract the port.
    private static func waitForServerStatus(atPath path: String, timeout: TimeInterval) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = json["port"] as? Int, port > 0 {
                return port
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw TestError.timeout("pecan-server did not write server.json within \(timeout)s")
    }

    /// Returns the path to the debug build directory.
    static func buildDirectory() -> URL {
        // Navigate: Tests/PecanIntegrationTests/TestHarness.swift → package root → .build/debug
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PecanIntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
            .appendingPathComponent(".build/debug")
    }
}
