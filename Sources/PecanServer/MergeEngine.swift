import Foundation
import Logging
import PecanShared

private let mergeLogger = Logger(label: "com.pecan.merge-engine")

// MARK: - MergeConflictClient

/// Correlates MergeConflictCommand requests with MergeResolutionResponse replies from the agent.
actor MergeConflictClient {
    static let shared = MergeConflictClient()

    private var pending: [String: CheckedContinuation<Pecan_MergeResolutionResponse, Error>] = [:]

    func sendAndWait(sessionID: String, cmd: Pecan_MergeConflictCommand) async throws -> Pecan_MergeResolutionResponse {
        var hostCmd = Pecan_HostCommand()
        hostCmd.mergeConflictCommand = cmd
        try await SessionManager.shared.sendToAgent(sessionID: sessionID, command: hostCmd)

        return try await withCheckedThrowingContinuation { continuation in
            pending[cmd.mergeID] = continuation
        }
    }

    func handleResponse(_ response: Pecan_MergeResolutionResponse) {
        guard let continuation = pending.removeValue(forKey: response.mergeID) else {
            mergeLogger.warning("MergeConflictClient: no pending merge for id \(response.mergeID)")
            return
        }
        continuation.resume(returning: response)
    }
}

// MARK: - MergeEngine

/// Drives the merge of an agent's overlay changeset into the project directory.
/// Called by /changeset:submit. Handles conflict detection, agent negotiation, and apply.
enum MergeEngine {

    /// Execute a full merge for the session. Sends progress to the UI via agentOutput.
    /// On completion (success or failure) the session merge status is cleared.
    static func run(
        sessionID: String,
        mergeID: String,
        projectDir: String,
        gitBase: String?,
        sendOutput: @escaping (String) async throws -> Void
    ) async {
        do {
            try await attempt(
                sessionID: sessionID,
                mergeID: mergeID,
                projectDir: projectDir,
                gitBase: gitBase,
                attemptNumber: 1,
                sendOutput: sendOutput
            )
        } catch {
            mergeLogger.error("Merge \(mergeID) failed: \(error)")
            try? await MergeQueueStore.shared.finish(mergeID: mergeID, status: "failed", message: error.localizedDescription)
            await SessionManager.shared.clearMerging(sessionID: sessionID, mergeStatus: "failed")
            try? await sendOutput("Merge failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static func attempt(
        sessionID: String,
        mergeID: String,
        projectDir: String,
        gitBase: String?,
        attemptNumber: Int,
        sendOutput: (String) async throws -> Void
    ) async throws {
        let maxAttempts = 5
        guard attemptNumber <= maxAttempts else {
            throw MergeError.tooManyAttempts(maxAttempts)
        }

        // Fetch change list from agent
        let listResp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "list")
        let changes = parseChanges(listResp.content)
        guard !changes.isEmpty else {
            // Nothing left — merge is complete
            try await MergeQueueStore.shared.finish(mergeID: mergeID, status: "merged", message: "No changes")
            await SessionManager.shared.clearMerging(sessionID: sessionID, mergeStatus: "merged")
            try await sendOutput("Merge complete. Overlay is clean.")
            return
        }

        var cleanFiles: [(path: String, data: Data)] = []
        var cleanDeletions: [String] = []
        var conflicts: [Pecan_MergeConflict] = []

        for change in changes {
            switch change.type {
            case "deleted":
                cleanDeletions.append(change.path)

            case "added":
                let resp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "read_file", path: change.path)
                cleanFiles.append((change.path, resp.fileData))

            case "modified":
                let resp = try await ChangesetClient.shared.request(sessionID: sessionID, action: "read_file", path: change.path)
                let projectPath = "\(projectDir)/\(change.path)"
                let currentData = FileManager.default.contents(atPath: projectPath)

                if let conflict = detectConflict(
                    path: change.path,
                    projectPath: projectPath,
                    currentData: currentData,
                    agentData: resp.fileData,
                    gitBase: gitBase,
                    projectDir: projectDir
                ) {
                    conflicts.append(conflict)
                } else {
                    cleanFiles.append((change.path, resp.fileData))
                }

            default:
                break
            }
        }

        // Apply all clean changes
        let fm = FileManager.default
        for (path, data) in cleanFiles {
            let dst = "\(projectDir)/\(path)"
            let dstDir = (dst as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dst))
        }
        for path in cleanDeletions {
            let dst = "\(projectDir)/\(path)"
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
        }

        if conflicts.isEmpty {
            // All done — discard overlay
            _ = try await ChangesetClient.shared.request(sessionID: sessionID, action: "discard")
            let total = cleanFiles.count + cleanDeletions.count
            let msg = "Merged \(total) change(s) into project."
            try await MergeQueueStore.shared.finish(mergeID: mergeID, status: "merged", message: msg)
            await SessionManager.shared.clearMerging(sessionID: sessionID, mergeStatus: "merged")
            try await sendOutput(msg)
        } else {
            // Send conflicts to agent for resolution
            try await sendOutput("Merge attempt \(attemptNumber): \(conflicts.count) conflict(s) — asking agent to resolve...")
            var cmd = Pecan_MergeConflictCommand()
            cmd.mergeID = mergeID
            cmd.attempt = Int32(attemptNumber)
            cmd.conflicts = conflicts

            let resolution = try await MergeConflictClient.shared.sendAndWait(sessionID: sessionID, cmd: cmd)

            if resolution.abort {
                let msg = resolution.message.isEmpty
                    ? "Agent declared conflicts unresolvable after \(attemptNumber) attempt(s)."
                    : resolution.message
                try await MergeQueueStore.shared.finish(mergeID: mergeID, status: "failed", message: msg)
                await SessionManager.shared.clearMerging(sessionID: sessionID, mergeStatus: "failed")
                try await sendOutput("Merge failed: \(msg)\nReview conflicts manually and use /changeset:discard to reset.")
                return
            }

            // Write resolved files into agent's upper dir via ChangesetCommand
            // (We ask the agent to write them by sending back resolved content as an update)
            // The agent already wrote them in its response processing — now re-run merge
            // Apply agent's resolutions directly to project dir (they come from the agent)
            for resolved in resolution.resolved {
                let safe = sanitizePath(resolved.path)
                guard !safe.isEmpty else { continue }
                let dst = "\(projectDir)/\(safe)"
                let dstDir = (dst as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
                try resolved.content.write(to: URL(fileURLWithPath: dst))
            }

            // Discard the resolved paths from the agent's overlay
            let resolvedPaths = resolution.resolved.map { $0.path }
            if !resolvedPaths.isEmpty {
                _ = try await ChangesetClient.shared.request(
                    sessionID: sessionID, action: "discard",
                    patterns: resolvedPaths)
            }

            // Recurse: try again with remaining changes (if any conflict paths weren't in resolution)
            try await attempt(
                sessionID: sessionID,
                mergeID: mergeID,
                projectDir: projectDir,
                gitBase: gitBase,
                attemptNumber: attemptNumber + 1,
                sendOutput: sendOutput
            )
        }
    }

    // MARK: - Conflict detection

    private static func detectConflict(
        path: String,
        projectPath: String,
        currentData: Data?,
        agentData: Data,
        gitBase: String?,
        projectDir: String
    ) -> Pecan_MergeConflict? {
        // If the file doesn't exist in the project dir, no conflict — just add it.
        guard let currentData = currentData else { return nil }
        // If current content == agent content, already in sync — no conflict.
        if currentData == agentData { return nil }

        // Try to determine the base version using git.
        let baseContent: String?
        if let base = gitBase {
            baseContent = gitShow(commit: base, path: path, projectDir: projectDir)
        } else {
            baseContent = nil
        }

        let currentStr = String(data: currentData, encoding: .utf8) ?? ""

        // If we have a base: check whether the project dir changed since base.
        if let base = baseContent {
            if base == currentStr {
                // Project dir hasn't changed since base — no conflict, agent wins.
                return nil
            }
            // Both changed — real conflict. Compute conflict markers.
            let agentStr = String(data: agentData, encoding: .utf8) ?? ""
            let conflictText = mergeWithMarkers(base: base, current: currentStr, agent: agentStr, path: path)
            var conflict = Pecan_MergeConflict()
            conflict.path = path
            conflict.baseContent = base
            conflict.currentContent = currentStr
            conflict.agentContent = agentStr
            conflict.conflictText = conflictText
            return conflict
        }

        // No git base available — assume conflict if files differ (conservative).
        let agentStr = String(data: agentData, encoding: .utf8) ?? ""
        let conflictText = mergeWithMarkers(base: "", current: currentStr, agent: agentStr, path: path)
        var conflict = Pecan_MergeConflict()
        conflict.path = path
        conflict.baseContent = ""
        conflict.currentContent = currentStr
        conflict.agentContent = agentStr
        conflict.conflictText = conflictText
        return conflict
    }

    /// Generate conflict-marker text using `diff3 -m` when possible, falling back to a simple layout.
    private static func mergeWithMarkers(base: String, current: String, agent: String, path: String) -> String {
        // Try diff3 for a proper 3-way merge
        let tmp = FileManager.default.temporaryDirectory
        let currentFile = tmp.appendingPathComponent(UUID().uuidString)
        let baseFile    = tmp.appendingPathComponent(UUID().uuidString)
        let agentFile   = tmp.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: currentFile)
            try? FileManager.default.removeItem(at: baseFile)
            try? FileManager.default.removeItem(at: agentFile)
        }
        do {
            try current.write(to: currentFile, atomically: true, encoding: .utf8)
            try base.write(to: baseFile, atomically: true, encoding: .utf8)
            try agent.write(to: agentFile, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff3")
            proc.arguments = ["-m",
                              "--label", "HEAD (project)",
                              currentFile.path,
                              "--label", "BASE",
                              baseFile.path,
                              "--label", "agent/\(path)",
                              agentFile.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try proc.run()
            proc.waitUntilExit()
            if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !out.isEmpty {
                return out
            }
        } catch {}

        // Fallback: simple conflict layout
        return """
            <<<<<<< HEAD (project)
            \(current)
            =======
            \(agent)
            >>>>>>> agent/\(path)
            """
    }

    /// Run `git show <commit>:<path>` and return the file content, or nil.
    private static func gitShow(commit: String, path: String, projectDir: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", projectDir, "show", "\(commit):\(path)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: - Helpers

    private struct ChangeEntry { let path: String; let type: String }

    private static func parseChanges(_ json: String) -> [ChangeEntry] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return arr.compactMap { d in
            guard let p = d["path"], let t = d["type"] else { return nil }
            return ChangeEntry(path: p, type: t)
        }
    }

    private static func sanitizePath(_ path: String) -> String {
        path.components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != ".." }
            .joined(separator: "/")
    }

    enum MergeError: Error, LocalizedError {
        case tooManyAttempts(Int)
        var errorDescription: String? {
            switch self {
            case .tooManyAttempts(let n): return "Merge still has conflicts after \(n) resolution attempts."
            }
        }
    }
}

// MARK: - Git HEAD helper (used at spawn time)

/// Returns the current git HEAD commit hash for the given directory, or nil if not a git repo.
func gitHead(for directory: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", directory, "rev-parse", "HEAD"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
