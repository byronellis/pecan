import Foundation
import GRPC
import NIO
import PecanShared
import PecanServerCore
import PecanSettings
import Logging

final class ClientServiceProvider: Pecan_ClientServiceAsyncProvider {
    func streamEvents(
        requestStream: GRPCAsyncRequestStream<Pecan_ClientMessage>,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_ServerMessage>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        logger.info("UI Client connected.")
        var activeSessions: Set<String> = []

        do {
            for try await message in requestStream {
                switch message.payload {
                case .startTask(let startReq):
                    let sessionID = UUID().uuidString
                    activeSessions.insert(sessionID)

                    let agentName = AgentNames.randomName()

                    // Create persistent session store
                    let store: SessionStore
                    do {
                        store = try SessionStore(sessionID: sessionID, name: agentName)
                    } catch {
                        logger.error("Failed to create session store: \(error)")
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sessionID
                        out.text = "System Error: Failed to create session store. (\(error.localizedDescription))"
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                        continue
                    }

                    // Fork: copy context and shares from source session
                    var shareMounts: [MountSpec] = []
                    if !startReq.forkSessionID.isEmpty {
                        if let sourceStore = await SessionManager.shared.getStore(sessionID: startReq.forkSessionID) {
                            // Copy context messages
                            if let contextMessages = try? sourceStore.getContextMessages() {
                                for msg in contextMessages {
                                    try? store.addContextMessage(
                                        section: msg.section,
                                        role: msg.role,
                                        content: msg.content,
                                        metadata: msg.metadataJson
                                    )
                                }
                            }
                            // Copy shares
                            if let shares = try? sourceStore.getShares() {
                                for share in shares {
                                    try? store.addShare(hostPath: share.hostPath, guestPath: share.guestPath, mode: share.mode)
                                }
                                shareMounts = shares.map { MountSpec(source: $0.hostPath, destination: $0.guestPath, readOnly: $0.mode == "ro") }
                            }
                            logger.info("Forked session \(startReq.forkSessionID) -> \(sessionID)")
                        } else {
                            logger.warning("Fork source session \(startReq.forkSessionID) not found, starting fresh")
                        }
                    }

                    await SessionManager.shared.setStore(sessionID: sessionID, store: store)
                    await SessionManager.shared.registerUI(sessionID: sessionID, stream: responseStream)
                    if startReq.persistent {
                        await SessionManager.shared.markPersistent(sessionID)
                    }

                    // Set up team if specified. In the flat model, team IS the project workspace.
                    // --project foo and --team foo are equivalent; project_name is auto-mapped to team_name.
                    var teamName = startReq.teamName.isEmpty ? startReq.projectName : startReq.teamName
                    var projectName = teamName  // project name == team name

                    if !teamName.isEmpty {
                        do {
                            let teamStore = try TeamStore(name: teamName)
                            await SessionManager.shared.setTeamForSession(sessionID: sessionID, teamName: teamName, store: teamStore)

                            // Mount team's project directory if set
                            if let dir = teamStore.projectDirectory {
                                shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
                                await SessionManager.shared.setGitBase(sessionID: sessionID, commit: gitHead(for: dir))
                            }

                            // Team workspace mount
                            shareMounts.append(MountSpec(source: teamStore.workspacePath.path, destination: "/team", readOnly: false))

                            logger.info("Session \(sessionID) joined team '\(teamName)'")
                        } catch {
                            logger.error("Failed to set up team: \(error)")
                        }
                    } else {
                        projectName = ""
                        teamName = ""
                    }

                    // Notify UI that session started
                    var response = Pecan_ServerMessage()
                    var started = Pecan_SessionStarted()
                    started.sessionID = sessionID
                    started.agentName = agentName
                    started.projectName = projectName
                    started.teamName = teamName
                    started.agentNumber = await SessionManager.shared.getAgentNumber(sessionID: sessionID)
                    response.sessionStarted = started
                    try await responseStream.send(response)

                    // Persist session metadata (enables respawn after server restart for persistent sessions)
                    let sessionMeta = SessionMeta(
                        sessionID: sessionID,
                        agentName: agentName,
                        projectName: projectName,
                        teamName: teamName,
                        networkEnabled: false,
                        persistent: startReq.persistent,
                        startedAt: ISO8601DateFormatter().string(from: Date())
                    )
                    sessionMeta.save()
                    await SessionManager.shared.flushRunningIndex()

                    // Spawn the agent using the Pluggable VM architecture
                    let envMountPath = await SessionManager.shared.persistEnvTarPath(sessionID: sessionID) ?? ""
                    do {
                        try await SpawnerFactory.shared.spawn(
                            sessionID: sessionID,
                            agentName: agentName,
                            workspacePath: store.workspacePath.path,
                            shares: shareMounts,
                            envMountPath: envMountPath
                        )
                    } catch {
                        logger.error("Failed to spawn agent: \(error)")
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sessionID
                        out.text = "System Error: Failed to spawn isolated agent VM. (\(error.localizedDescription))"
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                    }

                case .userInput(let req):
                    let text = req.text.trimmingCharacters(in: .whitespaces)

                    // Intercept /share and /unshare commands
                    if text.hasPrefix("/share ") || text.hasPrefix("/unshare ") {
                        do {
                            try await Self.handleShareCommand(sessionID: req.sessionID, text: text)
                        } catch {
                            logger.error("Share command failed: \(error)")
                            var errorMsg = Pecan_ServerMessage()
                            var out = Pecan_AgentOutput()
                            out.sessionID = req.sessionID
                            out.text = "Error: \(error.localizedDescription)"
                            errorMsg.agentOutput = out
                            try await SessionManager.shared.sendToUI(sessionID: req.sessionID, message: errorMsg)
                        }
                    } else if Self.isSlashCommand(text) {
                        do {
                            try await Self.handleSlashCommand(sessionID: req.sessionID, text: text)
                        } catch {
                            logger.error("Slash command failed: \(error)")
                            var errorMsg = Pecan_ServerMessage()
                            var out = Pecan_AgentOutput()
                            out.sessionID = req.sessionID
                            out.text = "Error: \(error.localizedDescription)"
                            errorMsg.agentOutput = out
                            try await SessionManager.shared.sendToUI(sessionID: req.sessionID, message: errorMsg)
                        }
                    } else {
                        let hasAgent = await SessionManager.shared.hasAgent(sessionID: req.sessionID)
                        logger.info("Routing user input to agent for session \(req.sessionID), hasAgent=\(hasAgent)")
                        await SessionManager.shared.setAgentBusy(sessionID: req.sessionID, busy: true)
                        var cmdMsg = Pecan_HostCommand()
                        var processInput = Pecan_ProcessInput()
                        processInput.text = req.text
                        cmdMsg.processInput = processInput
                        try await SessionManager.shared.sendToAgent(sessionID: req.sessionID, command: cmdMsg)
                    }

                case .toolApproval(let req):
                    logger.info("Received tool approval: \(req.approved) for \(req.toolCallID)")
                    await Self.handleToolApproval(req)

                case .listSessions(_):
                    var msg = Pecan_ServerMessage()
                    var list = Pecan_SessionList()
                    list.sessions = await SessionManager.shared.allLiveSessions()
                    msg.sessionList = list
                    try await responseStream.send(msg)

                case .detachSession(let req):
                    let sid = req.sessionID
                    guard activeSessions.contains(sid) else { continue }
                    await SessionManager.shared.markPersistent(sid)
                    // Update meta.json so the server can respawn after restart
                    if var meta = SessionMeta.load(sessionID: sid) {
                        meta.persistent = true
                        meta.save()
                    }
                    await SessionManager.shared.flushRunningIndex()
                    logger.info("Session \(sid) marked persistent via /detach")

                case .reattach(let req):
                    let sid = req.sessionID
                    guard await SessionManager.shared.getStore(sessionID: sid) != nil else {
                        var errorMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = sid
                        out.text = "Session '\(sid)' is not running. It may have been stopped or the server restarted."
                        errorMsg.agentOutput = out
                        try await responseStream.send(errorMsg)
                        continue
                    }
                    activeSessions.insert(sid)
                    await SessionManager.shared.registerUI(sessionID: sid, stream: responseStream)
                    // Tell the TUI about the session so its state is set up correctly
                    var startedMsg = Pecan_ServerMessage()
                    var started = Pecan_SessionStarted()
                    started.sessionID = sid
                    started.agentName = await SessionManager.shared.getAgentName(sessionID: sid) ?? ""
                    started.projectName = await SessionManager.shared.getProjectName(sessionID: sid) ?? ""
                    started.teamName = await SessionManager.shared.getTeamName(sessionID: sid) ?? ""
                    started.agentNumber = await SessionManager.shared.getAgentNumber(sessionID: sid)
                    startedMsg.sessionStarted = started
                    try await responseStream.send(startedMsg)
                    logger.info("UI reattached to session \(sid)")
                    // Lazy-spawn the container in a background task so the message loop
                    // stays responsive while the container boots.
                    let spawnSID = sid
                    Task {
                        do {
                            try await SessionManager.shared.spawnIfNeeded(sessionID: spawnSID)
                        } catch {
                            logger.error("Failed to spawn container for session \(spawnSID): \(error)")
                            var errMsg = Pecan_ServerMessage()
                            var errOut = Pecan_AgentOutput()
                            errOut.sessionID = spawnSID
                            errOut.text = "{\"type\":\"response\",\"text\":\"❌ Failed to start agent container: \(error.localizedDescription)\\n\\nThis session has no live agent. Type /new to start a fresh session.\"}"
                            errMsg.agentOutput = errOut
                            try? await SessionManager.shared.sendToUI(sessionID: spawnSID, message: errMsg)
                        }
                    }

                case nil:
                    break
                }
            }
        } catch {
            logger.error("UI Stream error or disconnected: \(error)")
        }
        
        for sid in activeSessions {
            if await SessionManager.shared.isPersistent(sid) {
                await SessionManager.shared.detachUI(sessionID: sid)
                logger.info("Session \(sid) detached — container remains running.")
            } else {
                await SessionManager.shared.removeSession(sessionID: sid)
            }
        }
        logger.info("UI Client disconnected.")
    }
}

extension ClientServiceProvider {
    /// Parse and execute /share or /unshare commands.
    static func handleShareCommand(sessionID: String, text: String) async throws {
        guard let store = await SessionManager.shared.getStore(sessionID: sessionID) else {
            throw NSError(domain: "ShareCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session"])
        }

        if text.hasPrefix("/unshare ") {
            let hostPath = String(text.dropFirst("/unshare ".count)).trimmingCharacters(in: .whitespaces)
            guard !hostPath.isEmpty else {
                throw NSError(domain: "ShareCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: /unshare <host_path>"])
            }
            try store.removeShare(hostPath: hostPath)
            logger.info("Removed share \(hostPath) for session \(sessionID)")
        } else {
            // /share [-rw] <host_path>[:<guest_path>]
            var args = String(text.dropFirst("/share ".count)).trimmingCharacters(in: .whitespaces)
            var mode = "ro"
            if args.hasPrefix("-rw ") {
                mode = "rw"
                args = String(args.dropFirst("-rw ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !args.isEmpty else {
                throw NSError(domain: "ShareCommand", code: 3, userInfo: [NSLocalizedDescriptionKey: "Usage: /share [-rw] <host_path>[:<guest_path>]"])
            }
            let parts = args.split(separator: ":", maxSplits: 1)
            let hostPath = String(parts[0])
            let guestPath = parts.count > 1 ? String(parts[1]) : hostPath
            try store.addShare(hostPath: hostPath, guestPath: guestPath, mode: mode)
            logger.info("Added share \(hostPath) -> \(guestPath) (\(mode)) for session \(sessionID)")
        }

        // Restart container with updated mounts
        try await SessionManager.shared.restartContainer(sessionID: sessionID)
    }
}

extension ClientServiceProvider {
    /// Parse scope suffix from commands like /task:team or /tasks:project.
    /// Returns (baseCommand, scope) where scope is "" for no suffix.
    /// Parsed representation of a colon-structured command.
    /// E.g., "/t:p:myproject foo" -> base="t", subcmd="p", target="myproject", args="foo"
    /// E.g., "/project:create foo" -> base="project", subcmd="create", target=nil, args="foo"
    /// E.g., "/ts" -> base="ts", subcmd=nil, target=nil, args=nil
    struct ParsedCommand {
        let base: String      // e.g. "t", "task", "ts", "tasks", "p", "project", "team"
        let subcmd: String?   // e.g. "create", "switch", "t", "p"
        let target: String?   // e.g. team name, project name
        let args: String      // remaining arguments after command word
    }

    /// Check if a text string is a slash command we handle (vs something to send to the agent).
    private static func isSlashCommand(_ text: String) -> Bool {
        // Extract the first word, then the base command (before any colon)
        let firstWord = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        guard firstWord.hasPrefix("/") else { return false }
        let commandPart = String(firstWord.dropFirst())
        let base = commandPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? commandPart
        let knownBases: Set<String> = ["task", "tasks", "t", "ts", "project", "projects", "p", "team", "teams", "changeset", "cs", "mergequeue", "mq", "exec", "network", "image", "close", "clear", "compact", "status", "prompt", "number", "settings"]
        return knownBases.contains(base)
    }

    /// Parse a slash command with colon-separated segments and shorthand expansion.
    /// Format: /<base>[:subcmd[:target]] [args...]
    private static func parseCommand(_ text: String) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let wordParts = trimmed.split(separator: " ", maxSplits: 1)
        let commandWord = String(wordParts.first ?? "").dropFirst() // strip leading /
        let args = wordParts.count > 1 ? String(wordParts[1]).trimmingCharacters(in: .whitespaces) : ""

        let segments = commandWord.split(separator: ":", maxSplits: 2).map(String.init)

        // Expand shorthands
        var base = segments[0]
        switch base {
        case "p": base = "project"
        case "t": base = "task"
        case "ts": base = "tasks"
        default: break
        }

        let subcmd = segments.count > 1 ? segments[1] : nil
        let target = segments.count > 2 ? segments[2] : nil

        return ParsedCommand(base: base, subcmd: subcmd, target: target, args: args)
    }

    /// Handle /project (or /p) commands.
    /// In the flat model, /project is an alias for /team — projects and teams are the same concept.
    static func handleProjectCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        switch cmd.subcmd {
        case "create":
            let argParts = cmd.args.split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = argParts.first, !name.isEmpty else {
                try await sendOutput("Usage: /project:create <name> [directory]")
                return
            }
            let directory = argParts.count > 1 ? argParts[1] : nil
            do {
                let _ = try TeamStore(name: name, projectDirectory: directory)
                var msg = "Created team/project '\(name)'."
                if let dir = directory { msg += " Directory: \(dir)" }
                try await sendOutput(msg)
            } catch {
                try await sendOutput("Failed to create team/project: \(error.localizedDescription)")
            }

        case "switch":
            // /project:switch is now an alias for switching teams
            let name = cmd.args.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                try await sendOutput("Usage: /project:switch <name>")
                return
            }
            let available = TeamRegistry.listAllTeamNames()
            guard available.contains(name) else {
                try await sendOutput("Team/project '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available.joined(separator: ", "))")
                return
            }
            if (try? await Self.hasOpenChangeset(sessionID: sessionID)) == true {
                try await sendOutput("Cannot switch: there is an open changeset. Submit (/changeset:submit) or discard (/changeset:discard) it first.")
                return
            }
            do {
                let store = try TeamStore(name: name)
                await SessionManager.shared.setTeamForSession(sessionID: sessionID, teamName: name, store: store)
                logger.info("Restarting container for team switch to '\(name)'...")
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
                try await SessionManager.shared.sendSessionUpdateToUI(sessionID: sessionID)
                try await sendOutput("Switched to team/project '\(name)'. Agent restarted.")
            } catch {
                logger.error("Team switch failed: \(error)")
                try await sendOutput("Failed to switch team/project: \(error.localizedDescription)")
            }

        case "list":
            let names = TeamRegistry.listAllTeamNames()
            if names.isEmpty {
                try await sendOutput("No teams/projects found. Use /project:create <name> [directory] to create one.")
                return
            }
            let currentTeam = await SessionManager.shared.getTeamName(sessionID: sessionID)
            var lines = "**Teams/Projects**\n"
            for name in names {
                let marker = (name == currentTeam) ? " <- active" : ""
                lines += "  \(name)\(marker)\n"
            }
            try await sendOutput(lines)

        case nil:
            let firstWord = cmd.args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if ["create", "switch", "list"].contains(firstWord) {
                try await sendOutput("Did you mean /project:\(firstWord)? Use colon syntax: /p:\(firstWord) \(cmd.args.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces))")
                return
            }

            // /project with no subcommand — show current team/project info
            guard let teamName = await SessionManager.shared.getTeamName(sessionID: sessionID),
                  let store = await SessionManager.shared.getTeamStore(sessionID: sessionID) else {
                try await sendOutput("No team/project assigned. Use /project:switch <name> or --project <name> at startup.")
                return
            }
            var info = "**Project: \(teamName)**\n"
            if let dir = store.projectDirectory {
                info += "  Directory: \(dir)\n"
            }
            info += "  Workspace: \(store.workspacePath.path)\n"
            let taskCount = try store.listTasks().count
            let memCount = try store.listMemories().count
            info += "  Tasks: \(taskCount)  Memories: \(memCount)"
            try await sendOutput(info)

        default:
            try await sendOutput("Unknown project command ':\(cmd.subcmd ?? "")'. Use :create, :switch, :list")
        }
    }

    /// Handle /team commands.
    /// In the flat model, teams are standalone workspaces — no longer nested under projects.
    static func handleTeamCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        switch cmd.subcmd {
        case "create":
            let argParts = cmd.args.split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = argParts.first, !name.isEmpty else {
                try await sendOutput("Usage: /team:create <name> [directory]")
                return
            }
            let directory = argParts.count > 1 ? argParts[1] : nil
            do {
                let _ = try TeamStore(name: name, projectDirectory: directory)
                var msg = "Created team '\(name)'."
                if let dir = directory { msg += " Directory: \(dir)" }
                try await sendOutput(msg)
            } catch {
                try await sendOutput("Failed to create team: \(error.localizedDescription)")
            }

        case "join":
            let name = cmd.args.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                try await sendOutput("Usage: /team:join <name>")
                return
            }
            let available = TeamRegistry.listAllTeamNames()
            guard available.contains(name) else {
                try await sendOutput("Team '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available.joined(separator: ", "))")
                return
            }
            if (try? await Self.hasOpenChangeset(sessionID: sessionID)) == true {
                try await sendOutput("Cannot change teams: there is an open changeset. Submit (/changeset:submit) or discard (/changeset:discard) it first.")
                return
            }
            do {
                let store = try TeamStore(name: name)
                await SessionManager.shared.setTeamForSession(sessionID: sessionID, teamName: name, store: store)
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
                try await SessionManager.shared.sendSessionUpdateToUI(sessionID: sessionID)
                try await sendOutput("Joined team '\(name)'. Agent restarted with team workspace mounted.")
            } catch {
                try await sendOutput("Failed to join team: \(error.localizedDescription)")
            }

        case "leave":
            guard let teamName = await SessionManager.shared.getTeamName(sessionID: sessionID) else {
                try await sendOutput("Not currently in a team.")
                return
            }
            if (try? await Self.hasOpenChangeset(sessionID: sessionID)) == true {
                try await sendOutput("Cannot leave team: there is an open changeset. Submit (/changeset:submit) or discard (/changeset:discard) it first.")
                return
            }
            await SessionManager.shared.clearTeamForSession(sessionID: sessionID)
            do {
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
                try await SessionManager.shared.sendSessionUpdateToUI(sessionID: sessionID)
                try await sendOutput("Left team '\(teamName)'. Agent restarted.")
            } catch {
                try await sendOutput("Left team '\(teamName)' but failed to restart: \(error.localizedDescription)")
            }

        case "list":
            let names = TeamRegistry.listAllTeamNames()
            if names.isEmpty {
                try await sendOutput("No teams found. Use /team:create <name> [directory] to create one.")
                return
            }
            let currentTeam = await SessionManager.shared.getTeamName(sessionID: sessionID)
            var lines = "**Teams**\n"
            for name in names {
                let marker = (name == currentTeam) ? " <- active" : ""
                lines += "  \(name)\(marker)\n"
            }
            try await sendOutput(lines)

        case "set-directory":
            let dir = cmd.args.trimmingCharacters(in: .whitespaces)
            guard !dir.isEmpty else {
                try await sendOutput("Usage: /team:set-directory <path>")
                return
            }
            guard let store = await SessionManager.shared.getTeamStore(sessionID: sessionID) else {
                try await sendOutput("No team assigned. Use /team:join <name> first.")
                return
            }
            do {
                try store.setProjectDirectory(dir)
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
                try await SessionManager.shared.sendSessionUpdateToUI(sessionID: sessionID)
                try await sendOutput("Team directory set to '\(dir)'. Agent restarted.")
            } catch {
                try await sendOutput("Failed to set directory: \(error.localizedDescription)")
            }

        case nil:
            let firstWord = cmd.args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if ["create", "join", "leave", "list", "set-directory"].contains(firstWord) {
                try await sendOutput("Did you mean /team:\(firstWord)? Use colon syntax: /team:\(firstWord) \(cmd.args.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces))")
                return
            }

            // /team with no subcommand — show current team info
            guard let teamName = await SessionManager.shared.getTeamName(sessionID: sessionID),
                  let store = await SessionManager.shared.getTeamStore(sessionID: sessionID) else {
                try await sendOutput("No team assigned. Use /team:join <name> or --team <name> at startup.")
                return
            }
            var info = "**Team: \(teamName)**\n"
            if let dir = store.projectDirectory {
                info += "  Directory: \(dir)\n"
            }
            info += "  Workspace: \(store.workspacePath.path)\n"
            let taskCount = try store.listTasks().count
            let memCount = try store.listMemories().count
            info += "  Tasks: \(taskCount)  Memories: \(memCount)"
            try await sendOutput(info)

        default:
            try await sendOutput("Unknown team command ':\(cmd.subcmd ?? "")'. Use :create, :join, :leave, :list, :set-directory")
        }
    }

    /// Handle /task, /tasks (and shorthands /t, /ts) commands with scope modifiers.
    /// Scope modifiers: :t[:teamName] for team, :p[:projectName] for project
    static func handleTaskCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        let isList = (cmd.base == "tasks")

        // Resolve scope from subcmd: "t"="team", "p"="project", nil=agent
        let scope: String
        let scopeTarget: String?
        if let sub = cmd.subcmd {
            switch sub {
            case "t", "team":
                scope = "team"
                scopeTarget = cmd.target
            case "p", "project":
                scope = "project"
                scopeTarget = cmd.target
            default:
                try await sendOutput("Unknown task scope ':\(sub)'. Use :t (team) or :p (project).")
                return
            }
        } else {
            scope = ""
            scopeTarget = nil
        }

        // Resolve store
        let store: ScopedStore
        if scope.isEmpty {
            guard let s = await SessionManager.shared.getStore(sessionID: sessionID) else {
                throw NSError(domain: "TaskCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session"])
            }
            store = s
        } else if let s = await SessionManager.shared.resolveStore(sessionID: sessionID, scope: scope, target: scopeTarget) {
            store = s
        } else {
            let label = scopeTarget.map { "\(scope) '\($0)'" } ?? scope
            try await sendOutput("No \(label) store available for this session.")
            return
        }

        let scopeLabel = scope.isEmpty ? "" : scopeTarget.map { " [\(scope):\($0)]" } ?? " [\(scope)]"

        // /tasks (list)
        if isList {
            let statusFilter = cmd.args.isEmpty ? nil : cmd.args
            let tasks = try store.listTasks(status: statusFilter, label: nil, search: nil)
            if tasks.isEmpty {
                try await sendOutput("No tasks found\(scopeLabel).")
                return
            }
            var lines = "**Tasks\(scopeLabel)**\n"
            for task in tasks {
                let focusMarker = task.focused == 1 ? " *" : ""
                let priorityStr = "P\(task.priority)"
                lines += "  #\(task.id ?? 0) [\(task.status)] \(priorityStr) \(task.title)\(focusMarker)\n"
            }
            try await sendOutput(lines)
            return
        }

        // /task with no args — show usage
        if cmd.args.isEmpty {
            try await sendOutput("Usage: /t <text> to create, /t #<id> to view, /ts to list")
            return
        }

        let rest = cmd.args

        // /task #<id> ...
        if rest.hasPrefix("#") {
            let parts = rest.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            guard let idStr = parts.first, let taskID = Int64(idStr) else {
                try await sendOutput("Invalid task ID.")
                return
            }

            if parts.count == 1 {
                guard let task = try store.getTask(id: taskID) else {
                    try await sendOutput("Task #\(taskID) not found\(scopeLabel).")
                    return
                }
                let focusStr = task.focused == 1 ? " * focused" : ""
                var detail = "**Task #\(task.id ?? 0)**: \(task.title)\(focusStr)\(scopeLabel)\n"
                detail += "  Status: \(task.status)  Priority: \(task.priority)  Severity: \(task.severity)\n"
                if !task.labels.isEmpty { detail += "  Labels: \(task.labels)\n" }
                if !task.dueDate.isEmpty { detail += "  Due: \(task.dueDate)\n" }
                if !task.dependsOn.isEmpty { detail += "  Depends: \(task.dependsOn)\n" }
                if !task.description.isEmpty { detail += "  Description: \(task.description)\n" }
                detail += "  Created: \(task.createdAt)  Updated: \(task.updatedAt)"
                try await sendOutput(detail)
                return
            }

            // /task #<id> <field> <value>
            let fieldAndValue = parts[1]
            let fieldParts = fieldAndValue.split(separator: " ", maxSplits: 1).map(String.init)
            let field = fieldParts[0].lowercased()

            if field == "focus" {
                try store.setFocused(taskID: taskID)
                if scope.isEmpty {
                    let focused = try store.getFocusedTask()
                    try await SessionManager.shared.sendTaskUpdateToUI(sessionID: sessionID, focusedTitle: focused?.title ?? "")
                }
                try await sendOutput("Task #\(taskID) is now focused\(scopeLabel).")
                return
            }

            guard fieldParts.count > 1 else {
                try await sendOutput("Missing value for field '\(field)'.")
                return
            }

            let value = fieldParts[1]
            var fields: [String: Any] = [:]
            switch field {
            case "priority":
                guard let p = Int(value), (1...5).contains(p) else {
                    try await sendOutput("Priority must be 1-5.")
                    return
                }
                fields["priority"] = p
            case "severity":
                let valid = ["low", "normal", "high", "critical"]
                guard valid.contains(value.lowercased()) else {
                    try await sendOutput("Severity must be: \(valid.joined(separator: ", "))")
                    return
                }
                fields["severity"] = value.lowercased()
            case "status":
                let valid = ["todo", "implementing", "testing", "preparing", "done", "blocked"]
                guard valid.contains(value.lowercased()) else {
                    try await sendOutput("Status must be: \(valid.joined(separator: ", "))")
                    return
                }
                fields["status"] = value.lowercased()
            case "label", "labels":
                fields["labels"] = value
            case "due":
                fields["due_date"] = value
            case "depends":
                fields["depends_on"] = value
            case "description":
                fields["description"] = value
            default:
                try await sendOutput("Unknown field '\(field)'. Use: priority, severity, status, label, due, depends, description, focus")
                return
            }

            let updated = try store.updateTask(id: taskID, fields: fields)
            try await sendOutput("Updated task #\(updated.id ?? 0)\(scopeLabel): \(field) -> \(value)")
            return
        }

        // /task <text> — create task
        let task = try store.createTask(title: rest, description: "", priority: 3, severity: "normal", labels: "", dueDate: "", dependsOn: "")
        try await sendOutput("Created task #\(task.id ?? 0)\(scopeLabel): \(task.title)")
    }

    /// Main entry point for all slash commands routed from the UI input handler.
    static func handleSlashCommand(sessionID: String, text: String) async throws {
        let cmd = parseCommand(text)

        func sendOutput(_ msg: String) async throws {
            var srvMsg = Pecan_ServerMessage()
            var out = Pecan_AgentOutput()
            out.sessionID = sessionID
            out.text = msg
            srvMsg.agentOutput = out
            try await SessionManager.shared.sendToUI(sessionID: sessionID, message: srvMsg)
        }

        switch cmd.base {
        case "project", "projects":
            // /projects is shorthand for /project:list
            let effective = cmd.base == "projects" ? ParsedCommand(base: "project", subcmd: "list", target: nil, args: cmd.args) : cmd
            try await handleProjectCommand(sessionID: sessionID, cmd: effective, sendOutput: sendOutput)
        case "team", "teams":
            let effective = cmd.base == "teams" ? ParsedCommand(base: "team", subcmd: "list", target: nil, args: cmd.args) : cmd
            try await handleTeamCommand(sessionID: sessionID, cmd: effective, sendOutput: sendOutput)
        case "task", "tasks":
            try await handleTaskCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        case "changeset", "cs":
            try await handleChangesetCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        case "mergequeue", "mq":
            try await handleMergeQueueCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        case "exec":
            let command = cmd.args.isEmpty ? (cmd.subcmd ?? "") : (cmd.subcmd.map { "\($0) \(cmd.args)" } ?? cmd.args)
            guard !command.isEmpty else {
                try await sendOutput("Usage: /exec <shell command>")
                return
            }
            var hostCmd = Pecan_HostCommand()
            var execCmd = Pecan_ExecCommand()
            execCmd.requestID = UUID().uuidString
            execCmd.command = command
            hostCmd.execCommand = execCmd
            try await SessionManager.shared.sendToAgent(sessionID: sessionID, command: hostCmd)
        case "network":
            try await handleNetworkCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        case "image":
            try await handleImageCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        case "close":
            // Send notification first so UI can remove the session before we tear it down
            var srvMsg = Pecan_ServerMessage()
            var out = Pecan_AgentOutput()
            out.sessionID = sessionID
            out.text = "{\"type\":\"session_closed\"}"
            srvMsg.agentOutput = out
            try await SessionManager.shared.sendToUI(sessionID: sessionID, message: srvMsg)
            await SessionManager.shared.removeSession(sessionID: sessionID)
        case "clear":
            await SessionManager.shared.compactContext(sessionID: sessionID, section: .conversation, keepRecent: 0)
            var srvMsg = Pecan_ServerMessage()
            var out = Pecan_AgentOutput()
            out.sessionID = sessionID
            out.text = "{\"type\":\"response\",\"text\":\"Context cleared.\"}"
            srvMsg.agentOutput = out
            try await SessionManager.shared.sendToUI(sessionID: sessionID, message: srvMsg)
        case "compact":
            guard await SessionManager.shared.hasAgent(sessionID: sessionID) else {
                try await sendOutput("No active agent — cannot compact context.")
                return
            }
            let contextData = try await SessionManager.shared.getContext(sessionID: sessionID)
            let contextJSON = String(data: contextData, encoding: .utf8) ?? "[]"
            await SessionManager.shared.setAgentBusy(sessionID: sessionID, busy: true)
            var cmdMsg = Pecan_HostCommand()
            var processInput = Pecan_ProcessInput()
            processInput.text = "\u{02}compact\n\(contextJSON)"
            cmdMsg.processInput = processInput
            try await SessionManager.shared.sendToAgent(sessionID: sessionID, command: cmdMsg)
            try await sendOutput("Compacting context with subagent...")
        case "number":
            let arg = cmd.args.isEmpty ? (cmd.subcmd ?? "") : cmd.args
            guard let n = Int32(arg.trimmingCharacters(in: .whitespaces)), n >= 1 else {
                try await sendOutput("Usage: /number <n>  — assign this agent a stable display number (e.g. /number 2)")
                return
            }
            await SessionManager.shared.renumberSession(sessionID: sessionID, newNumber: n)
            try await sendOutput("Agent number set to \(n).")
            try await SessionManager.shared.broadcastSessionList()
        case "status":
            try await sendOutput(await buildStatusOutput(sessionID: sessionID))
        case "prompt":
            try await sendOutput(await buildPromptOutput(sessionID: sessionID))
        case "settings":
            try await handleSettingsCommand(sessionID: sessionID, cmd: cmd, sendOutput: sendOutput)
        default:
            try await sendOutput("Unknown command '/\(cmd.base)'.")
        }
    }

    static func handleNetworkCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        let current = await SessionManager.shared.isNetworkEnabled(sessionID: sessionID)
        switch cmd.subcmd {
        case nil, "status":
            try await sendOutput("Network: \(current ? "enabled" : "disabled")\r\nUse /network:on or /network:off to change (saves image snapshot and restarts container).")
        case "on":
            if current {
                try await sendOutput("Network is already enabled.")
            } else {
                try await saveEnvSnapshot(sessionID: sessionID, sendOutput: sendOutput)
                await SessionManager.shared.setNetworkEnabled(sessionID: sessionID, enabled: true)
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
            }
        case "off":
            if !current {
                try await sendOutput("Network is already disabled.")
            } else {
                try await saveEnvSnapshot(sessionID: sessionID, sendOutput: sendOutput)
                await SessionManager.shared.setNetworkEnabled(sessionID: sessionID, enabled: false)
                try await SessionManager.shared.restartContainer(sessionID: sessionID)
            }
        default:
            try await sendOutput("Usage: /network[:on|:off]")
        }
    }

    static func handleImageCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        switch cmd.subcmd {
        case nil, "status":
            if let tarPath = await SessionManager.shared.persistEnvTarPath(sessionID: sessionID),
               FileManager.default.fileExists(atPath: tarPath) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: tarPath)
                let size = attrs?[.size] as? Int64 ?? 0
                let date = (attrs?[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                let mb = Double(size) / 1_048_576
                try await sendOutput(String(format: "Image snapshot: %.1f MB, saved %@\r\nUse /image:discard to remove.", mb, date))
            } else {
                try await sendOutput("No image snapshot saved.\r\nUse /image:save to capture the current container state.")
            }
        case "save":
            try await saveEnvSnapshot(sessionID: sessionID, sendOutput: sendOutput)
        case "discard":
            if let tarPath = await SessionManager.shared.persistEnvTarPath(sessionID: sessionID) {
                try? FileManager.default.removeItem(atPath: tarPath)
                try await sendOutput("Image snapshot discarded. Next restart will use clean alpine:3.19.")
            } else {
                try await sendOutput("No image snapshot to discard.")
            }
        default:
            try await sendOutput("Usage: /image[:save|:discard]")
        }
    }

    /// Saves the current container's environment snapshot. Shared by /image:save and network toggle.
    private static func saveEnvSnapshot(sessionID: String, sendOutput: (String) async throws -> Void) async throws {
        guard let tarPath = await SessionManager.shared.persistEnvTarPath(sessionID: sessionID) else {
            try await sendOutput("No session store — cannot save snapshot.")
            return
        }
        try await sendOutput("Saving environment snapshot...")
        try await SpawnerFactory.shared.saveEnvironment(sessionID: sessionID, outputPath: tarPath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: tarPath)
        let size = attrs?[.size] as? Int64 ?? 0
        let mb = Double(size) / 1_048_576
        try await sendOutput(String(format: "Snapshot saved (%.1f MB).", mb))
    }

    static func handleChangesetCommand(sessionID: String, cmd: ParsedCommand, sendOutput: @escaping (String) async throws -> Void) async throws {
        guard let projectStore = await SessionManager.shared.getProjectStore(sessionID: sessionID),
              projectStore.directory != nil else {
            try await sendOutput("No project mounted for this session.")
            return
        }

        // Parse any trailing args as glob patterns
        let patterns = cmd.args.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        switch cmd.subcmd {
        case "diff", nil:
            let resp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "diff", patterns: patterns)
            if resp.content.isEmpty {
                let scope = patterns.isEmpty ? "overlay" : "'\(patterns.joined(separator: " "))'"
                try await sendOutput("No changes in \(scope).")
                return
            }
            var out = ""
            for line in resp.content.components(separatedBy: "\n") {
                if line.hasPrefix("+++") || line.hasPrefix("---") {
                    out += "\u{1b}[1m\(line)\u{1b}[0m\r\n"
                } else if line.hasPrefix("@@") {
                    out += "\u{1b}[36m\(line)\u{1b}[0m\r\n"
                } else if line.hasPrefix("+") {
                    out += "\u{1b}[32m\(line)\u{1b}[0m\r\n"
                } else if line.hasPrefix("-") {
                    out += "\u{1b}[31m\(line)\u{1b}[0m\r\n"
                } else {
                    out += "\(line)\r\n"
                }
            }
            try await sendOutput(out)

        case "status":
            let resp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "list", patterns: patterns)
            let changes = parseChangeList(resp.content)
            let added    = changes.filter { $0.type == "added" }.count
            let modified = changes.filter { $0.type == "modified" }.count
            let deleted  = changes.filter { $0.type == "deleted" }.count
            let total = added + modified + deleted
            if total == 0 {
                let scope = patterns.isEmpty ? "overlay" : "'\(patterns.joined(separator: " "))'"
                try await sendOutput("No changes in \(scope).")
                return
            }
            var out = "\u{1b}[1mChangeset\u{1b}[0m  \u{1b}[32m+\(added)\u{1b}[0m \u{1b}[33m~\(modified)\u{1b}[0m \u{1b}[31m-\(deleted)\u{1b}[0m\r\n\r\n"
            for c in changes {
                switch c.type {
                case "added":    out += "  \u{1b}[32m+ \(c.path)\u{1b}[0m\r\n"
                case "modified": out += "  \u{1b}[33m~ \(c.path)\u{1b}[0m\r\n"
                case "deleted":  out += "  \u{1b}[31m- \(c.path)\u{1b}[0m\r\n"
                default:         out += "  \(c.path)\r\n"
                }
            }
            try await sendOutput(out)

        case "discard":
            let listResp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "list", patterns: patterns)
            let count = parseChangeList(listResp.content).count
            guard count > 0 else {
                let scope = patterns.isEmpty ? "overlay" : "'\(patterns.joined(separator: " "))'"
                try await sendOutput("No changes in \(scope).")
                return
            }
            _ = try await ChangesetClient.shared.request(sessionID: sessionID, action: "discard", patterns: patterns)
            let scope = patterns.isEmpty ? "Overlay is now clean." : "\(count) matching change(s) discarded."
            try await sendOutput("Discarded \(count) change(s). \(scope)")

        case "submit":
            guard !(await SessionManager.shared.isMerging(sessionID: sessionID)) else {
                try await sendOutput("A merge is already in progress for this session.")
                return
            }
            let listResp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "list")
            let changes = parseChangeList(listResp.content)
            guard !changes.isEmpty else {
                try await sendOutput("Nothing to submit — overlay is clean.")
                return
            }
            let note = cmd.args.isEmpty ? "" : cmd.args
            let store = await SessionManager.shared.getStore(sessionID: sessionID)
            let agentName = (try? store?.name) ?? sessionID
            let projectName = (try? projectStore.name) ?? ""
            guard let projectDir = projectStore.directory else {
                try await sendOutput("Project has no directory configured — cannot merge.")
                return
            }

            let mergeID = UUID().uuidString
            _ = try await MergeQueueStore.shared.begin(
                mergeID: mergeID, sessionID: sessionID,
                agentName: agentName, projectName: projectName, note: note)
            await SessionManager.shared.setMerging(sessionID: sessionID, mergeID: mergeID)
            try await SessionManager.shared.sendSessionUpdateToUI(sessionID: sessionID, mergeStatus: "merging")
            try await sendOutput("Merging \(changes.count) change(s) into project '\(projectName)'...")

            let gitBase = await SessionManager.shared.gitBase(sessionID: sessionID)
            let capturedSessionID = sessionID
            Task.detached {
                await MergeEngine.run(
                    sessionID: capturedSessionID,
                    mergeID: mergeID,
                    projectDir: projectDir,
                    gitBase: gitBase,
                    sendOutput: { msg in
                        var srvMsg = Pecan_ServerMessage()
                        var out = Pecan_AgentOutput()
                        out.sessionID = capturedSessionID
                        out.text = msg
                        srvMsg.agentOutput = out
                        try await SessionManager.shared.sendToUI(sessionID: capturedSessionID, message: srvMsg)
                    }
                )
            }

        default:
            try await sendOutput("""
                Usage:
                  /changeset [patterns]              Unified diff (optional glob filters)
                  /changeset:diff [patterns]         Same as above
                  /changeset:status [patterns]       List changed files with counts
                  /changeset:discard [patterns]      Discard matching changes (all if no pattern)
                  /changeset:submit [note]           Submit to merge queue for review
                Examples:
                  /changeset:diff *.swift            Diff only Swift files
                  /changeset:status src/**           Status of src/ subtree
                  /changeset:discard README.md       Revert a single file
                """)
        }
    }

    /// Returns true if the session has an active agent with a non-empty overlay changeset.
    static func hasOpenChangeset(sessionID: String) async throws -> Bool {
        guard await SessionManager.shared.getProjectStore(sessionID: sessionID)?.directory != nil else {
            return false
        }
        guard await SessionManager.shared.hasAgent(sessionID: sessionID) else {
            return false
        }
        let resp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "list")
        return !parseChangeList(resp.content).isEmpty
    }

    private struct ChangeEntry {
        let path: String
        let type: String
    }

    private static func parseChangeList(_ json: String) -> [ChangeEntry] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let path = dict["path"], let type = dict["type"] else { return nil }
            return ChangeEntry(path: path, type: type)
        }
    }

    static func handleMergeQueueCommand(sessionID: String, cmd: ParsedCommand, sendOutput: (String) async throws -> Void) async throws {
        switch cmd.subcmd {
        case nil, "list":
            let statusFilter = cmd.args.isEmpty ? nil : cmd.args
            let entries = try await MergeQueueStore.shared.list(status: statusFilter)
            if entries.isEmpty {
                try await sendOutput("Merge history is empty\(statusFilter.map { " (status: \($0))" } ?? "").")
                return
            }
            var out = "\u{1b}[1mMerge History\u{1b}[0m\r\n\r\n"
            for e in entries {
                let statusColor: String
                switch e.status {
                case "merging":  statusColor = "\u{1b}[33m"
                case "merged":   statusColor = "\u{1b}[32m"
                case "failed":   statusColor = "\u{1b}[31m"
                default:         statusColor = "\u{1b}[0m"
                }
                let project = e.projectName.isEmpty ? "" : " [\(e.projectName)]"
                let note = e.note.isEmpty ? "" : " — \(e.note)"
                out += "  \(statusColor)\(e.status)\u{1b}[0m  \(e.agentName)\(project)\(note)\r\n"
                out += "       submitted \(e.submittedAt)"
                if let resolved = e.resolvedAt { out += "  resolved \(resolved)" }
                if !e.resultMessage.isEmpty { out += "\r\n       \(e.resultMessage)" }
                out += "\r\n"
            }
            try await sendOutput(out)

        default:
            try await sendOutput("""
                Usage:
                  /mergequeue           List merge history
                  /mq                   Same
                  /mq:list [status]     Filter by status (merging/merged/failed)
                """)
        }
    }
}

// MARK: - /settings command

extension ClientServiceProvider {
    static func handleSettingsCommand(
        sessionID: String,
        cmd: ParsedCommand,
        sendOutput: (String) async throws -> Void
    ) async throws {
        let allProviders = (try? await SettingsStore.shared.allProviders()) ?? []
        let cachedModels = await ModelCache.shared.models(providers: allProviders)

        switch cmd.subcmd {
        case nil:
            // Show current effective settings
            let globalDefault = (try? await SettingsStore.shared.globalDefault()) ?? "(none)"
            let sessionOverride = await SessionManager.shared.getModelOverride(sessionID: sessionID)
            let personaModels = (try? await SettingsStore.shared.allPersonaModels()) ?? []

            var out = "**Settings**\n\n"
            out += "**Providers**\n"
            if allProviders.isEmpty {
                out += "  (none configured — run `pecan configure`)\n"
            } else {
                for p in allProviders {
                    let status = p.enabled ? "✓" : "✗"
                    out += "  \(status) \(p.id)  [\(p.type)]"
                    if let url = p.url { out += "  \(url)" }
                    out += "\n"
                }
            }
            out += "\n**Model defaults**\n"
            out += "  Global default:   \(globalDefault)\n"
            if let override = sessionOverride {
                out += "  Session override: \(override)\n"
            }
            if !personaModels.isEmpty {
                out += "\n**Persona model assignments**\n"
                for (persona, modelKey) in personaModels {
                    out += "  \(persona): \(modelKey)\n"
                }
            }
            out += "\nUse `/settings:models` to list available models, `/settings:model <key>` to set default."
            try await sendOutput(out)

        case "models":
            // List discovered models with context window info
            let refreshed: [CachedModelInfo]
            if cmd.args.trimmingCharacters(in: .whitespaces) == "--refresh" {
                await ModelCache.shared.invalidate()
                refreshed = await ModelCache.shared.models(providers: allProviders, force: true)
            } else {
                refreshed = cachedModels
            }
            if refreshed.isEmpty {
                try await sendOutput("No models discovered. Check provider configuration with `/settings`.\nAdd `--refresh` to force a re-fetch.")
            } else {
                var out = "**Available models**\n\n"
                var lastProvider = ""
                for m in refreshed.sorted(by: { $0.key < $1.key }) {
                    if m.providerID != lastProvider {
                        out += "\n**\(m.providerID)**\n"
                        lastProvider = m.providerID
                    }
                    let ctx = m.contextWindow.map { "  ctx:\($0 / 1024)k" } ?? ""
                    out += "  \(m.key)\(ctx)\n"
                }
                try await sendOutput(out)
            }

        case "model":
            let target = cmd.target  // e.g. "persona", "agent", or nil
            let arg = cmd.args.trimmingCharacters(in: .whitespaces)

            switch target {
            case nil:
                // /settings:model <key> — set global default
                guard !arg.isEmpty else {
                    let current = (try? await SettingsStore.shared.globalDefault()) ?? "(none)"
                    try await sendOutput("Current global default model: \(current)\nUsage: /settings:model <key>")
                    return
                }
                try await SettingsStore.shared.setGlobalDefault(arg)
                try await sendOutput("Global default model set to '\(arg)'.")

            case "agent":
                // /settings:model:agent <key|clear> — session override
                if arg == "clear" || arg.isEmpty {
                    await SessionManager.shared.setModelOverride(sessionID: sessionID, modelKey: nil)
                    try await sendOutput("Session model override cleared.")
                } else {
                    await SessionManager.shared.setModelOverride(sessionID: sessionID, modelKey: arg)
                    try await sendOutput("Session model override set to '\(arg)' (this session only).")
                }

            case let personaTarget where personaTarget != nil:
                // /settings:model:persona:<name> <key|clear>
                let personaName = personaTarget!
                if arg == "clear" || arg.isEmpty {
                    try await SettingsStore.shared.clearPersonaModel(for: personaName)
                    try await sendOutput("Model preference cleared for persona '\(personaName)'.")
                } else {
                    try await SettingsStore.shared.setPersonaModel(arg, for: personaName)
                    try await sendOutput("Persona '\(personaName)' will use model '\(arg)'.")
                }

            default:
                try await sendOutput("Usage:\n  /settings:model <key>                — set global default\n  /settings:model:agent <key|clear>    — this session only\n  /settings:model:persona:<name> <key|clear>  — per persona")
            }

        default:
            try await sendOutput("Usage:\n  /settings              — show current settings\n  /settings:models       — list available models\n  /settings:model <key>  — set global default model")
        }
    }
}

// MARK: - /status and /prompt builders

extension ClientServiceProvider {
    private static func buildStatusOutput(sessionID: String) async -> String {
        let meta = await SessionManager.shared.getSessionMeta(sessionID: sessionID)
        let (promptTokens, contextWindow) = await SessionManager.shared.getTokenUsage(sessionID: sessionID)
        let stats = await SessionManager.shared.getContextStats(sessionID: sessionID)
        let isBusy = await SessionManager.shared.isAgentBusy(sessionID: sessionID)

        var out = "**Session Status**\n\n"

        out += "  Name:    \(meta.agentName)\n"
        let shortID = String(sessionID.prefix(8))
        out += "  ID:      \(shortID)...\n"
        out += "  Agent:   \(isBusy ? "busy" : "idle")\n"
        out += "  Network: \(meta.networkEnabled ? "enabled" : "disabled")"
        if meta.persistent { out += "  Persistent: yes" }
        out += "\n"
        if let team = meta.teamName {
            out += "  Team:    \(team)\n"
        }
        if let dir = meta.projectDir {
            out += "  Project: \(dir)\n"
        }
        if !meta.lastModelKey.isEmpty {
            out += "  Model:   \(meta.lastModelKey)\n"
        }

        out += "\n**Context**\n\n"

        if contextWindow > 0 && promptTokens > 0 {
            let pct = Double(promptTokens) / Double(contextWindow) * 100.0
            let filled = min(30, Int(pct * 30.0 / 100.0))
            let empty = 30 - filled
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
            out += "  [\(bar)] \(String(format: "%.1f", pct))%\n"
            out += "  \(formatInt(promptTokens)) / \(formatInt(contextWindow)) tokens used\n"
        } else if promptTokens > 0 {
            out += "  \(formatInt(promptTokens)) tokens used (context window unknown)\n"
        } else {
            out += "  (no completion yet this session)\n"
        }

        out += "\n"

        let sectionNames = [0: "System", 1: "Conversation", 2: "Tool calls"]
        let orderedSections = [0, 1, 2]
        let colW = 14

        out += "  \("Section".padding(toLength: colW, withPad: " ", startingAt: 0))  Msgs    Chars    ~Tokens\n"
        out += "  \(String(repeating: "─", count: colW + 29))\n"

        var totalMsgs = 0, totalChars = 0
        for sec in orderedSections {
            let s = stats.sections[sec] ?? SessionManager.ContextSectionStats()
            if s.messageCount == 0 { continue }
            let name = sectionNames[sec] ?? "Section \(sec)"
            let estTokens = s.characterCount / 4
            out += "  \(name.padding(toLength: colW, withPad: " ", startingAt: 0))"
            out += "  \(String(s.messageCount).leftPad(4))"
            out += "  \(formatInt(s.characterCount).leftPad(8))"
            out += "  \(formatInt(estTokens).leftPad(8))\n"
            totalMsgs += s.messageCount
            totalChars += s.characterCount
        }
        out += "  \(String(repeating: "─", count: colW + 29))\n"
        out += "  \("Total".padding(toLength: colW, withPad: " ", startingAt: 0))"
        out += "  \(String(totalMsgs).leftPad(4))"
        out += "  \(formatInt(totalChars).leftPad(8))"
        out += "  \(formatInt(totalChars / 4).leftPad(8))\n"

        if contextWindow == 0 {
            out += "\n  (Set context_window in config to enable token budget display)"
        }

        return out
    }

    private static func buildPromptOutput(sessionID: String) async -> String {
        let messages = await SessionManager.shared.getSystemMessages(sessionID: sessionID)
        guard !messages.isEmpty else {
            return "No system prompt stored for this session yet.\n(The agent writes it on first connect.)"
        }
        var out = "**System Prompt** (\(messages.count) message\(messages.count == 1 ? "" : "s"))\n"
        for (i, msg) in messages.enumerated() {
            out += "\n\(String(repeating: "─", count: 60))\n"
            out += "[\(msg.role)]\n\n"
            out += msg.content
            if i < messages.count - 1 { out += "\n" }
        }
        return out
    }

    private static func formatInt(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        let s = self
        if s.count >= width { return s }
        return String(repeating: " ", count: width - s.count) + s
    }
}

// MARK: - HTTP Proxy Manager

actor HttpProxyManager {
    static let shared = HttpProxyManager()

    struct PendingRequest {
        let sessionID: String
        let request: Pecan_HttpProxyRequest
        let responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>
    }

    private var pending: [String: PendingRequest] = [:]

    func storePending(
        requestID: String,
        sessionID: String,
        request: Pecan_HttpProxyRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Pecan_HostCommand>
    ) {
        pending[requestID] = PendingRequest(sessionID: sessionID, request: request, responseStream: responseStream)
    }

    func removePending(requestID: String) -> PendingRequest? {
        pending.removeValue(forKey: requestID)
    }
}
