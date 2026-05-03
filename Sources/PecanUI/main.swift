import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import GRPC
import NIO
import PecanShared
import PecanSettings


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

func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan UI...\r")
        exit(0)
    }

    // Check for configure/config subcommand
    let args = CommandLine.arguments.dropFirst()
    if let first = args.first, first == "configure" || first == "config" {
        await runConfigureTUI()
        return
    }

    // First-run detection: open settings to see if any providers are configured
    do {
        try await SettingsStore.shared.open()
        let providers = try await SettingsStore.shared.allProviders()
        if providers.isEmpty {
            print("No providers configured. Launching setup wizard...\r\n")
            await runConfigureTUI()
        }
    } catch {
        // If we can't open the DB at all, proceed anyway (server will handle it)
    }

    // Parse CLI arguments
    var cliProjectName: String? = nil
    var cliTeamName: String? = nil
    var cliPersistent: Bool = false
    var cliForceRestart: Bool = false
    do {
        var i = 1
        while i < CommandLine.arguments.count {
            switch CommandLine.arguments[i] {
            case "--project":
                i += 1
                if i < CommandLine.arguments.count { cliProjectName = CommandLine.arguments[i] }
            case "--team":
                i += 1
                if i < CommandLine.arguments.count { cliTeamName = CommandLine.arguments[i] }
            case "--keep", "-k":
                cliPersistent = true
            case "--force-restart":
                cliForceRestart = true
            case "configure", "config":
                break  // already handled above
            default: break
            }
            i += 1
        }
    }

    // Discover or launch the server
    let serverPort: Int
    do {
        serverPort = try await ensureServer(forceRestart: cliForceRestart)
    } catch {
        print("Error: \(error.localizedDescription)\r")
        exit(1)
    }

    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: serverPort),
        transportSecurity: .plaintext,
        eventLoopGroup: group
    ) { config in
        config.keepalive = ClientConnectionKeepalive(
            interval: .seconds(15),
            timeout: .seconds(10),
            permitWithoutCalls: true,
            maximumPingsWithoutData: 0
        )
        config.connectionBackoff = ConnectionBackoff(
            initialBackoff: 1.0,
            maximumBackoff: 60.0,
            multiplier: 1.6,
            jitter: 0.2
        )
    }

    let client = Pecan_ClientServiceAsyncClient(channel: channel)

    /// Bridges the async receiver loop and the synchronous startup flow.
    actor SessionListWaiter {
        private var cont: CheckedContinuation<[Pecan_SessionInfo], Never>?
        private var delivered = false
        private var result: [Pecan_SessionInfo] = []

        /// Returns true if this was the startup delivery (consumed by wait()), false if post-startup.
        @discardableResult
        func deliver(_ sessions: [Pecan_SessionInfo]) -> Bool {
            guard !delivered else { return false }
            delivered = true
            result = sessions
            cont?.resume(returning: sessions)
            cont = nil
            return true
        }

        func wait() async -> [Pecan_SessionInfo] {
            if delivered { return result }
            return await withCheckedContinuation { c in cont = c }
        }
    }
    let sessionListWaiter = SessionListWaiter()

    // Open Bidirectional Stream
    let call = client.makeStreamEventsCall()

    // UI Setup
    clearScreen()
    moveTo(1, 1)
    print("🥜 Pecan Interactive UI".bold + "\r", terminator: "\n")
    print("Connecting to server at 127.0.0.1:\(serverPort)...\r\n", terminator: "\n")
    
    let sessionState = SessionState()

    // Start a task to listen for server messages
    let receiverTask = Task {
        do {
            for try await message in call.responseStream {
                switch message.payload {
                case .sessionStarted(let started):
                    let name = started.agentName.isEmpty ? "agent" : started.agentName
                    await sessionState.addSession(id: started.sessionID, name: name, projectName: started.projectName, teamName: started.teamName, agentNumber: started.agentNumber)
                    let tabs = await sessionState.agentTabList()
                    await TerminalManager.shared.updateAgentTabs(tabs)
                    let projectDisplay = await sessionState.getActiveProjectName()
                    let teamDisplay = await sessionState.getActiveTeamName()
                    await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    var startMsg = "Session started: \(name) (\(started.sessionID))"
                    if !started.projectName.isEmpty {
                        startMsg += " [project: \(started.projectName)]"
                    }
                    if !started.teamName.isEmpty && started.teamName != "default" {
                        startMsg += " [team: \(started.teamName)]"
                    }
                    await TerminalManager.shared.printSystem(startMsg)

                case .agentOutput(let output):
                    // Handle session_closed before active-session check — applies regardless
                    if let data = output.text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       json["type"] == "session_closed" {
                        let closedID = output.sessionID
                        let closedName = await sessionState.getName(for: closedID) ?? closedID
                        await sessionState.removeSession(id: closedID)
                        let remaining = await sessionState.agentTabList()
                        await TerminalManager.shared.updateAgentTabs(remaining)
                        if remaining.isEmpty {
                            await TerminalManager.shared.printSystem("Session '\(closedName)' closed. No sessions remaining.")
                            exit(0)
                        }
                        let next = remaining.first!
                        await switchToAgent(id: next.id, sessionState: sessionState)
                        await TerminalManager.shared.printSystem("Session '\(closedName)' closed.")
                        await TerminalManager.shared.printSystem("Remaining agents:")
                        for tab in remaining {
                            let num = tab.agentNumber > 0 ? "\(tab.agentNumber)" : "·"
                            let marker = tab.id == next.id ? " ← active" : ""
                            await TerminalManager.shared.printSystem("  \(num). \(tab.name)\(marker)")
                        }
                        continue
                    }

                    let isActive = await sessionState.isActiveSession(output.sessionID)

                    if isActive {
                        // Render live — includes side effects like throbbers
                        if let data = output.text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                           let msgType = json["type"] {
                            // Start throbber for thinking/tool_call (side effect only for live view)
                            if msgType == "thinking" {
                                await TerminalManager.shared.startThrobber(message: "Thinking...")
                            } else if msgType == "tool_call" {
                                let toolName = json["name"] ?? "unknown"
                                if let rendered = renderAgentOutput(output.text) {
                                    await TerminalManager.shared.printOutput(rendered)
                                }
                                await TerminalManager.shared.startThrobber(message: "Running \(toolName)...")
                            } else if let rendered = renderAgentOutput(output.text) {
                                await TerminalManager.shared.printOutput(rendered)
                            }
                        } else if let rendered = renderAgentOutput(output.text) {
                            await TerminalManager.shared.printOutput(rendered)
                        }
                    } else {
                        // Buffer raw text for non-active sessions
                        await sessionState.bufferOutput(output.sessionID, rawText: output.text)
                    }

                case .approvalRequest(let req):
                    await TerminalManager.shared.printSystem("Tool Approval Required: \(req.toolName)\r\nArguments: \(req.argumentsJson)\r\nApprove? (y/n)")

                case .taskCompleted(let comp):
                    await TerminalManager.shared.printSystem("Task completed: \(comp.sessionID)")

                case .taskUpdate(let update):
                    await sessionState.setFocusedTask(sessionID: update.sessionID, title: update.focusedTaskTitle)
                    let focusedTitle = await sessionState.getActiveFocusedTask()
                    await TerminalManager.shared.updateFocusedTask(focusedTitle)

                case .sessionUpdate(let update):
                    await sessionState.updateProjectTeam(
                        sessionID: update.sessionID,
                        projectName: update.projectName,
                        teamName: update.teamName
                    )
                    // Refresh breadcrumbs if this is the active session
                    if await sessionState.getActiveID() == update.sessionID {
                        let projectDisplay = await sessionState.getActiveProjectName()
                        let teamDisplay = await sessionState.getActiveTeamName()
                        await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    }

                case .sessionList(let list):
                    let delivered = await sessionListWaiter.deliver(list.sessions)
                    if !delivered {
                        // Post-startup update (e.g., after /number renumber) — refresh ordering
                        for s in list.sessions {
                            await sessionState.updateAgentNumber(sessionID: s.sessionID, agentNumber: s.agentNumber)
                        }
                        let updatedTabs = await sessionState.agentTabList()
                        await TerminalManager.shared.updateAgentTabs(updatedTabs)
                    }

                case nil:
                    break
                }
            }
        } catch {
            await TerminalManager.shared.printSystem("Disconnected from server: \(error)")
        }
    }

    // Ask server for any running sessions, then decide to reattach or start new
    var listReq = Pecan_ClientMessage()
    listReq.listSessions = Pecan_ListSessionsRequest()
    try await call.requestStream.send(listReq)

    // Wait up to 1.5s for the session list before falling through to start-new
    let liveSessions = await withTaskGroup(of: [Pecan_SessionInfo].self) { group in
        group.addTask { await sessionListWaiter.wait() }
        group.addTask {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await sessionListWaiter.deliver([])
            return []
        }
        let r = await group.next()!
        group.cancelAll()
        return r
    }

    if !liveSessions.isEmpty {
        // Pre-populate all known sessions so the status bar, /agents, and /switch
        // work immediately — even before the user has reattached to a specific one.
        for s in liveSessions {
            await sessionState.registerSession(
                id: s.sessionID,
                name: s.agentName.isEmpty ? "agent" : s.agentName,
                projectName: s.projectName,
                teamName: s.teamName,
                agentNumber: s.agentNumber
            )
        }
        let initialTabs = await sessionState.agentTabList()
        await TerminalManager.shared.updateAgentTabs(initialTabs)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func relativeAge(_ isoString: String) -> String {
            guard let date = iso.date(from: isoString) else { return "" }
            let secs = Int(-date.timeIntervalSinceNow)
            if secs < 60 { return "just now" }
            if secs < 3600 { return "\(secs / 60)m ago" }
            if secs < 86400 { return "\(secs / 3600)h ago" }
            return "\(secs / 86400)d ago"
        }

        await TerminalManager.shared.printSystem("Running agents:")
        for s in liveSessions {
            let num = s.agentNumber > 0 ? s.agentNumber : 0
            var label = "  \(num).  \(s.agentName)"
            if !s.projectName.isEmpty { label += "  [\(s.projectName)]" }
            label += s.isBusy ? "  · busy" : "  · idle"
            if !s.startedAt.isEmpty { label += "  · \(relativeAge(s.startedAt))" }
            await TerminalManager.shared.printSystem(label)
        }
        await TerminalManager.shared.printSystem("")
        await TerminalManager.shared.printSystem("Enter an agent number to reattach, or press Enter to start a new agent:")

        let choice = await readInputLine(sessionState: sessionState)
        let trimmedChoice = choice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let n = Int32(trimmedChoice), let target = liveSessions.first(where: { $0.agentNumber == n }) {
            var reattachMsg = Pecan_ClientMessage()
            var reattach = Pecan_ReattachRequest()
            reattach.sessionID = target.sessionID
            reattachMsg.reattach = reattach
            try await call.requestStream.send(reattachMsg)
        } else {
            // Fall through to start a new agent
            var initialMsg = Pecan_ClientMessage()
            var startTask = Pecan_StartTaskRequest()
            startTask.initialPrompt = "Initialize new session"
            if let p = cliProjectName { startTask.projectName = p }
            if let t = cliTeamName { startTask.teamName = t }
            startTask.persistent = cliPersistent
            initialMsg.startTask = startTask
            try await call.requestStream.send(initialMsg)
        }
    } else {
        var initialMsg = Pecan_ClientMessage()
        var startTask = Pecan_StartTaskRequest()
        startTask.initialPrompt = "Initialize new session"
        if let p = cliProjectName { startTask.projectName = p }
        if let t = cliTeamName { startTask.teamName = t }
        startTask.persistent = cliPersistent
        initialMsg.startTask = startTask
        try await call.requestStream.send(initialMsg)
    }
    
    // Helper: send an /exec command for the active session
    func sendExec(_ command: String, sessionID: String) async throws {
        var msg = Pecan_ClientMessage()
        var input = Pecan_TaskInput()
        input.sessionID = sessionID
        input.text = "/exec \(command)"
        msg.userInput = input
        try await call.requestStream.send(msg)
    }

    // Input Loop
    while true {
        guard let line = await readInputLine(sessionState: sessionState) else { break }

        // ESC interrupt sentinel
        if line == "\u{00}" {
            if let sid = await sessionState.getActiveID() {
                await TerminalManager.shared.printSystem("Interrupting agent...")
                var msg = Pecan_ClientMessage()
                var input = Pecan_TaskInput()
                input.sessionID = sid
                input.text = "Please stop what you are doing immediately and wait for my next instruction."
                msg.userInput = input
                try await call.requestStream.send(msg)
            }
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "/quit" || trimmed == "exit" {
            break
        }

        if trimmed == "/detach" {
            if let sid = await sessionState.getActiveID() {
                var msg = Pecan_ClientMessage()
                msg.detachSession = Pecan_DetachSession.with { $0.sessionID = sid }
                try await call.requestStream.send(msg)
                await TerminalManager.shared.printSystem("Detached — agent continues running. Reconnect with: pecan")
            } else {
                await TerminalManager.shared.printSystem("No active session to detach.")
            }
            break
        }

        // ! prefix — shell mode shortcut
        if trimmed == "!" {
            // Interactive shell sub-loop
            guard let sid = await sessionState.getActiveID() else {
                await TerminalManager.shared.printSystem("No active session.")
                continue
            }
            await TerminalManager.shared.printSystem("Shell mode — type commands to run in container, empty line or 'exit' to return.")
            while true {
                guard let shellLine = await readInputLine(sessionState: sessionState) else { break }
                if shellLine == "\u{00}" { break }
                let shellCmd = shellLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if shellCmd.isEmpty || shellCmd == "exit" || shellCmd == "quit" { break }
                await TerminalManager.shared.printUserInput("$ \(shellCmd)")
                try await sendExec(shellCmd, sessionID: sid)
            }
            continue
        }

        if trimmed.hasPrefix("!") {
            // Single exec command: !<cmd>
            let cmd = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !cmd.isEmpty else { continue }
            guard let sid = await sessionState.getActiveID() else {
                await TerminalManager.shared.printSystem("No active session.")
                continue
            }
            await TerminalManager.shared.printUserInput("$ \(cmd)")
            try await sendExec(cmd, sessionID: sid)
            continue
        }

        if !trimmed.isEmpty {
            await TerminalManager.shared.printUserInput(trimmed)

            // /help — show available commands
            if trimmed == "/help" {
                let help = """
                \(ansiBold)Commands\(ansiReset)
                  \(ansiCyan)/new\(ansiReset)              Spawn a new agent
                  \(ansiCyan)/fork\(ansiReset)             Fork current agent (copies context & shares)
                  \(ansiCyan)/agents\(ansiReset)            List all agents
                  \(ansiCyan)/switch\(ansiReset) \(ansiDim)<name>\(ansiReset)    Switch to agent by name
                  \(ansiCyan)/number\(ansiReset) \(ansiDim)<n>\(ansiReset)       Assign this agent a stable display number
                  \(ansiCyan)/share\(ansiReset) \(ansiDim)[-rw] <path>[:<guest>]\(ansiReset)
                                    Share a host directory with the agent
                  \(ansiCyan)/unshare\(ansiReset) \(ansiDim)<path>\(ansiReset)  Remove a shared directory
                  \(ansiCyan)/network\(ansiReset)          Show network status (default: off)
                  \(ansiCyan)/network:on\(ansiReset)       Enable networking (snapshots image, restarts)
                  \(ansiCyan)/network:off\(ansiReset)      Disable networking (snapshots image, restarts)
                  \(ansiCyan)/image\(ansiReset)             Show image snapshot status
                  \(ansiCyan)/image:save\(ansiReset)        Save container state as image snapshot
                  \(ansiCyan)/image:discard\(ansiReset)     Discard image snapshot (use clean alpine)
                  \(ansiCyan)/changeset\(ansiReset)        Show agent's current overlay diff (/cs)
                  \(ansiCyan)/changeset:promote\(ansiReset) Apply changes to project directory
                  \(ansiCyan)/changeset:discard\(ansiReset) Wipe all changes from overlay
                  \(ansiCyan)/changeset:submit\(ansiReset) \(ansiDim)[note]\(ansiReset)  Submit to merge queue
                  \(ansiCyan)/mergequeue\(ansiReset)       List merge queue (/mq)
                  \(ansiCyan)/mq:approve\(ansiReset) \(ansiDim)<id>\(ansiReset)  Approve and promote changeset
                  \(ansiCyan)/mq:reject\(ansiReset) \(ansiDim)<id>\(ansiReset)   Reject changeset
                  \(ansiCyan)/close\(ansiReset)            Terminate current agent, switch to next (or exit if last)
                  \(ansiCyan)/clear\(ansiReset)            Clear conversation history, keep persona/system prompt
                  \(ansiCyan)/compact\(ansiReset)          Summarize conversation via LLM subagent, replace with summary
                  \(ansiCyan)/detach\(ansiReset)           Disconnect UI, keep agent running
                  \(ansiCyan)/quit\(ansiReset)             Exit Pecan and stop the agent

                \(ansiBold)Tasks\(ansiReset) \(ansiDim)(/t = /task, /ts = /tasks)\(ansiReset)
                  \(ansiCyan)/t\(ansiReset) \(ansiDim)<text>\(ansiReset)          Create a new task
                  \(ansiCyan)/ts\(ansiReset)                List all tasks
                  \(ansiCyan)/ts\(ansiReset) \(ansiDim)<status>\(ansiReset)       List tasks by status
                  \(ansiCyan)/t #\(ansiReset)\(ansiDim)<id>\(ansiReset)           Show task details
                  \(ansiCyan)/t #\(ansiReset)\(ansiDim)<id>\(ansiReset) \(ansiDim)<field> <value>\(ansiReset)
                                    Update task field
                  \(ansiDim)Scope: /t:t = team, /t:p = project, /t:t:name = specific team\(ansiReset)

                \(ansiBold)Projects\(ansiReset) \(ansiDim)(/p = /project)\(ansiReset)
                  \(ansiCyan)/p\(ansiReset)                Show current project
                  \(ansiCyan)/p:list\(ansiReset)            List all projects
                  \(ansiCyan)/p:create\(ansiReset) \(ansiDim)<name> [dir]\(ansiReset)
                                    Create a new project
                  \(ansiCyan)/p:switch\(ansiReset) \(ansiDim)<name>\(ansiReset)   Switch to a project

                \(ansiBold)Teams\(ansiReset)
                  \(ansiCyan)/team\(ansiReset)              Show current team
                  \(ansiCyan)/team:list\(ansiReset)         List teams in project
                  \(ansiCyan)/team:create\(ansiReset) \(ansiDim)<name>\(ansiReset) Create a new team
                  \(ansiCyan)/team:join\(ansiReset) \(ansiDim)<name>\(ansiReset)   Join a team
                  \(ansiCyan)/team:leave\(ansiReset)        Leave current team

                \(ansiBold)Shell\(ansiReset)
                  \(ansiCyan)!\(ansiReset)\(ansiDim)<cmd>\(ansiReset)             Run a shell command in the container
                  \(ansiCyan)!\(ansiReset)                 Interactive shell mode (empty line to exit)

                \(ansiBold)Keys\(ansiReset)
                  \(ansiCyan)Esc\(ansiReset)               Interrupt the running agent
                  \(ansiCyan)Esc\(ansiReset) \(ansiDim)(with text)\(ansiReset)    Clear input line
                  \(ansiCyan)↑\(ansiReset) / \(ansiCyan)↓\(ansiReset)            Command history (per agent)
                  \(ansiCyan)Tab\(ansiReset)               Agent picker (↑↓ or hotkey to select)
                  \(ansiCyan)^A\(ansiReset) / \(ansiCyan)^E\(ansiReset)          Beginning / end of line
                  \(ansiCyan)^K\(ansiReset) / \(ansiCyan)^U\(ansiReset)          Kill to end / start of line
                  \(ansiCyan)^W\(ansiReset)                Kill word backward
                  \(ansiCyan)^Y\(ansiReset)                Yank (paste killed text)

                \(ansiBold)Agent navigation\(ansiReset) \(ansiDim)(Alt = Esc then key)\(ansiReset)
                  \(ansiCyan)Alt+n\(ansiReset) / \(ansiCyan)Alt+p\(ansiReset)    Next / prev agent within team
                  \(ansiCyan)Alt+1..9\(ansiReset)          Jump to agent N within team
                  \(ansiCyan)Alt+t\(ansiReset)             Team picker (←→ or key to select)
                """
                await TerminalManager.shared.printOutput(help)
                continue
            }

            // /agents — list all agents
            if trimmed == "/agents" {
                let tabs = await sessionState.agentTabList()
                if tabs.isEmpty {
                    await TerminalManager.shared.printSystem("No agents.")
                } else {
                    var lines = "\(ansiBold)Agents\(ansiReset)\r\n"
                    // Group by team
                    var teamOrder: [String] = []
                    var teamGroups: [String: [AgentTabInfo]] = [:]
                    for tab in tabs {
                        if teamGroups[tab.teamKey] == nil {
                            teamOrder.append(tab.teamKey)
                            teamGroups[tab.teamKey] = []
                        }
                        teamGroups[tab.teamKey]!.append(tab)
                    }
                    for teamKey in teamOrder {
                        guard let group = teamGroups[teamKey] else { continue }
                        let header = teamKey.isEmpty ? "  \(ansiDim)(no team)\(ansiReset)\r\n" : "  \(ansiDim)\(teamKey):\(ansiReset)\r\n"
                        lines += header
                        for tab in group {
                            let marker = tab.isActive ? "\(ansiCyan) ← active\(ansiReset)" : ""
                            let unread = tab.hasUnread ? " \(ansiDim)*\(ansiReset)" : ""
                            let num = tab.agentNumber > 0 ? "\(ansiDim)#\(tab.agentNumber)\(ansiReset) " : ""
                            lines += "    \(num)\(tab.isActive ? "\(ansiBold)\(tab.name)\(ansiReset)" : "\(ansiDim)\(tab.name)\(ansiReset)")\(marker)\(unread)\r\n"
                        }
                    }
                    await TerminalManager.shared.printOutput(lines)
                }
                continue
            }

            // /new — spawn a fresh agent
            if trimmed == "/new" {
                var msg = Pecan_ClientMessage()
                var startTask = Pecan_StartTaskRequest()
                startTask.initialPrompt = "Initialize new session"
                if let p = cliProjectName { startTask.projectName = p }
                if let t = cliTeamName { startTask.teamName = t }
                msg.startTask = startTask
                try await call.requestStream.send(msg)
                continue
            }

            // /fork — clone context+shares from current agent into new one
            if trimmed == "/fork" {
                guard let currentSid = await sessionState.getActiveID() else {
                    await TerminalManager.shared.printSystem("No active session to fork.")
                    continue
                }
                var msg = Pecan_ClientMessage()
                var startTask = Pecan_StartTaskRequest()
                startTask.initialPrompt = "Initialize forked session"
                startTask.forkSessionID = currentSid
                // Inherit project/team from the session being forked
                if let p = await sessionState.getActiveProjectName() {
                    startTask.projectName = p
                }
                if let t = await sessionState.getActiveTeamName() {
                    startTask.teamName = t
                }
                msg.startTask = startTask
                try await call.requestStream.send(msg)
                continue
            }

            // /close — terminate current agent, switch to next or exit
            if trimmed == "/close" {
                guard let sid = await sessionState.getActiveID() else {
                    await TerminalManager.shared.printSystem("No active session to close.")
                    continue
                }
                var msg = Pecan_ClientMessage()
                var input = Pecan_TaskInput()
                input.sessionID = sid
                input.text = "/close"
                msg.userInput = input
                try await call.requestStream.send(msg)
                continue
            }

            // /switch <name> — switch active agent by name
            if trimmed.hasPrefix("/switch ") {
                let name = String(trimmed.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespaces)
                let tabs = await sessionState.agentTabList()
                if let target = tabs.first(where: { $0.name == name }) {
                    await switchToAgent(id: target.id, sessionState: sessionState)
                    await TerminalManager.shared.printSystem("Switched to \(name)")
                } else {
                    let all = tabs.map(\.name).joined(separator: ", ")
                    await TerminalManager.shared.printSystem("No agent named '\(name)'. Available: \(all)")
                }
                continue
            }

            guard let sid = await sessionState.getID() else {
                await TerminalManager.shared.printSystem("Waiting for session ID...")
                continue
            }

            var msg = Pecan_ClientMessage()
            var input = Pecan_TaskInput()
            input.sessionID = sid
            input.text = trimmed
            msg.userInput = input

            await TerminalManager.shared.startThrobber(message: "Working...")
            try await call.requestStream.send(msg)
        }
    }
    
    print("\r\nExiting Pecan UI...\r", terminator: "\n")
    
    // Cleanup
    call.requestStream.finish()
    receiverTask.cancel()
    
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        print("Error: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
