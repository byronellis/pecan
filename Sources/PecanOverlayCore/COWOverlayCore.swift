import Foundation

// MARK: - COWOverlayCore

/// Platform-agnostic copy-on-write overlay filesystem logic.
///
/// Manages a union of a read-only lower directory and a writable upper directory.
/// Writes always go to the upper layer; deletes create whiteout marker files.
/// Virtual read-only files at `/.pecan/{diff,changes,status}` expose the current
/// change summary without touching the real filesystem layers.
///
/// This type contains no FUSE-specific dependencies and can be unit-tested on
/// any platform supported by Foundation.
public actor COWOverlayCore {
    public let lowerDir: String
    public let upperDir: String

    // Virtual file content cache, keyed by name (diff / changes / status).
    private var virtualCache: [String: Data] = [:]

    // Per-file diff cache: relPath → unified diff text.
    // Cleared per-file when that file is modified; cleared entirely on first access after a cold start.
    private var perFileDiffCache: [String: String] = [:]

    // Set of logical paths whose diff cache entry was invalidated by a recent write.
    private var dirtyPaths: Set<String> = []

    public init(lower: String, upper: String) {
        self.lowerDir = lower
        self.upperDir = upper
    }

    // MARK: - Path helpers

    public func upperPath(_ relPath: String) -> String {
        relPath == "/" ? upperDir : upperDir + relPath
    }

    public func lowerPath(_ relPath: String) -> String {
        relPath == "/" ? lowerDir : lowerDir + relPath
    }

    // MARK: - Existence / whiteout helpers

    public func isWhitedOut(_ name: String, inDir: String) -> Bool {
        let whPath = upperDir + inDir + "/.wh." + name
        return FileManager.default.fileExists(atPath: whPath)
    }

    public func existsInUpper(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: upperPath(relPath))
    }

    public func existsInLower(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: lowerPath(relPath))
    }

    // MARK: - COW copy

    /// Copy a file from the lower layer to the upper layer if not already there.
    /// Creates intermediate directories as needed. No-op if the file does not
    /// exist in the lower layer or already exists in the upper layer.
    public func cowCopy(_ relPath: String) {
        let srcPath = lowerPath(relPath)
        let dstPath = upperPath(relPath)
        guard FileManager.default.fileExists(atPath: srcPath) else { return }
        guard !FileManager.default.fileExists(atPath: dstPath) else { return }
        let dstDir = (dstPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
    }

    // MARK: - File I/O

    /// Read `size` bytes from the file at `relPath` starting at `offset`.
    /// Returns nil if the file does not exist in either layer.
    public func readFile(at relPath: String, offset: UInt64, size: Int) -> Data? {
        let uPath = upperPath(relPath)
        let lPath = lowerPath(relPath)
        let filePath: String
        if FileManager.default.fileExists(atPath: uPath) {
            filePath = uPath
        } else if FileManager.default.fileExists(atPath: lPath) {
            filePath = lPath
        } else {
            return nil
        }
        guard let fh = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        return fh.readData(ofLength: size)
    }

    /// Write `data` to `relPath` at `offset`, COW-copying from lower if needed.
    /// Returns a POSIX errno value (0 on success).
    @discardableResult
    public func writeFile(at relPath: String, offset: UInt64, data: Data) -> Int32 {
        cowCopy(relPath)
        let uPath = upperPath(relPath)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: uPath) {
            guard FileManager.default.createFile(atPath: uPath, contents: nil) else { return EACCES }
        }
        guard let fh = FileHandle(forWritingAtPath: uPath) else { return EIO }
        defer { fh.closeFile() }
        fh.seek(toFileOffset: offset)
        fh.write(data)
        invalidateFile(relPath)
        return 0
    }

    /// Create a new file at `relPath`. Removes any existing whiteout.
    /// Returns a POSIX errno value (0 on success).
    @discardableResult
    public func createFile(at relPath: String, mode: UInt32 = 0o644) -> Int32 {
        let uPath = upperPath(relPath)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: uPath, contents: nil) else { return EIO }
        // Remove any whiteout that may have existed
        let parentPath = (relPath as NSString).deletingLastPathComponent
        let name = (relPath as NSString).lastPathComponent
        let whPath = upperDir + parentPath + "/.wh." + name
        try? FileManager.default.removeItem(atPath: whPath)
        invalidateFile(relPath)
        return 0
    }

    /// Create a directory at `relPath`. Removes any existing whiteout.
    /// Returns a POSIX errno value (0 on success).
    @discardableResult
    public func createDirectory(at relPath: String, mode: UInt32 = 0o755) -> Int32 {
        let uPath = upperPath(relPath)
        do {
            try FileManager.default.createDirectory(atPath: uPath, withIntermediateDirectories: true)
        } catch {
            return EIO
        }
        let parentPath = (relPath as NSString).deletingLastPathComponent
        let name = (relPath as NSString).lastPathComponent
        let whPath = upperDir + parentPath + "/.wh." + name
        try? FileManager.default.removeItem(atPath: whPath)
        invalidateVirtualCache()
        return 0
    }

    /// Delete a file at `relPath`. Creates a whiteout if it existed in the lower layer.
    /// Returns a POSIX errno value (0 on success).
    @discardableResult
    public func deleteFile(at relPath: String) -> Int32 {
        let inUpper = existsInUpper(relPath)
        let inLower = existsInLower(relPath)
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(relPath)) }
        if inLower {
            let parentPath = (relPath as NSString).deletingLastPathComponent
            let name = (relPath as NSString).lastPathComponent
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: whDir + "/.wh." + name, contents: nil)
        }
        invalidateFile(relPath)
        return 0
    }

    /// Delete a directory at `relPath`. Creates a whiteout if it existed in the lower layer.
    @discardableResult
    public func deleteDirectory(at relPath: String) -> Int32 {
        let inUpper = existsInUpper(relPath)
        let inLower = existsInLower(relPath)
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(relPath)) }
        if inLower {
            let parentPath = (relPath as NSString).deletingLastPathComponent
            let name = (relPath as NSString).lastPathComponent
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: whDir + "/.wh." + name, contents: nil)
        }
        invalidateVirtualCache()
        return 0
    }

    /// Rename `oldRelPath` to `newRelPath`. COW-copies source from lower if needed.
    /// Returns a POSIX errno value (0 on success).
    @discardableResult
    public func rename(from oldRelPath: String, to newRelPath: String) -> Int32 {
        cowCopy(oldRelPath)
        guard existsInUpper(oldRelPath) else { return ENOENT }
        let srcUpper = upperPath(oldRelPath)
        let dstUpper = upperPath(newRelPath)
        let dstDir = (dstUpper as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dstUpper)
        do {
            try FileManager.default.moveItem(atPath: srcUpper, toPath: dstUpper)
        } catch {
            return EIO
        }
        if existsInLower(oldRelPath) {
            let parentPath = (oldRelPath as NSString).deletingLastPathComponent
            let name = (oldRelPath as NSString).lastPathComponent
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: whDir + "/.wh." + name, contents: nil)
        }
        // Invalidate both source and destination in the diff cache
        invalidateFile(oldRelPath)
        invalidateFile(newRelPath)
        return 0
    }

    /// Truncate the file at `relPath` to `newSize`. COW-copies from lower if needed.
    @discardableResult
    public func truncateFile(at relPath: String, to newSize: UInt64) -> Int32 {
        cowCopy(relPath)
        let uPath = upperPath(relPath)
        guard let fh = FileHandle(forWritingAtPath: uPath) else { return ENOENT }
        defer { fh.closeFile() }
        fh.truncateFile(atOffset: newSize)
        invalidateFile(relPath)
        return 0
    }

    // MARK: - Directory listing

    /// Return the union of entries in the upper and lower directories at `relPath`,
    /// with whiteouts applied. Entry flags: `(name, isDirectory)`.
    public func listDirectory(_ relPath: String) -> [(name: String, isDirectory: Bool)] {
        var names = Set<String>()
        var whiteouts = Set<String>()

        let uDir = upperPath(relPath)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: uDir) {
            for item in items {
                if item.hasPrefix(".wh.") {
                    whiteouts.insert(String(item.dropFirst(4)))
                } else {
                    names.insert(item)
                }
            }
        }
        let lDir = lowerPath(relPath)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: lDir) {
            for item in items { names.insert(item) }
        }
        names.subtract(whiteouts)

        return names.sorted().map { name in
            let childPath = relPath == "/" ? "/\(name)" : "\(relPath)/\(name)"
            var isDir: ObjCBool = false
            let uChild = upperPath(childPath)
            let lChild = lowerPath(childPath)
            if FileManager.default.fileExists(atPath: uChild, isDirectory: &isDir) {
                return (name, isDir.boolValue)
            } else if FileManager.default.fileExists(atPath: lChild, isDirectory: &isDir) {
                return (name, isDir.boolValue)
            }
            return (name, false)
        }
    }

    // MARK: - Virtual file content

    /// Return cached (or freshly generated) content for a virtual file path.
    /// Valid paths: `/.pecan/diff`, `/.pecan/changes`, `/.pecan/status`.
    public func virtualContent(for relPath: String) -> Data? {
        let name: String
        switch relPath {
        case "/.pecan/diff":    name = "diff"
        case "/.pecan/changes": name = "changes"
        case "/.pecan/status":  name = "status"
        default: return nil
        }
        if let cached = virtualCache[name] { return cached }
        let content: String
        switch name {
        case "diff":    content = generateDiff()
        case "changes": content = generateChanges()
        case "status":  content = generateStatus()
        default:        content = ""
        }
        let data = Data(content.utf8)
        virtualCache[name] = data
        return data
    }

    // MARK: - Virtual file generation

    /// Generate a unified diff of all changes in the upper layer vs the lower layer.
    ///
    /// Uses a per-file diff cache (`perFileDiffCache`): only files whose path
    /// appears in `dirtyPaths` are re-diffed. All other modified files reuse
    /// the cached result. This prevents spawning N processes on every access
    /// when only one file changed.
    public func generateDiff() -> String {
        var parts: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            let fullUpper = upperDir + "/" + rel
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: fullUpper, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let fileName = (rel as NSString).lastPathComponent
            if fileName.hasPrefix(".wh.") { continue }

            let logicalPath = "/" + rel

            // Use cached diff if this file has not been modified since last generation
            if !dirtyPaths.contains(logicalPath), let cached = perFileDiffCache[logicalPath] {
                if !cached.isEmpty { parts.append(cached) }
                continue
            }

            // Generate diff for this file
            let uPath = upperPath(logicalPath)
            let lPath = lowerPath(logicalPath)
            let diffText = runDiff(lower: lPath, upper: uPath)
            perFileDiffCache[logicalPath] = diffText
            if !diffText.isEmpty { parts.append(diffText) }
        }
        dirtyPaths.removeAll()
        return parts.joined(separator: "\n")
    }

    /// Generate a sorted list of changed paths with status prefixes (M/A/D).
    public func generateChanges() -> String {
        var lines: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            let fullUpper = upperDir + "/" + rel
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: fullUpper, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let fileName = (rel as NSString).lastPathComponent
            if fileName.hasPrefix(".wh.") {
                let dir = (rel as NSString).deletingLastPathComponent
                let target = String(fileName.dropFirst(4))
                let logicalPath = dir.isEmpty ? "/\(target)" : "/\(dir)/\(target)"
                lines.append("D \(logicalPath)")
            } else {
                let logicalPath = "/" + rel
                let lPath = lowerPath(logicalPath)
                let status = FileManager.default.fileExists(atPath: lPath) ? "M" : "A"
                lines.append("\(status) \(logicalPath)")
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// Generate a JSON summary of change counts.
    public func generateStatus() -> String {
        let changesText = generateChanges()
        let lines = changesText.isEmpty ? [] : changesText.components(separatedBy: "\n")
        let modified = lines.filter { $0.hasPrefix("M") }.count
        let added    = lines.filter { $0.hasPrefix("A") }.count
        let deleted  = lines.filter { $0.hasPrefix("D") }.count

        // Build JSON manually to avoid a Foundation JSONSerialization dependency
        // and to guarantee stable key order for testing.
        let ts = ISO8601DateFormatter().string(from: Date())
        return """
        {
          "session_id" : "overlay",
          "modified" : \(modified),
          "added" : \(added),
          "deleted" : \(deleted),
          "generated_at" : "\(ts)"
        }
        """
    }

    // MARK: - Cache invalidation

    /// Invalidate the virtual cache and mark a logical path as dirty so its
    /// diff entry will be regenerated on next access. Also invalidates the
    /// `changes` and `status` virtual files (they are cheap to regenerate).
    public func invalidateFile(_ relPath: String) {
        dirtyPaths.insert(relPath)
        // Invalidate the assembled virtual files that depend on all paths
        virtualCache.removeValue(forKey: "diff")
        virtualCache.removeValue(forKey: "changes")
        virtualCache.removeValue(forKey: "status")
    }

    /// Fully invalidate all virtual caches and the per-file diff cache.
    /// Use for operations that affect multiple paths at once (e.g. mkdir, rmdir).
    public func invalidateVirtualCache() {
        virtualCache.removeAll()
        dirtyPaths.removeAll()
        perFileDiffCache.removeAll()
    }

    // MARK: - Private helpers

    private func runDiff(lower lPath: String, upper uPath: String) -> String {
        let proc = Process()
        let diffBin = FileManager.default.fileExists(atPath: "/usr/bin/diff")
            ? "/usr/bin/diff" : "/bin/diff"
        proc.executableURL = URL(fileURLWithPath: diffBin)
        if FileManager.default.fileExists(atPath: lPath) {
            proc.arguments = ["-u", lPath, uPath]
        } else {
            proc.arguments = ["-u", "/dev/null", uPath]
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.standardError
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
