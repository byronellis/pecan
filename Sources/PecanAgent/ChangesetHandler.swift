#if os(Linux)
import Foundation
import PecanShared
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Handles ChangesetCommand messages from the server.
/// Operates on the container-local overlay dirs (/project-lower, /project-upper).
enum ChangesetHandler {
    static let lowerDir = "/project-lower"
    static let upperDir = "/project-upper"

    static func handle(cmd: Pecan_ChangesetCommand) -> Pecan_ChangesetResponse {
        var resp = Pecan_ChangesetResponse()
        resp.requestID = cmd.requestID
        let patterns = cmd.patterns.isEmpty ? nil : Array(cmd.patterns)

        switch cmd.action {
        case "list":
            let changes = listChanges(patterns: patterns)
            do {
                let items = changes.map { ["path": $0.path, "type": $0.changeType] }
                let data = try JSONSerialization.data(withJSONObject: items)
                resp.content = String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                resp.errorMessage = "Failed to serialize change list: \(error)"
            }

        case "diff":
            resp.content = computeDiff(changes: listChanges(patterns: patterns))

        case "read_file":
            guard !cmd.path.isEmpty else {
                resp.errorMessage = "read_file requires a path"
                break
            }
            let filePath = "\(upperDir)/\(cmd.path)"
            guard let data = FileManager.default.contents(atPath: filePath) else {
                resp.errorMessage = "File not found in overlay upper: \(cmd.path)"
                break
            }
            resp.fileData = data

        case "discard":
            do {
                if let pats = patterns {
                    // Targeted discard: only remove upper-dir entries whose logical path matches
                    let all = listChanges(patterns: nil)
                    let matched = all.filter { globMatches(patterns: pats, path: $0.path) }
                    let fm = FileManager.default
                    for change in matched {
                        if change.changeType == "deleted" {
                            // Remove whiteout file(s) for this path
                            let dir = (change.path as NSString).deletingLastPathComponent
                            let base = (change.path as NSString).lastPathComponent
                            let whiteout = dir.isEmpty
                                ? "\(upperDir)/.wh.\(base)"
                                : "\(upperDir)/\(dir)/.wh.\(base)"
                            try? fm.removeItem(atPath: whiteout)
                        } else {
                            try? fm.removeItem(atPath: "\(upperDir)/\(change.path)")
                        }
                    }
                } else {
                    // Full discard: wipe everything in upper
                    let fm = FileManager.default
                    if let items = try? fm.contentsOfDirectory(atPath: upperDir) {
                        for item in items {
                            try fm.removeItem(atPath: "\(upperDir)/\(item)")
                        }
                    }
                }
                resp.content = "ok"
            } catch {
                resp.errorMessage = "Failed to discard overlay: \(error)"
            }

        default:
            resp.errorMessage = "Unknown changeset action: \(cmd.action)"
        }

        return resp
    }

    // MARK: - Helpers

    struct ChangeEntry {
        let path: String
        let changeType: String  // "added", "modified", "deleted"
    }

    /// Walk the upper dir and return all changed entries, optionally filtered by glob patterns.
    private static func listChanges(patterns: [String]?) -> [ChangeEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: upperDir) else { return [] }
        var changes: [ChangeEntry] = []
        while let rel = enumerator.nextObject() as? String {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: "\(upperDir)/\(rel)", isDirectory: &isDir)
            if isDir.boolValue { continue }
            let fileName = (rel as NSString).lastPathComponent
            let entry: ChangeEntry
            if fileName.hasPrefix(".wh.") {
                let dir = (rel as NSString).deletingLastPathComponent
                let target = String(fileName.dropFirst(4))
                let path = dir.isEmpty ? target : "\(dir)/\(target)"
                entry = ChangeEntry(path: path, changeType: "deleted")
            } else if fm.fileExists(atPath: "\(lowerDir)/\(rel)") {
                entry = ChangeEntry(path: rel, changeType: "modified")
            } else {
                entry = ChangeEntry(path: rel, changeType: "added")
            }
            if let pats = patterns {
                guard globMatches(patterns: pats, path: entry.path) else { continue }
            }
            changes.append(entry)
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// Returns true if any of the given glob patterns matches path.
    /// Patterns support shell-style wildcards (* matches within a component, ** matches across).
    private static func globMatches(patterns: [String], path: String) -> Bool {
        for pattern in patterns {
            // Use fnmatch with FNM_PATHNAME for single-* and a second pass for **
            let flags: Int32 = FNM_PATHNAME
            if fnmatch(pattern, path, flags) == 0 {
                return true
            }
            // Also try without FNM_PATHNAME to allow ** to span slashes
            if fnmatch(pattern, path, 0) == 0 {
                return true
            }
        }
        return false
    }

    private static func computeDiff(changes: [ChangeEntry]) -> String {
        var parts: [String] = []
        for change in changes {
            switch change.changeType {
            case "added":
                let content = (try? String(contentsOfFile: "\(upperDir)/\(change.path)", encoding: .utf8)) ?? ""
                let lines = content.components(separatedBy: "\n")
                var d = "--- /dev/null\n+++ b/\(change.path)\n@@ -0,0 +1,\(lines.count) @@\n"
                for l in lines { d += "+\(l)\n" }
                parts.append(d)
            case "deleted":
                let content = (try? String(contentsOfFile: "\(lowerDir)/\(change.path)", encoding: .utf8)) ?? ""
                let lines = content.components(separatedBy: "\n")
                var d = "--- a/\(change.path)\n+++ /dev/null\n@@ -1,\(lines.count) +0,0 @@\n"
                for l in lines { d += "-\(l)\n" }
                parts.append(d)
            case "modified":
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
                proc.arguments = [
                    "-u",
                    "--label", "a/\(change.path)", "\(lowerDir)/\(change.path)",
                    "--label", "b/\(change.path)", "\(upperDir)/\(change.path)"
                ]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.standardError
                try? proc.run()
                proc.waitUntilExit()
                if let d = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !d.isEmpty {
                    parts.append(d)
                }
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }
}
#endif
