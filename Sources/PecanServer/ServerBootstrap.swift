import Foundation
import PecanShared
import PecanServerCore
import Logging

/// Ensure built-in skill directories exist under skillsDir.
/// Only creates SKILL.md and scripts if not already present (preserves user customizations).
func ensureBuiltinSkills(skillsDir: String) {
    let fm = FileManager.default

    struct BuiltinSkill {
        let dir: String
        let skillMD: String
        let scripts: [(name: String, content: String)]
    }

    let builtins: [BuiltinSkill] = [
        BuiltinSkill(
            dir: "web",
            skillMD: """
            ---
            name: web
            description: Make HTTP requests with custom methods, headers, and bodies.
            ---

            ## Web Tools

            Use `http_request` to make POST, PUT, PATCH, or DELETE requests.

            ### http_request
            Make an HTTP request with a custom method, headers, and body.

            Usage: `http_request '{"url":"https://...","method":"POST","headers":{"Content-Type":"application/json"},"body":"..."}'`
            """,
            scripts: [("http_request", "#!/bin/sh\npecan-agent invoke http_request \"$@\"\n")]
        ),
        BuiltinSkill(
            dir: "dev",
            skillMD: """
            ---
            name: dev
            description: Developer tools for creating and registering custom Lua tools at runtime.
            ---

            ## Developer Tools

            Use `create_lua_tool` to define new persistent tools using Lua module scripts.

            ### create_lua_tool
            Create a new Lua tool and register it for the current session.

            Usage: `create_lua_tool '{"name":"my_tool","description":"...","script":"return { name=\\"my_tool\\", execute=function(args) ... end }"}'`
            """,
            scripts: [("create_lua_tool", "#!/bin/sh\npecan-agent invoke create_lua_tool \"$@\"\n")]
        ),
        BuiltinSkill(
            dir: "tasks",
            skillMD: """
            ---
            name: tasks
            description: Create and manage tasks to track work across agent, team, and project scopes.
            ---

            ## Task Management

            Tasks track work items with title, status, priority, severity, labels, and due date.
            Scopes: `agent` (default, private), `team` (shared within team), `project` (shared across project).
            Statuses: `todo`, `implementing`, `testing`, `preparing`, `done`, `blocked`.
            Priority: 1 (critical) to 5 (low). Default 3.

            ### Create a task
            ```
            task_create '{"title":"Fix the bug","priority":2,"scope":"agent"}'
            task_create '{"title":"Deploy feature","description":"...","labels":"backend,deploy","scope":"project"}'
            ```

            ### List tasks
            ```
            task_list '{}'                              # all tasks across all scopes
            task_list '{"status":"todo"}'               # filter by status
            task_list '{"scope":"project"}'             # project-scoped only
            task_list '{"label":"backend","status":"implementing"}'
            ```

            ### Get a task
            ```
            task_get '{"task_id":42}'
            ```

            ### Update a task
            ```
            task_update '{"task_id":42,"status":"done"}'
            task_update '{"task_id":42,"title":"New title","priority":1,"labels":"urgent"}'
            ```

            ### Focus a task (highlights it in the UI)
            ```
            task_focus '{"task_id":42}'   # focus
            task_focus '{"task_id":0}'    # unfocus
            ```
            """,
            scripts: [
                ("task_create",  "#!/bin/sh\npecan-agent invoke task_create \"$@\"\n"),
                ("task_list",    "#!/bin/sh\npecan-agent invoke task_list \"$@\"\n"),
                ("task_get",     "#!/bin/sh\npecan-agent invoke task_get \"$@\"\n"),
                ("task_update",  "#!/bin/sh\npecan-agent invoke task_update \"$@\"\n"),
                ("task_focus",   "#!/bin/sh\npecan-agent invoke task_focus \"$@\"\n"),
            ]
        ),
        BuiltinSkill(
            dir: "triggers",
            skillMD: """
            ---
            name: triggers
            description: Schedule future instructions to yourself — one-shot or repeating.
            ---

            ## Triggers

            Triggers deliver an instruction to you at a scheduled time. Useful for reminders,
            periodic check-ins, or deferred actions.

            ### Schedule a trigger
            ```
            trigger_create '{"instruction":"Check if the build passed","fire_at":"2026-03-22T15:00:00Z"}'
            trigger_create '{"instruction":"Send weekly summary","fire_at":"2026-03-24T09:00:00Z","interval_seconds":604800}'
            ```
            `interval_seconds` makes the trigger repeat after firing (0 or omitted = one-shot).

            ### List active triggers
            ```
            trigger_list '{}'
            trigger_list '{"status":"fired"}'    # or "cancelled"
            ```

            ### Cancel a trigger
            ```
            trigger_cancel '{"trigger_id":3}'
            ```
            """,
            scripts: [
                ("trigger_create", "#!/bin/sh\npecan-agent invoke trigger_create \"$@\"\n"),
                ("trigger_list",   "#!/bin/sh\npecan-agent invoke trigger_list \"$@\"\n"),
                ("trigger_cancel", "#!/bin/sh\npecan-agent invoke trigger_cancel \"$@\"\n"),
            ]
        ),
    ]

    for skill in builtins {
        let skillDir = "\(skillsDir)/\(skill.dir)"
        let skillMDPath = "\(skillDir)/SKILL.md"
        guard !fm.fileExists(atPath: skillMDPath) else { continue }
        try? fm.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try? skill.skillMD.write(toFile: skillMDPath, atomically: true, encoding: .utf8)
        if !skill.scripts.isEmpty {
            let scriptsDir = "\(skillDir)/scripts"
            try? fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
            for script in skill.scripts {
                let scriptPath = "\(scriptsDir)/\(script.name)"
                try? script.content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            }
        }
    }
}

/// Scan ~/.pecan/sessions/ for persistent session metadata and respawn their containers.
/// Called once at startup after the launcher and gRPC servers are ready.
func respawnPersistentSessions() async {
    let metas = SessionMeta.allPersistent()
    guard !metas.isEmpty else { return }
    logger.info("Respawning \(metas.count) persistent session(s)...")

    for meta in metas {
        do {
            let store = try SessionStore(sessionID: meta.sessionID)
            await SessionManager.shared.setStore(sessionID: meta.sessionID, store: store)
            await SessionManager.shared.markPersistent(meta.sessionID)

            var shareMounts: [MountSpec] = []

            // Use teamName as the primary key (team = project workspace in flat model).
            // Fall back to projectName for sessions created before this model change.
            let teamKey = meta.teamName.isEmpty ? meta.projectName : meta.teamName
            if !teamKey.isEmpty && teamKey != "default" {
                // Try flat team first, then legacy nested team
                let teamStore: TeamStore
                let flatPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".pecan/teams/\(teamKey)/team.db").path
                if FileManager.default.fileExists(atPath: flatPath) {
                    teamStore = try TeamStore(name: teamKey)
                } else if !meta.projectName.isEmpty {
                    // Legacy: nested under project
                    teamStore = try TeamStore(teamName: teamKey, projectName: meta.projectName)
                } else {
                    teamStore = try TeamStore(name: teamKey)
                }
                await SessionManager.shared.setTeamForSession(
                    sessionID: meta.sessionID, teamName: teamKey, store: teamStore)
                if let dir = teamStore.projectDirectory {
                    shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
                    await SessionManager.shared.setGitBase(
                        sessionID: meta.sessionID, commit: gitHead(for: dir))
                    await ProjectToolRegistry.shared.registerSession(
                        sessionID: meta.sessionID, projectName: teamKey, projectDirectory: dir)
                } else if !meta.projectName.isEmpty {
                    // Legacy fallback: get directory from ProjectStore
                    if let projectStore = try? ProjectStore(name: meta.projectName),
                       let dir = projectStore.directory {
                        shareMounts.append(MountSpec(source: dir, destination: "/project-lower", readOnly: true))
                        await SessionManager.shared.setGitBase(
                            sessionID: meta.sessionID, commit: gitHead(for: dir))
                        await ProjectToolRegistry.shared.registerSession(
                            sessionID: meta.sessionID, projectName: meta.projectName, projectDirectory: dir)
                    }
                }
                shareMounts.append(MountSpec(
                    source: teamStore.workspacePath.path, destination: "/team", readOnly: false))
            }

            // Re-add user shares persisted in the session store
            if let shares = try? store.getShares() {
                for share in shares {
                    shareMounts.append(MountSpec(
                        source: share.hostPath, destination: share.guestPath,
                        readOnly: share.mode == "ro"))
                }
            }

            logger.info("Registered persistent session \(meta.sessionID) (\(meta.agentName)) — container will start on reattach")
        } catch {
            logger.error("Failed to respawn session \(meta.sessionID) (\(meta.agentName)): \(error)")
        }
    }
    // Compact any number gaps left from sessions deleted while the server was offline
    await SessionManager.shared.repackAndBroadcast()
    await SessionManager.shared.flushRunningIndex()
}

