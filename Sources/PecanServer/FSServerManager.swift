import Foundation
import Logging

/// Manages per-session pecan-fs-server FUSE mounts backed by SQLite databases.
public actor FSServerManager {
    public static let shared = FSServerManager()

    private struct MountEntry {
        let process: Process
        let mountPath: String
    }

    private var mounts: [String: MountEntry] = [:]
    private var skillsMount: MountEntry?

    private func fsBinaryPath() -> String? {
        let currentPath = FileManager.default.currentDirectoryPath
        let serverBinary = CommandLine.arguments[0]
        let serverDir = (serverBinary as NSString).deletingLastPathComponent
        let sibling = "\(serverDir)/pecan-fs-server"
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        let debug = "\(currentPath)/.build/debug/pecan-fs-server"
        if FileManager.default.isExecutableFile(atPath: debug) { return debug }
        return nil
    }

    /// Mounts a per-session FUSE filesystem backed by SQLite.
    /// Returns the host mount path for inclusion in container share mounts.
    public func mount(sessionID: String,
                      agentDBPath: String,
                      projectDBPath: String? = nil,
                      teamDBPath: String? = nil) async throws -> String {
        if let existing = mounts[sessionID] { return existing.mountPath }

        guard let binaryPath = fsBinaryPath() else { throw FSManagerError.binaryNotFound }

        let currentPath = FileManager.default.currentDirectoryPath
        let mountPath = "\(currentPath)/.run/fuse/\(sessionID)"
        try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)

        var procArgs = [mountPath, "--agent-db", agentDBPath]
        if let p = projectDBPath { procArgs += ["--project-db", p] }
        if let t = teamDBPath    { procArgs += ["--team-db",    t] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = procArgs
        proc.currentDirectoryURL = URL(fileURLWithPath: currentPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError  = FileHandle.standardError

        var env = ProcessInfo.processInfo.environment
        let existing = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? "/usr/local/lib" : "/usr/local/lib:\(existing)"
        proc.environment = env

        proc.terminationHandler = { p in
            logger.warning("pecan-fs-server for session \(sessionID) exited (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-fs-server (pid \(proc.processIdentifier)) for session \(sessionID) at \(mountPath)")
        mounts[sessionID] = MountEntry(process: proc, mountPath: mountPath)

        try await waitForMount(mountPath: mountPath)
        return mountPath
    }

    public func unmount(sessionID: String) {
        guard let entry = mounts.removeValue(forKey: sessionID) else { return }
        logger.info("Unmounting FUSE for session \(sessionID)")
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [entry.mountPath]
        try? umount.run()
        umount.waitUntilExit()
        if entry.process.isRunning {
            entry.process.terminate()
            entry.process.waitUntilExit()
        }
    }

    private func waitForMount(mountPath: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? FileManager.default.contentsOfDirectory(atPath: mountPath)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FSManagerError.mountTimeout(mountPath)
    }

    public enum FSManagerError: Error, CustomStringConvertible {
        case binaryNotFound
        case mountTimeout(String)
        public var description: String {
            switch self {
            case .binaryNotFound: return "pecan-fs-server binary not found"
            case .mountTimeout(let p): return "Timed out waiting for FUSE mount at \(p)"
            }
        }
    }

    /// Returns the current skills mount path if mounted, otherwise nil.
    public func skillsMountPath() -> String? {
        skillsMount?.mountPath
    }

    /// Ensure built-in skill directories exist under skillsDir.
    /// Creates web/ (http_request) and dev/ (create_lua_tool) and memory/ skills if absent.
    private func ensureBuiltinSkills(skillsDir: String) {
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
                dir: "memory",
                skillMD: """
                ---
                name: memory
                description: Search and manage persistent memories stored in /memory/.
                ---

                ## Memory Management

                Memories are stored as files in `/memory/`. Each file contains entries marked with `<!-- memory:N -->` blocks.

                ### Read all memories for a tag
                ```
                cat /memory/CORE.md
                cat /memory/NOTES.md
                ```

                ### List all tags
                ```
                ls /memory/
                ```

                ### Search memories
                ```
                grep -r "keyword" /memory/
                grep "keyword" /memory/NOTES.md
                ```

                ### Add a new memory
                Use `append_file` with path `/memory/TAG.md` — appending always creates a new memory entry.

                ### Edit a memory
                Use `edit_file` to find-and-replace within a memory file.

                ### Delete a memory
                Rewrite the file with `write_file`, omitting the block you want to delete (blocks without their ID are deleted).
                """,
                scripts: []
            ),
        ]

        for skill in builtins {
            let skillDir = "\(skillsDir)/\(skill.dir)"
            let skillMDPath = "\(skillDir)/SKILL.md"

            // Only create if SKILL.md doesn't already exist (don't overwrite user customizations)
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

    /// Mount the global (shared across all sessions) skills FUSE filesystem.
    /// Returns the host mount path for inclusion in container share mounts.
    public func mountSkills(skillsDir: String) async throws -> String {
        if let existing = skillsMount { return existing.mountPath }

        ensureBuiltinSkills(skillsDir: skillsDir)

        guard let binaryPath = fsBinaryPath() else { throw FSManagerError.binaryNotFound }

        let currentPath = FileManager.default.currentDirectoryPath
        let mountPath = "\(currentPath)/.run/fuse/skills"
        try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)

        let procArgs = [mountPath, "--mode", "skills", "--skills-dir", skillsDir]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = procArgs
        proc.currentDirectoryURL = URL(fileURLWithPath: currentPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        var env = ProcessInfo.processInfo.environment
        let existingLib = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existingLib.isEmpty ? "/usr/local/lib" : "/usr/local/lib:\(existingLib)"
        proc.environment = env

        proc.terminationHandler = { p in
            logger.warning("pecan-fs-server (skills) exited (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-fs-server (skills) (pid \(proc.processIdentifier)) at \(mountPath)")
        skillsMount = MountEntry(process: proc, mountPath: mountPath)

        try await waitForMount(mountPath: mountPath)
        return mountPath
    }

    public func unmountSkills() {
        guard let entry = skillsMount else { return }
        skillsMount = nil
        logger.info("Unmounting skills FUSE")
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [entry.mountPath]
        try? umount.run()
        umount.waitUntilExit()
        if entry.process.isRunning {
            entry.process.terminate()
            entry.process.waitUntilExit()
        }
    }
}
