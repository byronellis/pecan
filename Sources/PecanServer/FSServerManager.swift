import Foundation
import Logging

/// Manages per-session pecan-fs-server FUSE mounts for agent memory access.
/// Each session gets its own FUSE mount at .run/fuse/<sessionID>/ backed
/// by persistent storage at .run/fs/<sessionID>/.
public actor FSServerManager {
    public static let shared = FSServerManager()

    private struct MountEntry {
        let process: Process
        let mountPath: String
        let persistPath: String
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

    /// Mounts a per-session FUSE filesystem and returns the host mount path.
    /// Safe to call again for an already-mounted session (returns existing path).
    public func mount(sessionID: String) async throws -> String {
        if let existing = mounts[sessionID] {
            return existing.mountPath
        }

        guard let binaryPath = fsBinaryPath() else {
            throw FSManagerError.binaryNotFound
        }

        let currentPath = FileManager.default.currentDirectoryPath
        let mountPath = "\(currentPath)/.run/fuse/\(sessionID)"
        let persistPath = "\(currentPath)/.run/fs/\(sessionID)"

        let fm = FileManager.default
        try fm.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: persistPath, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [mountPath, "--persist", persistPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: currentPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        // libfuse-t.dylib lives in /usr/local/lib — add to rpath so dyld finds it
        var env = ProcessInfo.processInfo.environment
        let existing = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? "/usr/local/lib" : "/usr/local/lib:\(existing)"
        proc.environment = env

        proc.terminationHandler = { p in
            logger.warning("pecan-fs-server for session \(sessionID) exited (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-fs-server (pid \(proc.processIdentifier)) for session \(sessionID) at \(mountPath)")
        mounts[sessionID] = MountEntry(process: proc, mountPath: mountPath, persistPath: persistPath)

        try await waitForMount(mountPath: mountPath)
        return mountPath
    }

    /// Unmounts and terminates the FUSE server for a session.
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
            if (try? FileManager.default.contentsOfDirectory(atPath: mountPath)) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        throw FSManagerError.mountTimeout(mountPath)
    }

    public enum FSManagerError: Error, CustomStringConvertible {
        case binaryNotFound
        case mountTimeout(String)

        public var description: String {
            switch self {
            case .binaryNotFound: return "pecan-fs-server binary not found"
            case .mountTimeout(let path): return "Timed out waiting for FUSE mount at \(path)"
            }
        }
    }
}
