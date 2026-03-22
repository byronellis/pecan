import Foundation
import Logging

/// Manages per-session pecan-fs-server FUSE mounts backed by SQLite databases.
public actor FSServerManager {
    public static let shared = FSServerManager()

    private struct MountEntry {
        let process: Process
        let mountPath: String
    }

    private struct OverlayEntry {
        let process: Process
        let mountPath: String
        let lowerDir: String
        let upperDir: String
    }

    private var mounts: [String: MountEntry] = [:]
    private var skillsMount: MountEntry?
    private var overlayMounts: [String: OverlayEntry] = [:]

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

    /// Mount a per-session COW overlay FUSE filesystem.
    /// The lower layer is the project directory (read-only source).
    /// The upper layer is a per-session writable scratch at .run/overlay/<sessionID>/.
    /// Returns the host mount path for inclusion in container share mounts.
    public func mountOverlay(sessionID: String, lowerDir: String) async throws -> String {
        if let existing = overlayMounts[sessionID] { return existing.mountPath }

        guard let binaryPath = fsBinaryPath() else { throw FSManagerError.binaryNotFound }

        let currentPath = FileManager.default.currentDirectoryPath
        let upperDir = "\(currentPath)/.run/overlay/\(sessionID)"
        let mountPath = "\(currentPath)/.run/fuse/overlay/\(sessionID)"
        try FileManager.default.createDirectory(atPath: upperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)

        let procArgs = [
            mountPath,
            "--mode", "overlay",
            "--lower-dir", lowerDir,
            "--upper-dir", upperDir,
            "--session-id", sessionID
        ]

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
            logger.warning("pecan-fs-server (overlay/\(sessionID)) exited (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-fs-server (overlay) pid \(proc.processIdentifier) for \(sessionID) at \(mountPath)")
        overlayMounts[sessionID] = OverlayEntry(process: proc, mountPath: mountPath, lowerDir: lowerDir, upperDir: upperDir)

        try await waitForMount(mountPath: mountPath)
        return mountPath
    }

    public func unmountOverlay(sessionID: String) {
        guard let entry = overlayMounts.removeValue(forKey: sessionID) else { return }
        logger.info("Unmounting overlay for session \(sessionID)")
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

    /// Swap the lower directory for an existing overlay without restarting the container.
    /// The mount path stays stable; only the backing FUSE process is replaced.
    /// If no overlay exists yet, falls through to a normal mount.
    public func remountOverlay(sessionID: String, newLowerDir: String) async throws -> String {
        guard let entry = overlayMounts.removeValue(forKey: sessionID) else {
            return try await mountOverlay(sessionID: sessionID, lowerDir: newLowerDir)
        }

        guard let binaryPath = fsBinaryPath() else { throw FSManagerError.binaryNotFound }

        // Tear down the old FUSE process (keep the mount directory).
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [entry.mountPath]
        try? umount.run()
        umount.waitUntilExit()
        if entry.process.isRunning {
            entry.process.terminate()
            entry.process.waitUntilExit()
        }

        let currentPath = FileManager.default.currentDirectoryPath
        let procArgs = [
            entry.mountPath,
            "--mode", "overlay",
            "--lower-dir", newLowerDir,
            "--upper-dir", entry.upperDir,
            "--session-id", sessionID
        ]

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
            logger.warning("pecan-fs-server (overlay/\(sessionID)) exited (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Remounted pecan-fs-server (overlay) pid \(proc.processIdentifier) for \(sessionID) → lower: \(newLowerDir)")
        overlayMounts[sessionID] = OverlayEntry(process: proc, mountPath: entry.mountPath, lowerDir: newLowerDir, upperDir: entry.upperDir)

        try await waitForMount(mountPath: entry.mountPath)
        return entry.mountPath
    }

    /// Replace the memory FUSE for a session with updated DB paths (e.g. after project switch).
    /// The mount path stays stable; the backing process is replaced transparently.
    public func remountMemory(sessionID: String,
                              agentDBPath: String,
                              projectDBPath: String? = nil,
                              teamDBPath: String? = nil) async throws -> String {
        if let entry = mounts.removeValue(forKey: sessionID) {
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
        return try await mount(sessionID: sessionID,
                               agentDBPath: agentDBPath,
                               projectDBPath: projectDBPath,
                               teamDBPath: teamDBPath)
    }

    /// Returns (lowerDir, upperDir) for the session's overlay, or nil if not mounted.
    public func overlayDirs(sessionID: String) -> (lower: String, upper: String)? {
        guard let entry = overlayMounts[sessionID] else { return nil }
        return (entry.lowerDir, entry.upperDir)
    }

    /// Wipes the upper layer for a session (discard). The overlay FUSE keeps running.
    public func discardOverlay(sessionID: String) throws {
        guard let entry = overlayMounts[sessionID] else { return }
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: entry.upperDir)
        for item in items {
            try fm.removeItem(atPath: "\(entry.upperDir)/\(item)")
        }
        logger.info("Discarded overlay upper layer for session \(sessionID)")
    }
}
