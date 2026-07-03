import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import PecanSettings
import PecanAgentCore

// MARK: - Server lifecycle helpers

func findServerBinary() -> URL? {
    if let envPath = ProcessInfo.processInfo.environment["PECAN_SERVER_PATH"] {
        let url = URL(fileURLWithPath: envPath).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidate = execURL.deletingLastPathComponent().appendingPathComponent("pecan-server")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

func launchServer() throws {
    guard let serverURL = findServerBinary() else {
        throw NSError(domain: "Pecan", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "pecan-server not found alongside \(CommandLine.arguments[0])"
        ])
    }
    let runDir = "\(FileManager.default.currentDirectoryPath)/.run"
    try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
    let logPath = "\(runDir)/server.log"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))

    let process = Process()
    process.executableURL = serverURL
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()
    print("Server started (PID \(process.processIdentifier)), logs: \(logPath)\r")
}

func ensureServer(forceRestart: Bool) async throws -> Int {
    let runDir = "\(FileManager.default.currentDirectoryPath)/.run"
    let logPath = "\(runDir)/server.log"

    if forceRestart, let existing = try? ServerStatus.read(), existing.isAlive {
        print("Stopping server (PID \(existing.pid))...\r")
        kill(existing.pid, SIGTERM)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if kill(existing.pid, 0) != 0 { break }
        }
        ServerStatus.remove()
    }

    if let status = try? ServerStatus.read(), status.isAlive {
        return status.port
    }

    print("Starting pecan-server... (logs: \(logPath))\r")
    try launchServer()
    for _ in 0..<60 {
        try await Task.sleep(nanoseconds: 500_000_000)
        if let status = try? ServerStatus.read(), status.isAlive {
            return status.port
        }
    }
    throw NSError(domain: "Pecan", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Server did not start within 30 seconds. Check logs: \(logPath)"
    ])
}

// MARK: - Main TUI execution

func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan TUI...\r")
        exit(0)
    }

    let args = CommandLine.arguments.dropFirst()
    if let first = args.first, first == "configure" || first == "config" {
        print("Settings configuration manager not needed. Configure ~/.pecan/config.yaml directly.\r")
        return
    }

    var cliForceRestart = false
    var cliProjectName: String? = nil
    var i = 1
    while i < CommandLine.arguments.count {
        switch CommandLine.arguments[i] {
        case "--project":
            i += 1
            if i < CommandLine.arguments.count { cliProjectName = CommandLine.arguments[i] }
        case "--force-restart":
            cliForceRestart = true
        default: break
        }
        i += 1
    }

    // Ensure proxy server is running
    let serverPort: Int
    do {
        serverPort = try await ensureServer(forceRestart: cliForceRestart)
    } catch {
        print("Error starting proxy server: \(error.localizedDescription)\r")
        exit(1)
    }

    // Set project context path
    let projectDir = FileManager.default.currentDirectoryPath
    let projectName = cliProjectName ?? URL(fileURLWithPath: projectDir).lastPathComponent
    await PromptComposer.shared.setProjectContext(name: projectName, directory: projectDir, mount: projectDir)
    
    // Register builtin tools (direct execution tools)
    await ToolManager.shared.registerBuiltinTools()
    await ToolManager.shared.loadTools()
    
    // UI setup
    clearScreen()
    moveTo(1, 1)
    print("🥜 Pecan Local TUI".bold + "\r", terminator: "\n")
    print("LLM Proxy running at 127.0.0.1:\(serverPort)...\r\n", terminator: "\n")
    
    let sessionState = SessionState()
    
    // Initialize the default agent session
    await sessionState.addSession(id: UUID().uuidString, name: "Session-1", projectName: projectName, agentNumber: 1)
    
    let tabs = await sessionState.agentTabList()
    await TerminalManager.shared.updateAgentTabs(tabs)
    await TerminalManager.shared.updateProjectTeam(project: projectName, team: nil)
    
    // Start terminal input loop
    await TerminalManager.shared.printSystem("Type your instruction and press Enter. /help for commands.")
    await TerminalManager.shared.setInputActive(true)
    
    while true {
        guard let line = await readInputLine(sessionState: sessionState) else { break }

        // ESC interrupt sentinel
        if line == "\u{00}" {
            await TerminalManager.shared.printSystem("Operation cancelled.")
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "/quit" || trimmed == "exit" {
            break
        }

        if trimmed == "/help" {
            let help = """
            \(ansiBold)Commands\(ansiReset)
              \(ansiCyan)/new\(ansiReset)              Spawn a new session
              \(ansiCyan)/agents\(ansiReset)           List all active sessions
              \(ansiCyan)/switch\(ansiReset) \(ansiDim)<name>\(ansiReset)    Switch to session by name
              \(ansiCyan)/close\(ansiReset)            Close the current session
              \(ansiCyan)/clear\(ansiReset)            Clear conversation history
              \(ansiCyan)/help\(ansiReset)             Show this help screen
              \(ansiCyan)/quit\(ansiReset)             Exit Pecan TUI
            """
            await TerminalManager.shared.printOutput(help)
            continue
        }

        if trimmed == "/agents" {
            let activeTabs = await sessionState.agentTabList()
            var list = "\(ansiBold)Active Sessions\(ansiReset)\r\n"
            for tab in activeTabs {
                let marker = tab.isActive ? "\(ansiCyan) ← active\(ansiReset)" : ""
                list += "  #\(tab.agentNumber) \(tab.name)\(marker)\r\n"
            }
            await TerminalManager.shared.printOutput(list)
            continue
        }

        if trimmed == "/new" {
            let nextNum = Int32(await sessionState.allSessions().count + 1)
            await sessionState.addSession(id: UUID().uuidString, name: "Session-\(nextNum)", projectName: projectName, agentNumber: nextNum)
            let activeTabs = await sessionState.agentTabList()
            await TerminalManager.shared.updateAgentTabs(activeTabs)
            await TerminalManager.shared.printSystem("Created new session: Session-\(nextNum)")
            continue
        }

        if trimmed.hasPrefix("/switch ") {
            let name = String(trimmed.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespaces)
            let success = await sessionState.setActiveByName(name)
            if success {
                let activeTabs = await sessionState.agentTabList()
                await TerminalManager.shared.updateAgentTabs(activeTabs)
                await TerminalManager.shared.printSystem("Switched to session: \(name)")
            } else {
                await TerminalManager.shared.printSystem("Session '\(name)' not found.")
            }
            continue
        }

        if trimmed == "/close" {
            guard let sid = await sessionState.getActiveID() else { continue }
            await sessionState.removeSession(id: sid)
            let remaining = await sessionState.agentTabList()
            await TerminalManager.shared.updateAgentTabs(remaining)
            if remaining.isEmpty {
                await TerminalManager.shared.printSystem("All sessions closed. Exiting.")
                break
            }
            if let first = remaining.first {
                await sessionState.setActive(first.id)
            }
            await TerminalManager.shared.printSystem("Session closed.")
            continue
        }

        if trimmed == "/clear" {
            if let active = await sessionState.getActiveSession() {
                await active.clearHistory()
                await TerminalManager.shared.printSystem("History cleared.")
            }
            continue
        }

        if !trimmed.isEmpty {
            await TerminalManager.shared.printUserInput(trimmed)
            
            if let active = await sessionState.getActiveSession() {
                do {
                    try await active.execute(prompt: trimmed, serverPort: serverPort)
                } catch {
                    await TerminalManager.shared.printSystem("Execution error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    await TerminalManager.shared.setInputActive(false)
    print("\r\nExiting Pecan TUI...\r", terminator: "\n")
}

// Start TUI
Task {
    do {
        try await main()
    } catch {
        print("TUI Crash: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
