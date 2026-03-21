import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

/// Copy-on-write overlay FUSE filesystem.
///
/// Merges a read-only lower layer (project directory) with a writable upper layer
/// (per-session scratch). Writes trigger copy-on-write from lower to upper.
/// Deletions are represented by whiteout sentinel files (.wh.<name>).
///
/// Virtual /.pecan/ directory provides:
///   /.pecan/diff     - unified diff of all changes (lower vs upper)
///   /.pecan/changes  - [A|M|D] <path> list of changed paths
///   /.pecan/status   - JSON summary
final class OverlayFilesystem: PecanFuseFS {

    let lowerDir: String   // host project directory (read-only source)
    let upperDir: String   // writable scratch (.run/overlay/<sessionID>)
    let sessionID: String

    // Write-invalidated cache for virtual file content
    private var virtualCache: [String: Data] = [:]

    init(lowerDir: String, upperDir: String, sessionID: String) {
        self.lowerDir = lowerDir
        self.upperDir = upperDir
        self.sessionID = sessionID
        try? FileManager.default.createDirectory(atPath: upperDir, withIntermediateDirectories: true)
    }

    // MARK: - Path helpers

    private func lowerPath(_ path: String) -> String { lowerDir + path }
    private func upperPath(_ path: String) -> String { upperDir + path }

    private func whiteoutPath(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        return upperDir + dir + "/.wh." + file
    }

    private func isWhitedOut(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: whiteoutPath(for: path))
    }

    private func existsInUpper(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: upperPath(path))
    }

    private func existsInLower(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: lowerPath(path))
    }

    // MARK: - Virtual paths

    private func isVirtualDir(_ path: String) -> Bool { path == "/.pecan" }
    private func isVirtualFile(_ path: String) -> Bool { path.hasPrefix("/.pecan/") }
    private let virtualFileNames = ["diff", "changes", "status"]

    private func virtualContent(_ name: String) -> Data {
        if let cached = virtualCache[name] { return cached }
        let data: Data
        switch name {
        case "diff":    data = Data(generateDiff().utf8)
        case "changes": data = Data(generateChanges().utf8)
        case "status":  data = Data(generateStatus().utf8)
        default:        data = Data()
        }
        virtualCache[name] = data
        return data
    }

    private func invalidateCache() { virtualCache.removeAll() }

    // MARK: - COW

    /// Copy a file from lower to upper, preserving content. Creates parent dirs.
    private func cowCopy(_ path: String) throws {
        let src = lowerPath(path)
        let dst = upperPath(path)
        let dstDir = (dst as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dst) { return }
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    // MARK: - PecanFuseFS: getattr

    func getattr(_ path: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32 {
        stbuf.pointee = stat()

        // Virtual directory
        if isVirtualDir(path) {
            stbuf.pointee.st_mode = S_IFDIR | 0o555
            stbuf.pointee.st_nlink = 2
            return 0
        }

        // Virtual files
        if isVirtualFile(path) {
            let name = String(path.dropFirst("/.pecan/".count))
            guard virtualFileNames.contains(name) else { return -ENOENT }
            let data = virtualContent(name)
            stbuf.pointee.st_mode = S_IFREG | 0o444
            stbuf.pointee.st_nlink = 1
            stbuf.pointee.st_size = off_t(data.count)
            return 0
        }

        // Whited out?
        if path != "/" && isWhitedOut(path) { return -ENOENT }

        // Upper layer
        let uPath = upperPath(path)
        if FileManager.default.fileExists(atPath: uPath) {
            return statFile(uPath, stbuf)
        }

        // Lower layer
        let lPath = lowerPath(path)
        if FileManager.default.fileExists(atPath: lPath) {
            return statFile(lPath, stbuf)
        }

        return -ENOENT
    }

    private func statFile(_ fullPath: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32 {
        // Use lstat so symlinks are stat'd directly (not followed), matching overlay semantics.
        // lstat is unambiguous in Swift (unlike stat which shadows the struct type).
        var st = stat()
        guard lstat(fullPath, &st) == 0 else { return -ENOENT }
        stbuf.pointee = st
        return 0
    }

    // MARK: - PecanFuseFS: readdir

    func readdir(_ path: String, buf: UnsafeMutableRawPointer?, filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32 {
        pecan_fuse_fill(filler, buf, ".")
        pecan_fuse_fill(filler, buf, "..")

        if isVirtualDir(path) {
            for name in virtualFileNames { pecan_fuse_fill(filler, buf, name) }
            return 0
        }

        var entries = Set<String>()

        // Lower layer entries
        if let items = try? FileManager.default.contentsOfDirectory(atPath: lowerPath(path)) {
            for item in items { entries.insert(item) }
        }

        // Upper layer entries (add new, track whiteouts for removal)
        var whiteouts = Set<String>()
        if let items = try? FileManager.default.contentsOfDirectory(atPath: upperPath(path)) {
            for item in items {
                if item.hasPrefix(".wh.") {
                    let target = String(item.dropFirst(4))
                    whiteouts.insert(target)
                } else {
                    entries.insert(item)
                }
            }
        }

        // Remove whited-out entries
        entries.subtract(whiteouts)

        // Inject virtual .pecan at root
        if path == "/" { entries.insert(".pecan") }

        for entry in entries.sorted() { pecan_fuse_fill(filler, buf, entry) }
        return 0
    }

    // MARK: - PecanFuseFS: read

    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?, size: Int, offset: off_t) -> Int32 {
        guard let buf else { return -EIO }

        let data: Data

        if isVirtualFile(path) {
            let name = String(path.dropFirst("/.pecan/".count))
            guard virtualFileNames.contains(name) else { return -ENOENT }
            data = virtualContent(name)
        } else if FileManager.default.fileExists(atPath: upperPath(path)) {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: upperPath(path))) else { return -EIO }
            data = d
        } else if !isWhitedOut(path), FileManager.default.fileExists(atPath: lowerPath(path)) {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: lowerPath(path))) else { return -EIO }
            data = d
        } else {
            return -ENOENT
        }

        let fileSize = data.count
        guard offset < off_t(fileSize) else { return 0 }
        let available = fileSize - Int(offset)
        let toRead = min(size, available)
        data.withUnsafeBytes { ptr in
            buf.withMemoryRebound(to: UInt8.self, capacity: toRead) { dst in
                dst.update(from: ptr.baseAddress!.advanced(by: Int(offset)).assumingMemoryBound(to: UInt8.self), count: toRead)
            }
        }
        return Int32(toRead)
    }

    // MARK: - PecanFuseFS: write

    func write(_ path: String, buf: UnsafePointer<CChar>?, size: Int, offset: off_t) -> Int32 {
        guard let buf else { return -EIO }
        invalidateCache()

        // COW if needed
        if existsInLower(path) && !existsInUpper(path) {
            guard (try? cowCopy(path)) != nil else { return -EIO }
        }

        let uPath = upperPath(path)
        // Ensure parent exists
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let fh = FileHandle(forWritingAtPath: uPath) else { return -EIO }
        defer { fh.closeFile() }
        fh.seek(toFileOffset: UInt64(offset))
        let data = Data(bytes: buf, count: size)
        fh.write(data)
        return Int32(size)
    }

    // MARK: - PecanFuseFS: create

    func create(_ path: String, mode: mode_t) -> Int32 {
        invalidateCache()
        let uPath = upperPath(path)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: uPath, contents: nil) else { return -EIO }
        // Remove whiteout if one existed
        let wh = whiteoutPath(for: path)
        try? FileManager.default.removeItem(atPath: wh)
        return 0
    }

    // MARK: - PecanFuseFS: truncate

    func truncate(_ path: String, size: off_t) -> Int32 {
        invalidateCache()
        if existsInLower(path) && !existsInUpper(path) {
            guard (try? cowCopy(path)) != nil else { return -EIO }
        }
        let uPath = upperPath(path)
        guard FileManager.default.fileExists(atPath: uPath) else { return -ENOENT }
        guard let fh = FileHandle(forWritingAtPath: uPath) else { return -EIO }
        defer { fh.closeFile() }
        fh.truncateFile(atOffset: UInt64(size))
        return 0
    }

    // MARK: - PecanFuseFS: unlink

    func unlink(_ path: String) -> Int32 {
        invalidateCache()
        let inUpper = existsInUpper(path)
        let inLower = existsInLower(path)
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(path)) }
        if inLower {
            // Create whiteout
            let wh = whiteoutPath(for: path)
            let whDir = (wh as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: wh, contents: nil)
        }
        return 0
    }

    // MARK: - PecanFuseFS: mkdir

    func mkdir(_ path: String, mode: mode_t) -> Int32 {
        invalidateCache()
        let uPath = upperPath(path)
        do {
            try FileManager.default.createDirectory(atPath: uPath, withIntermediateDirectories: true)
            // Remove whiteout if one existed
            let wh = whiteoutPath(for: path)
            try? FileManager.default.removeItem(atPath: wh)
            return 0
        } catch { return -EIO }
    }

    // MARK: - PecanFuseFS: rmdir

    func rmdir(_ path: String) -> Int32 {
        invalidateCache()
        let inUpper = existsInUpper(path)
        let inLower = existsInLower(path)
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(path)) }
        if inLower {
            let wh = whiteoutPath(for: path)
            let whDir = (wh as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: wh, contents: nil)
        }
        return 0
    }

    // MARK: - PecanFuseFS: rename

    func rename(from: String, to: String) -> Int32 {
        invalidateCache()
        // Ensure source is in upper (COW if needed)
        if existsInLower(from) && !existsInUpper(from) {
            guard (try? cowCopy(from)) != nil else { return -EIO }
        }
        guard existsInUpper(from) else { return -ENOENT }

        let srcPath = upperPath(from)
        let dstPath = upperPath(to)
        let dstDir = (dstPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dstPath)
        guard (try? FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)) != nil else { return -EIO }

        // Whiteout the source if it existed in lower
        if existsInLower(from) {
            let wh = whiteoutPath(for: from)
            let whDir = (wh as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: wh, contents: nil)
        }
        return 0
    }

    // MARK: - Virtual content generation

    private func generateChanges() -> String {
        var lines: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            // Skip directory entries (only process files)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: upperDir + "/" + rel, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let fileName = (rel as NSString).lastPathComponent
            if fileName.hasPrefix(".wh.") {
                // Deletion whiteout
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

    private func generateDiff() -> String {
        var parts: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: upperDir + "/" + rel, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let fileName = (rel as NSString).lastPathComponent
            if fileName.hasPrefix(".wh.") { continue } // skip whiteouts in diff

            let logicalPath = "/" + rel
            let uPath = upperPath(logicalPath)
            let lPath = lowerPath(logicalPath)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
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
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    private func generateStatus() -> String {
        let changesText = generateChanges()
        let lines = changesText.isEmpty ? [] : changesText.components(separatedBy: "\n")
        let modified = lines.filter { $0.hasPrefix("M") }.count
        let added    = lines.filter { $0.hasPrefix("A") }.count
        let deleted  = lines.filter { $0.hasPrefix("D") }.count

        let dict: [String: Any] = [
            "session_id": sessionID,
            "modified": modified,
            "added": added,
            "deleted": deleted,
            "total_changes": modified + added + deleted,
            "generated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
