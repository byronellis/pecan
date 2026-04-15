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


func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan UI...\r")
        exit(0)
    }

    // Parse CLI arguments
    var cliProjectName: String? = nil
    var cliTeamName: String? = nil
    var cliPersistent: Bool = false
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
            default: break
            }
            i += 1
        }
    }

    // Load config just to verify we can parse ~/.pecan/config.yaml
    do {
        let config = try Config.load()
        print("Loaded config. Default model: \(config.defaultModel ?? config.models.first?.key ?? "unknown")\r", terminator: "\n")
    } catch {
        // Suppress warning if not setup yet
    }
    
    // Discover server port from status file
    let serverPort: Int
    do {
        let status = try ServerStatus.read()
        guard status.isAlive else {
            print("Error: server status file found but process \(status.pid) is not running. Start the server first.\r", terminator: "\n")
            exit(1)
        }
        serverPort = status.port
    } catch {
        print("Error: could not read server status file (.run/server.json): \(error)\r", terminator: "\n")
        print("Make sure the server is running (./dev_start.sh).\r", terminator: "\n")
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

        func deliver(_ sessions: [Pecan_SessionInfo]) {
            guard !delivered else { return }
            delivered = true
            result = sessions
            cont?.resume(returning: sessions)
            cont = nil
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
                    await sessionState.addSession(id: started.sessionID, name: name, projectName: started.projectName, teamName: started.teamName)
                    let agents = await sessionState.agentList()
                    await TerminalManager.shared.updateAgents(agents)
                    // Update breadcrumb with project/team
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
                    await sessionListWaiter.deliver(list.sessions)

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
        for (i, s) in liveSessions.enumerated() {
            var label = "  \(i + 1).  \(s.agentName)"
            if !s.projectName.isEmpty { label += "  [\(s.projectName)]" }
            label += s.isBusy ? "  · busy" : "  · idle"
            if !s.startedAt.isEmpty { label += "  · \(relativeAge(s.startedAt))" }
            await TerminalManager.shared.printSystem(label)
        }
        await TerminalManager.shared.printSystem("")
        await TerminalManager.shared.printSystem("Enter a number to reattach, or press Enter to start a new agent:")

        let choice = await readInputLine(sessionState: sessionState)
        let trimmedChoice = choice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let idx = Int(trimmedChoice), idx >= 1, idx <= liveSessions.count {
            let target = liveSessions[idx - 1]
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
                """
                await TerminalManager.shared.printOutput(help)
                continue
            }

            // /agents — list all agents
            if trimmed == "/agents" {
                let agents = await sessionState.agentList()
                if agents.isEmpty {
                    await TerminalManager.shared.printSystem("No agents.")
                } else {
                    var lines = "\(ansiBold)Agents\(ansiReset)\r\n"
                    for agent in agents {
                        let marker = agent.isActive ? "\(ansiCyan) ← active\(ansiReset)" : ""
                        lines += "  \(agent.isActive ? "\(ansiBold)\(agent.name)\(ansiReset)" : "\(ansiDim)\(agent.name)\(ansiReset)")\(marker)\r\n"
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

            // /switch <name> — switch active tab by agent name
            if trimmed.hasPrefix("/switch ") {
                let name = String(trimmed.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespaces)
                if await sessionState.setActiveByName(name) {
                    let agents = await sessionState.agentList()
                    await TerminalManager.shared.updateAgents(agents)
                    // Update breadcrumbs to reflect the switched-to session's project/team
                    let projectDisplay = await sessionState.getActiveProjectName()
                    let teamDisplay = await sessionState.getActiveTeamName()
                    await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    let focusedTask = await sessionState.getActiveFocusedTask()
                    await TerminalManager.shared.updateFocusedTask(focusedTask)
                    await TerminalManager.shared.printSystem("Switched to \(name)")
                    // Replay any buffered output from while this agent was in the background
                    if let sid = await sessionState.getActiveID() {
                        let buffered = await sessionState.drainBuffer(sid)
                        if !buffered.isEmpty {
                            await TerminalManager.shared.printSystem("--- buffered output ---")
                            for rawText in buffered {
                                if let rendered = renderAgentOutput(rawText) {
                                    await TerminalManager.shared.printOutput(rendered)
                                }
                            }
                            await TerminalManager.shared.printSystem("--- end buffered output ---")
                        }
                    }
                } else {
                    let all = await sessionState.allSessions().map(\.name).joined(separator: ", ")
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
