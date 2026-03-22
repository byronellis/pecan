#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - COWOverlayFilesystem

actor COWOverlayFilesystem: FUSEFilesystem {

    // MARK: - Fields

    let lowerDir: String
    let upperDir: String

    // Inode mappings: path (relative, e.g. "/") ↔ node ID
    private var inodes: [String: UInt64] = [:]
    private var paths: [UInt64: String] = [:]
    private var lookupCounts: [UInt64: UInt64] = [:]
    private var nextInode: UInt64 = 100

    // Virtual file content cache (invalidated on writes)
    private var virtualCache: [String: Data] = [:]

    // Hardcoded well-known node IDs
    private let rootNodeID: UInt64 = 1
    private let pecanDirNodeID: UInt64 = 2
    private let diffFileNodeID: UInt64 = 3
    private let changesFileNodeID: UInt64 = 4
    private let statusFileNodeID: UInt64 = 5

    // MARK: - Init

    init(lower: String, upper: String) {
        self.lowerDir = lower
        self.upperDir = upper
        // Pre-populate well-known nodes
        inodes["/"] = 1
        paths[1] = "/"
        inodes["/.pecan"] = 2
        paths[2] = "/.pecan"
        inodes["/.pecan/diff"] = 3
        paths[3] = "/.pecan/diff"
        inodes["/.pecan/changes"] = 4
        paths[4] = "/.pecan/changes"
        inodes["/.pecan/status"] = 5
        paths[5] = "/.pecan/status"
    }

    // MARK: - Inode helpers

    private func nodeID(for path: String) -> UInt64 {
        if let id = inodes[path] { return id }
        let id = nextInode
        nextInode += 1
        inodes[path] = id
        paths[id] = path
        return id
    }

    private func nodePath(for id: UInt64) -> String? {
        return paths[id]
    }

    private func trackLookup(_ id: UInt64) {
        lookupCounts[id] = (lookupCounts[id] ?? 0) + 1
    }

    private func invalidateCache() {
        virtualCache.removeAll()
    }

    // MARK: - Path resolution

    private func upperPath(_ relPath: String) -> String {
        if relPath == "/" { return upperDir }
        return upperDir + relPath
    }

    private func lowerPath(_ relPath: String) -> String {
        if relPath == "/" { return lowerDir }
        return lowerDir + relPath
    }

    private func isWhitedOut(_ name: String, inDir: String) -> Bool {
        let whPath = upperDir + inDir + "/.wh." + name
        return FileManager.default.fileExists(atPath: whPath)
    }

    private func existsInUpper(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: upperPath(relPath))
    }

    private func existsInLower(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: lowerPath(relPath))
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Copy from lower to upper if not already in upper. Creates parent dirs.
    private func cowCopy(_ relPath: String) {
        let srcPath = lowerPath(relPath)
        let dstPath = upperPath(relPath)
        guard FileManager.default.fileExists(atPath: srcPath) else { return }
        guard !FileManager.default.fileExists(atPath: dstPath) else { return }
        let dstDir = (dstPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
    }

    // MARK: - Virtual file content

    private func virtualContent(for relPath: String) -> Data? {
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

    private func generateDiff() -> String {
        var parts: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            let fullUpper = upperDir + "/" + rel
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullUpper, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let fileName = (rel as NSString).lastPathComponent
            if fileName.hasPrefix(".wh.") { continue }

            let logicalPath = "/" + rel
            let uPath = upperPath(logicalPath)
            let lPath = lowerPath(logicalPath)

            let proc = Process()
            if FileManager.default.fileExists(atPath: "/usr/bin/diff") {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            } else {
                proc.executableURL = URL(fileURLWithPath: "/bin/diff")
            }
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

    private func generateChanges() -> String {
        var lines: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: upperDir) else { return "" }
        while let rel = enumerator.nextObject() as? String {
            let fullUpper = upperDir + "/" + rel
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullUpper, isDirectory: &isDir)
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

    private func generateStatus() -> String {
        let changesText = generateChanges()
        let lines = changesText.isEmpty ? [] : changesText.components(separatedBy: "\n")
        let modified = lines.filter { $0.hasPrefix("M") }.count
        let added    = lines.filter { $0.hasPrefix("A") }.count
        let deleted  = lines.filter { $0.hasPrefix("D") }.count
        let dict: [String: Any] = [
            "session_id": "overlay",
            "modified": modified,
            "added": added,
            "deleted": deleted,
            "generated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Stat helpers

    private func makeAttr(ino: UInt64, mode: UInt32, size: UInt64, nlink: UInt32 = 1) -> FUSEAttr {
        var attr = FUSEAttr()
        attr.ino = ino
        attr.size = size
        attr.blocks = (size + 511) / 512
        let now = UInt64(Date().timeIntervalSince1970)
        attr.atime = now
        attr.mtime = now
        attr.ctime = now
        attr.atimensec = 0
        attr.mtimensec = 0
        attr.ctimensec = 0
        attr.mode = mode
        attr.nlink = nlink
        attr.uid = 0
        attr.gid = 0
        attr.rdev = 0
        attr.blksize = 4096
        attr.padding = 0
        return attr
    }

    private func statToAttr(ino: UInt64, path: String) -> FUSEAttr? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        var attr = FUSEAttr()
        attr.ino = ino
        attr.size = UInt64(st.st_size)
        attr.blocks = UInt64(st.st_blocks)
        attr.atime = UInt64(st.st_atim.tv_sec)
        attr.mtime = UInt64(st.st_mtim.tv_sec)
        attr.ctime = UInt64(st.st_ctim.tv_sec)
        attr.atimensec = UInt32(st.st_atim.tv_nsec)
        attr.mtimensec = UInt32(st.st_mtim.tv_nsec)
        attr.ctimensec = UInt32(st.st_ctim.tv_nsec)
        attr.mode = UInt32(st.st_mode)
        attr.nlink = UInt32(st.st_nlink)
        attr.uid = st.st_uid
        attr.gid = st.st_gid
        attr.rdev = UInt32(st.st_rdev)
        attr.blksize = UInt32(st.st_blksize)
        attr.padding = 0
        return attr
    }

    private func makeAttrOut(attr: FUSEAttr) -> FUSEAttrOut {
        var out = FUSEAttrOut()
        out.attr_valid = 1
        out.attr_valid_nsec = 0
        out.dummy = 0
        out.attr = attr
        return out
    }

    private func makeEntryOut(nodeID: UInt64, attr: FUSEAttr) -> FUSEEntryOut {
        var out = FUSEEntryOut()
        out.nodeid = nodeID
        out.generation = 1
        out.entry_valid = 1
        out.attr_valid = 1
        out.entry_valid_nsec = 0
        out.attr_valid_nsec = 0
        out.attr = attr
        return out
    }

    // MARK: - FUSEFilesystem: lookup

    func lookup(parent: UInt64, name: String) async -> Result<FUSEEntryOut, FUSEErrno> {
        // Root → .pecan
        if parent == rootNodeID && name == ".pecan" {
            let attr = makeAttr(ino: pecanDirNodeID, mode: S_IFDIR | 0o555, size: 0, nlink: 2)
            trackLookup(pecanDirNodeID)
            return .success(makeEntryOut(nodeID: pecanDirNodeID, attr: attr))
        }

        // .pecan dir → virtual files
        if parent == pecanDirNodeID {
            switch name {
            case "diff":
                let data = virtualContent(for: "/.pecan/diff") ?? Data()
                let attr = makeAttr(ino: diffFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(diffFileNodeID)
                return .success(makeEntryOut(nodeID: diffFileNodeID, attr: attr))
            case "changes":
                let data = virtualContent(for: "/.pecan/changes") ?? Data()
                let attr = makeAttr(ino: changesFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(changesFileNodeID)
                return .success(makeEntryOut(nodeID: changesFileNodeID, attr: attr))
            case "status":
                let data = virtualContent(for: "/.pecan/status") ?? Data()
                let attr = makeAttr(ino: statusFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(statusFileNodeID)
                return .success(makeEntryOut(nodeID: statusFileNodeID, attr: attr))
            default:
                return .failure(FUSEErrno(-ENOENT))
            }
        }

        // Get parent path
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let dirPart = parentPath

        // Check whiteout in upper
        if isWhitedOut(name, inDir: dirPart) { return .failure(FUSEErrno(-ENOENT)) }

        // Check upper
        let uPath = upperPath(relPath)
        if FileManager.default.fileExists(atPath: uPath) {
            let id = nodeID(for: relPath)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: uPath, isDirectory: &isDir)
            let attr: FUSEAttr
            if let a = statToAttr(ino: id, path: uPath) {
                attr = a
            } else {
                let mode: UInt32 = isDir.boolValue ? (S_IFDIR | 0o755) : (S_IFREG | 0o644)
                attr = makeAttr(ino: id, mode: mode, size: 0)
            }
            trackLookup(id)
            return .success(makeEntryOut(nodeID: id, attr: attr))
        }

        // Check lower
        let lPath = lowerPath(relPath)
        if FileManager.default.fileExists(atPath: lPath) {
            let id = nodeID(for: relPath)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: lPath, isDirectory: &isDir)
            let attr: FUSEAttr
            if let a = statToAttr(ino: id, path: lPath) {
                attr = a
            } else {
                let mode: UInt32 = isDir.boolValue ? (S_IFDIR | 0o755) : (S_IFREG | 0o644)
                attr = makeAttr(ino: id, mode: mode, size: 0)
            }
            trackLookup(id)
            return .success(makeEntryOut(nodeID: id, attr: attr))
        }

        return .failure(FUSEErrno(-ENOENT))
    }

    // MARK: - FUSEFilesystem: getattr

    func getattr(nodeID: UInt64) async -> Result<FUSEAttrOut, FUSEErrno> {
        switch nodeID {
        case rootNodeID:
            let attr = makeAttr(ino: rootNodeID, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))

        case pecanDirNodeID:
            let attr = makeAttr(ino: pecanDirNodeID, mode: S_IFDIR | 0o555, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))

        case diffFileNodeID:
            let data = virtualContent(for: "/.pecan/diff") ?? Data()
            let attr = makeAttr(ino: diffFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
            return .success(makeAttrOut(attr: attr))

        case changesFileNodeID:
            let data = virtualContent(for: "/.pecan/changes") ?? Data()
            let attr = makeAttr(ino: changesFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
            return .success(makeAttrOut(attr: attr))

        case statusFileNodeID:
            let data = virtualContent(for: "/.pecan/status") ?? Data()
            let attr = makeAttr(ino: statusFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
            return .success(makeAttrOut(attr: attr))

        default:
            guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

            // Check whiteout
            let name = (relPath as NSString).lastPathComponent
            let dir = (relPath as NSString).deletingLastPathComponent
            let parentDir = dir.isEmpty ? "/" : dir
            if relPath != "/" && isWhitedOut(name, inDir: parentDir) { return .failure(FUSEErrno(-ENOENT)) }

            // Check upper
            let uPath = upperPath(relPath)
            if let attr = statToAttr(ino: nodeID, path: uPath) {
                return .success(makeAttrOut(attr: attr))
            }

            // Check lower
            let lPath = lowerPath(relPath)
            if let attr = statToAttr(ino: nodeID, path: lPath) {
                return .success(makeAttrOut(attr: attr))
            }

            return .failure(FUSEErrno(-ENOENT))
        }
    }

    // MARK: - FUSEFilesystem: setattr

    func setattr(nodeID: UInt64, valid: UInt32, size: UInt64?, mode: UInt32?) async -> Result<FUSEAttrOut, FUSEErrno> {
        // Virtual files are read-only
        if nodeID == diffFileNodeID || nodeID == changesFileNodeID || nodeID == statusFileNodeID {
            return .failure(FUSEErrno(-EROFS))
        }
        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

        if let newSize = size, (valid & FATTR_SIZE) != 0 {
            // COW copy if needed
            cowCopy(relPath)
            let uPath = upperPath(relPath)
            guard let fh = FileHandle(forWritingAtPath: uPath) else {
                // If file doesn't exist in upper and not in lower, error
                if !FileManager.default.fileExists(atPath: uPath) {
                    return .failure(FUSEErrno(-ENOENT))
                }
                return .failure(FUSEErrno(-EIO))
            }
            fh.truncateFile(atOffset: newSize)
            fh.closeFile()
            invalidateCache()
        }

        if let newMode = mode, (valid & FATTR_MODE) != 0 {
            cowCopy(relPath)
            let uPath = upperPath(relPath)
            _ = chmod(uPath, mode_t(newMode))
        }

        // Return updated attrs
        return await getattr(nodeID: nodeID)
    }

    // MARK: - FUSEFilesystem: opendir

    func opendir(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        // Just return a dummy file handle
        return .success(UInt64(nodeID))
    }

    // MARK: - FUSEFilesystem: readdir

    func readdir(nodeID: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        var entries: [(name: String, ino: UInt64, type: UInt32)] = []

        if nodeID == pecanDirNodeID {
            entries = [
                (".", pecanDirNodeID, DT_DIR),
                ("..", rootNodeID, DT_DIR),
                ("diff", diffFileNodeID, DT_REG),
                ("changes", changesFileNodeID, DT_REG),
                ("status", statusFileNodeID, DT_REG),
            ]
        } else {
            guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

            entries.append((".", nodeID, DT_DIR))
            let parentNodeID: UInt64
            if relPath == "/" {
                parentNodeID = rootNodeID
            } else {
                let parentPath = (relPath as NSString).deletingLastPathComponent
                parentNodeID = self.nodeID(for: parentPath.isEmpty ? "/" : parentPath)
            }
            entries.append(("..", parentNodeID, DT_DIR))

            // Collect union of upper + lower entries
            var names = Set<String>()
            var whiteouts = Set<String>()

            let uDirPath = upperPath(relPath)
            if let items = try? FileManager.default.contentsOfDirectory(atPath: uDirPath) {
                for item in items {
                    if item.hasPrefix(".wh.") {
                        whiteouts.insert(String(item.dropFirst(4)))
                    } else {
                        names.insert(item)
                    }
                }
            }

            let lDirPath = lowerPath(relPath)
            if let items = try? FileManager.default.contentsOfDirectory(atPath: lDirPath) {
                for item in items {
                    names.insert(item)
                }
            }

            names.subtract(whiteouts)

            // Inject .pecan at root
            if relPath == "/" {
                names.insert(".pecan")
            }

            for name in names.sorted() {
                let childPath = relPath == "/" ? "/\(name)" : "\(relPath)/\(name)"
                let childID: UInt64
                if name == ".pecan" {
                    childID = pecanDirNodeID
                } else {
                    childID = self.nodeID(for: childPath)
                }

                // Determine type
                var fileType = DT_REG
                let uChild = upperPath(childPath)
                let lChild = lowerPath(childPath)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: uChild, isDirectory: &isDir) {
                    fileType = isDir.boolValue ? DT_DIR : DT_REG
                } else if FileManager.default.fileExists(atPath: lChild, isDirectory: &isDir) {
                    fileType = isDir.boolValue ? DT_DIR : DT_REG
                } else if name == ".pecan" {
                    fileType = DT_DIR
                }

                entries.append((name, childID, fileType))
            }
        }

        // Build dirent data, respecting offset
        var result = Data()
        for (idx, entry) in entries.enumerated() {
            let entryOffset = UInt64(idx)
            if entryOffset < offset { continue }
            let dirent = buildDirent(ino: entry.ino, offset: entryOffset + 1, type: entry.type, name: entry.name)
            if result.count + dirent.count > Int(size) { break }
            result.append(dirent)
        }
        return .success(result)
    }

    // MARK: - FUSEFilesystem: releasedir

    func releasedir(nodeID: UInt64, fh: UInt64) async {
        // Nothing to do
    }

    // MARK: - FUSEFilesystem: open

    func open(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        return .success(UInt64(nodeID))
    }

    // MARK: - FUSEFilesystem: read

    func read(nodeID: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        // Virtual files
        switch nodeID {
        case diffFileNodeID:
            return serveVirtualFile("/.pecan/diff", offset: offset, size: size)
        case changesFileNodeID:
            return serveVirtualFile("/.pecan/changes", offset: offset, size: size)
        case statusFileNodeID:
            return serveVirtualFile("/.pecan/status", offset: offset, size: size)
        default:
            break
        }

        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

        // Try upper first, then lower
        let uPath = upperPath(relPath)
        let lPath = lowerPath(relPath)

        let filePath: String
        if FileManager.default.fileExists(atPath: uPath) {
            filePath = uPath
        } else if FileManager.default.fileExists(atPath: lPath) {
            filePath = lPath
        } else {
            return .failure(FUSEErrno(-ENOENT))
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return .failure(FUSEErrno(-EIO))
        }

        let start = Int(offset)
        guard start < data.count else { return .success(Data()) }
        let end = min(start + Int(size), data.count)
        return .success(data.subdata(in: start..<end))
    }

    private func serveVirtualFile(_ relPath: String, offset: UInt64, size: UInt32) -> Result<Data, FUSEErrno> {
        guard let data = virtualContent(for: relPath) else { return .failure(FUSEErrno(-ENOENT)) }
        let start = Int(offset)
        guard start < data.count else { return .success(Data()) }
        let end = min(start + Int(size), data.count)
        return .success(data.subdata(in: start..<end))
    }

    // MARK: - FUSEFilesystem: write

    func write(nodeID: UInt64, fh: UInt64, offset: UInt64, data: Data, flags: UInt32) async -> Result<UInt32, FUSEErrno> {
        // Virtual files are read-only
        if nodeID == diffFileNodeID || nodeID == changesFileNodeID || nodeID == statusFileNodeID {
            return .failure(FUSEErrno(-EROFS))
        }
        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

        // COW copy if needed
        cowCopy(relPath)

        let uPath = upperPath(relPath)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create file if not exists
        if !FileManager.default.fileExists(atPath: uPath) {
            FileManager.default.createFile(atPath: uPath, contents: nil)
        }

        guard let fh = FileHandle(forWritingAtPath: uPath) else { return .failure(FUSEErrno(-EIO)) }
        fh.seek(toFileOffset: offset)
        fh.write(data)
        fh.closeFile()

        invalidateCache()
        return .success(UInt32(data.count))
    }

    // MARK: - FUSEFilesystem: create

    func create(parent: UInt64, name: String, mode: UInt32, flags: UInt32) async -> Result<(FUSEEntryOut, FUSEOpenOut), FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let uPath = upperPath(relPath)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: uPath, contents: nil) else { return .failure(FUSEErrno(-EIO)) }

        // Remove whiteout if one existed
        let whPath = upperDir + parentPath + "/.wh." + name
        try? FileManager.default.removeItem(atPath: whPath)

        invalidateCache()

        let id = nodeID(for: relPath)
        trackLookup(id)
        let attr = makeAttr(ino: id, mode: S_IFREG | (mode & 0o777), size: 0)
        var openOut = FUSEOpenOut()
        openOut.fh = UInt64(id)
        openOut.open_flags = 0
        openOut.padding = 0
        return .success((makeEntryOut(nodeID: id, attr: attr), openOut))
    }

    // MARK: - FUSEFilesystem: mkdir

    func mkdir(parent: UInt64, name: String, mode: UInt32) async -> Result<FUSEEntryOut, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let uPath = upperPath(relPath)
        do {
            try FileManager.default.createDirectory(atPath: uPath, withIntermediateDirectories: true)
        } catch {
            return .failure(FUSEErrno(-EIO))
        }

        // Remove whiteout if one existed
        let whPath = upperDir + parentPath + "/.wh." + name
        try? FileManager.default.removeItem(atPath: whPath)

        invalidateCache()

        let id = nodeID(for: relPath)
        trackLookup(id)
        let attr = makeAttr(ino: id, mode: S_IFDIR | (mode & 0o777), size: 0, nlink: 2)
        return .success(makeEntryOut(nodeID: id, attr: attr))
    }

    // MARK: - FUSEFilesystem: unlink

    func unlink(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"

        let inUpper = existsInUpper(relPath)
        let inLower = existsInLower(relPath)

        if inUpper {
            try? FileManager.default.removeItem(atPath: upperPath(relPath))
        }
        if inLower {
            // Create whiteout
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            let whPath = whDir + "/.wh." + name
            FileManager.default.createFile(atPath: whPath, contents: nil)
        }

        invalidateCache()
        return .success(())
    }

    // MARK: - FUSEFilesystem: rmdir

    func rmdir(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"

        let inUpper = existsInUpper(relPath)
        let inLower = existsInLower(relPath)

        if inUpper {
            try? FileManager.default.removeItem(atPath: upperPath(relPath))
        }
        if inLower {
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            let whPath = whDir + "/.wh." + name
            FileManager.default.createFile(atPath: whPath, contents: nil)
        }

        invalidateCache()
        return .success(())
    }

    // MARK: - FUSEFilesystem: rename

    func rename(oldParent: UInt64, oldName: String, newParent: UInt64, newName: String) async -> Result<Void, FUSEErrno> {
        guard let oldParentPath = nodePath(for: oldParent),
              let newParentPath = nodePath(for: newParent) else { return .failure(FUSEErrno(-ENOENT)) }

        let oldRelPath = oldParentPath == "/" ? "/\(oldName)" : "\(oldParentPath)/\(oldName)"
        let newRelPath = newParentPath == "/" ? "/\(newName)" : "\(newParentPath)/\(newName)"

        // COW copy source if in lower
        cowCopy(oldRelPath)

        guard existsInUpper(oldRelPath) else { return .failure(FUSEErrno(-ENOENT)) }

        let srcUpper = upperPath(oldRelPath)
        let dstUpper = upperPath(newRelPath)
        let dstDir = (dstUpper as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dstUpper)

        do {
            try FileManager.default.moveItem(atPath: srcUpper, toPath: dstUpper)
        } catch {
            return .failure(FUSEErrno(-EIO))
        }

        // Whiteout source if it existed in lower
        if existsInLower(oldRelPath) {
            let whDir = upperPath(oldParentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            let whPath = whDir + "/.wh." + oldName
            FileManager.default.createFile(atPath: whPath, contents: nil)
        }

        invalidateCache()
        return .success(())
    }

    // MARK: - FUSEFilesystem: release

    func release(nodeID: UInt64, fh: UInt64) async {
        // Nothing to do — files are opened/closed per-operation
    }

    // MARK: - FUSEFilesystem: forget

    func forget(nodeID: UInt64, nlookup: UInt64) async {
        guard var count = lookupCounts[nodeID] else { return }
        if count <= nlookup {
            lookupCounts.removeValue(forKey: nodeID)
            // Only clean up dynamic inodes (not well-known ones)
            if nodeID >= 100, let path = paths[nodeID] {
                paths.removeValue(forKey: nodeID)
                inodes.removeValue(forKey: path)
            }
        } else {
            count -= nlookup
            lookupCounts[nodeID] = count
        }
    }
}

#endif // os(Linux)
