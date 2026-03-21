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
}
