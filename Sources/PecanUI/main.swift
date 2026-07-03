import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import PecanSettings
import PecanAgentCore
import PecanServer

// MARK: - Server lifecycle helpers

func ensureServer(forceRestart: Bool) async throws -> Int {
    if forceRestart {
        if let status = try? ServerStatus.read(), status.isAlive {
            // Kill existing server process if it's a separate PID
            if status.pid != ProcessInfo.processInfo.processIdentifier {
                kill(status.pid, SIGTERM)
            }
        }
        ServerStatus.remove()
    } else if let status = try? ServerStatus.read(), status.isAlive {
        return status.port
    }

    // Start embedded HTTP server in background task inside this TUI process
    let boundPort = try await startHTTPProxyServer(background: true)
    return boundPort
}

// MARK: - Main TUI execution

func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan TUI...\r")
        ServerStatus.remove()
        exit(0)
    }

    let args = CommandLine.arguments.dropFirst()
    
    // Ensure config.yaml is present on startup
    let configPath = ProxyConfig.configFilePath
    if !FileManager.default.fileExists(atPath: configPath) && args.first != "configure" && args.first != "config" && args.first != "server" {
        print("config.yaml not found at \(configPath). Entering Onboarding Configuration...\r\n")
        await runConfigureTUI()
        if !FileManager.default.fileExists(atPath: configPath) {
            print("Configuration was cancelled or not saved. Exiting.\r")
            exit(0)
        }
    }
    
    // Standalone server mode subcommand: pecan server
    if let first = args.first, first == "server" {
        print("Starting standalone HTTP Proxy server mode...\r")
        do {
            try await startHTTPProxyServer(background: false)
        } catch {
            print("Server error: \(error.localizedDescription)\r")
            exit(1)
        }
        return
    }

    if let first = args.first, first == "configure" || first == "config" {
        await runConfigureTUI()
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

    // Ensure proxy server is running (either existing external, or start new embedded)
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
    print("Embedded HTTP Proxy running at 127.0.0.1:\(serverPort)...\r\n", terminator: "\n")
    
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
              \(ansiCyan)/model\(ansiReset) \(ansiDim)<name>\(ansiReset)    View/set model for current agent
              \(ansiCyan)/config\(ansiReset)           Open Configuration Manager
              \(ansiCyan)/help\(ansiReset)             Show this help screen
              \(ansiCyan)/quit\(ansiReset)             Exit Pecan TUI
            """
            await TerminalManager.shared.printOutput(help)
            continue
        }

        if trimmed == "/config" {
            await runConfigureTUI()
            // Redraw TUI screen
            clearScreen()
            moveTo(1, 1)
            print("🥜 Pecan Local TUI".bold + "\r", terminator: "\n")
            print("Embedded HTTP Proxy running...\r\n", terminator: "\n")
            let activeTabs = await sessionState.agentTabList()
            await TerminalManager.shared.updateAgentTabs(activeTabs)
            await TerminalManager.shared.redrawPrompt()
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

        if trimmed == "/model" {
            let activeAgentID = await PromptComposer.shared.activePersonaName ?? "general"
            if let agentConfig = try? await SettingsStore.shared.agent(id: activeAgentID) {
                let modelDisplay = agentConfig.model ?? "global default"
                await TerminalManager.shared.printSystem("Agent '\(activeAgentID)' is using model: \(modelDisplay)")
            }
            continue
        }

        if trimmed.hasPrefix("/model ") {
            let modelName = String(trimmed.dropFirst("/model ".count)).trimmingCharacters(in: .whitespaces)
            let activeAgentID = await PromptComposer.shared.activePersonaName ?? "general"
            if var agentConfig = try? await SettingsStore.shared.agent(id: activeAgentID) {
                agentConfig.model = (modelName.isEmpty || modelName.lowercased() == "default" || modelName.lowercased() == "none") ? nil : modelName
                try? await SettingsStore.shared.saveAgent(agentConfig)
                let modelDisplay = agentConfig.model ?? "global default"
                await TerminalManager.shared.printSystem("Updated model for agent '\(activeAgentID)' to \(modelDisplay)")
            } else {
                await TerminalManager.shared.printSystem("No configured agent found for '\(activeAgentID)'")
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
    ServerStatus.remove()
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
