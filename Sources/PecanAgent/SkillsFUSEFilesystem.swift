#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - SkillsFUSEFilesystem

/// COW FUSE filesystem for /skills.
/// Lower layer: populated from server's ~/.pecan/skills/ via SkillsClient (read-only).
/// Upper layer: /tmp/skills-upper/ (writable, for dynamically created skills).
///
/// On configure(), the entire lower layer is loaded into memory.
/// Reads check upper first, fall back to lower cache.
/// Writes/creates go to upper only (COW semantics, with whiteout support for deletions).

actor SkillsFUSEFilesystem: FUSEFilesystem {

    let upperDir: String

    // Lower layer cache: path (e.g. "/" or "/web" or "/web/SKILL.md") -> entries or content
    private var lowerDirs:  [String: [(name: String, isDir: Bool, isExecutable: Bool)]] = [:]
    private var lowerFiles: [String: (content: Data, isExecutable: Bool)] = [:]

    // Inode table (path <-> nodeID)
    private var inodes: [String: UInt64] = ["/": 1]
    private var paths:  [UInt64: String] = [1: "/"]
    private var lookupCounts: [UInt64: UInt64] = [:]
    private var nextInode: UInt64 = 100

    // MARK: - Init

    init(upperDir: String) {
        self.upperDir = upperDir
        try? FileManager.default.createDirectory(atPath: upperDir, withIntermediateDirectories: true)
    }

    // MARK: - Configure (load lower layer from server)

    func configure() async {
        await loadDirFromServer(serverPath: "/", localPath: "/")
    }

    private func loadDirFromServer(serverPath: String, localPath: String) async {
        guard let entries = try? await SkillsClient.shared.listDir(path: serverPath) else { return }
        lowerDirs[localPath] = entries.map { ($0.name, $0.isDir, $0.isExecutable) }
        for entry in entries {
            let childLocalPath = localPath == "/" ? "/\(entry.name)" : "\(localPath)/\(entry.name)"
            let childServerPath = serverPath == "/" ? "/\(entry.name)" : "\(serverPath)/\(entry.name)"
            if entry.isDir {
                await loadDirFromServer(serverPath: childServerPath, localPath: childLocalPath)
            } else {
                if let (data, isExec) = try? await SkillsClient.shared.readFile(path: childServerPath) {
                    lowerFiles[childLocalPath] = (content: data, isExecutable: isExec)
                }
            }
        }
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

    private func nodePath(for id: UInt64) -> String? { paths[id] }

    private func trackLookup(_ id: UInt64) {
        lookupCounts[id] = (lookupCounts[id] ?? 0) + 1
    }

    // MARK: - COW helpers

    private func upperPath(_ relPath: String) -> String {
        relPath == "/" ? upperDir : upperDir + relPath
    }

    private func isWhitedOut(_ name: String, inDir: String) -> Bool {
        let whPath = upperDir + inDir + "/.wh." + name
        return FileManager.default.fileExists(atPath: whPath)
    }

    private func existsInUpper(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: upperPath(relPath))
    }

    private func existsInLower(_ relPath: String) -> Bool {
        lowerDirs[relPath] != nil || lowerFiles[relPath] != nil
    }

    private func isDirectoryInLower(_ relPath: String) -> Bool {
        lowerDirs[relPath] != nil
    }

    private func isDirectoryInUpper(_ relPath: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: upperPath(relPath), isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - Stat helpers

    private func makeAttr(ino: UInt64, mode: UInt32, size: UInt64, nlink: UInt32 = 1) -> FUSEAttr {
        var attr = FUSEAttr()
        attr.ino = ino; attr.size = size
        attr.blocks = (size + 511) / 512
        let now = UInt64(Date().timeIntervalSince1970)
        attr.atime = now; attr.mtime = now; attr.ctime = now
        attr.atimensec = 0; attr.mtimensec = 0; attr.ctimensec = 0
        attr.mode = mode; attr.nlink = nlink
        attr.uid = 0; attr.gid = 0; attr.rdev = 0
        attr.blksize = 4096; attr.padding = 0
        return attr
    }

    private func makeAttrOut(attr: FUSEAttr) -> FUSEAttrOut {
        var out = FUSEAttrOut()
        out.attr_valid = 1; out.attr_valid_nsec = 0; out.dummy = 0; out.attr = attr
        return out
    }

    private func makeEntryOut(nodeID: UInt64, attr: FUSEAttr) -> FUSEEntryOut {
        var out = FUSEEntryOut()
        out.nodeid = nodeID; out.generation = 1
        out.entry_valid = 1; out.attr_valid = 1
        out.entry_valid_nsec = 0; out.attr_valid_nsec = 0
        out.attr = attr
        return out
    }

    private func attrForPath(_ relPath: String, ino: UInt64) -> FUSEAttr? {
        // Check upper first
        let uPath = upperPath(relPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: uPath, isDirectory: &isDir) {
            let mode: UInt32 = isDir.boolValue ? (S_IFDIR | 0o755) : (S_IFREG | 0o644)
            var st = stat()
            if stat(uPath, &st) == 0 {
                var attr = FUSEAttr()
                attr.ino = ino
                attr.size = UInt64(st.st_size)
                attr.blocks = UInt64(st.st_blocks)
                let now = UInt64(Date().timeIntervalSince1970)
                attr.atime = now; attr.mtime = now; attr.ctime = now
                attr.atimensec = 0; attr.mtimensec = 0; attr.ctimensec = 0
                attr.mode = UInt32(st.st_mode)
                attr.nlink = UInt32(st.st_nlink)
                attr.uid = 0; attr.gid = 0; attr.rdev = 0
                attr.blksize = 4096; attr.padding = 0
                return attr
            }
            return makeAttr(ino: ino, mode: mode, size: 0)
        }
        // Fall back to lower
        if let dirEntries = lowerDirs[relPath] {
            _ = dirEntries
            return makeAttr(ino: ino, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
        }
        if let (data, isExec) = lowerFiles[relPath] {
            let mode: UInt32 = isExec ? (S_IFREG | 0o755) : (S_IFREG | 0o644)
            return makeAttr(ino: ino, mode: mode, size: UInt64(data.count))
        }
        return nil
    }

    // MARK: - FUSEFilesystem: lookup

    func lookup(parent: UInt64, name: String) async -> Result<FUSEEntryOut, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let dirPart = parentPath

        // Check whiteout
        if isWhitedOut(name, inDir: dirPart) { return .failure(FUSEErrno(-ENOENT)) }

        let id = nodeID(for: relPath)
        guard let attr = attrForPath(relPath, ino: id) else { return .failure(FUSEErrno(-ENOENT)) }
        trackLookup(id)
        return .success(makeEntryOut(nodeID: id, attr: attr))
    }

    // MARK: - FUSEFilesystem: getattr

    func getattr(nodeID id: UInt64) async -> Result<FUSEAttrOut, FUSEErrno> {
        if id == 1 { // root
            let attr = makeAttr(ino: 1, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))
        }
        guard let relPath = nodePath(for: id) else { return .failure(FUSEErrno(-ENOENT)) }
        // Check whiteout for non-root nodes
        let name = (relPath as NSString).lastPathComponent
        let dir = (relPath as NSString).deletingLastPathComponent
        let parentDir = dir.isEmpty ? "/" : dir
        if isWhitedOut(name, inDir: parentDir) { return .failure(FUSEErrno(-ENOENT)) }
        guard let attr = attrForPath(relPath, ino: id) else { return .failure(FUSEErrno(-ENOENT)) }
        return .success(makeAttrOut(attr: attr))
    }

    // MARK: - FUSEFilesystem: setattr

    func setattr(nodeID id: UInt64, valid: UInt32, size: UInt64?, mode: UInt32?) async -> Result<FUSEAttrOut, FUSEErrno> {
        guard let relPath = nodePath(for: id) else { return .failure(FUSEErrno(-ENOENT)) }
        if let newSize = size, (valid & FATTR_SIZE) != 0 {
            let uPath = upperPath(relPath)
            // COW copy if not in upper
            if !FileManager.default.fileExists(atPath: uPath), let (data, _) = lowerFiles[relPath] {
                let dir = (uPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: uPath, contents: data)
            }
            if let fh = FileHandle(forWritingAtPath: uPath) {
                fh.truncateFile(atOffset: newSize)
                fh.closeFile()
            }
        }
        if let newMode = mode, (valid & FATTR_MODE) != 0 {
            let uPath = upperPath(relPath)
            _ = chmod(uPath, mode_t(newMode))
        }
        return await getattr(nodeID: id)
    }

    // MARK: - FUSEFilesystem: opendir

    func opendir(nodeID id: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        .success(id)
    }

    // MARK: - FUSEFilesystem: readdir

    func readdir(nodeID id: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        guard let relPath = nodePath(for: id) else { return .failure(FUSEErrno(-ENOENT)) }

        var entries: [(name: String, ino: UInt64, type: UInt32)] = []
        entries.append((".", id, DT_DIR))
        let parentID: UInt64
        if relPath == "/" {
            parentID = 1
        } else {
            let parentPath = (relPath as NSString).deletingLastPathComponent
            parentID = nodeID(for: parentPath.isEmpty ? "/" : parentPath)
        }
        entries.append(("..", parentID, DT_DIR))

        // Collect union of upper + lower entries (respecting whiteouts)
        var names = Set<String>()
        var whiteouts = Set<String>()

        let uDirPath = upperPath(relPath)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: uDirPath) {
            for item in items {
                if item.hasPrefix(".wh.") { whiteouts.insert(String(item.dropFirst(4))) }
                else { names.insert(item) }
            }
        }

        if let lowerEntries = lowerDirs[relPath] {
            for entry in lowerEntries { names.insert(entry.name) }
        }

        names.subtract(whiteouts)

        for name in names.sorted() {
            let childPath = relPath == "/" ? "/\(name)" : "\(relPath)/\(name)"
            let childID = nodeID(for: childPath)
            // Determine type
            let isDir = isDirectoryInUpper(childPath) || isDirectoryInLower(childPath)
            entries.append((name, childID, isDir ? DT_DIR : DT_REG))
        }

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

    func releasedir(nodeID id: UInt64, fh: UInt64) async { }

    // MARK: - FUSEFilesystem: open

    func open(nodeID id: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        .success(id)
    }

    // MARK: - FUSEFilesystem: read

    func read(nodeID id: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        guard let relPath = nodePath(for: id) else { return .failure(FUSEErrno(-ENOENT)) }

        // Upper takes precedence
        let uPath = upperPath(relPath)
        let filePath: String
        if FileManager.default.fileExists(atPath: uPath) {
            filePath = uPath
        } else if let (data, _) = lowerFiles[relPath] {
            let start = Int(offset)
            guard start < data.count else { return .success(Data()) }
            let end = min(start + Int(size), data.count)
            return .success(data.subdata(in: start..<end))
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

    // MARK: - FUSEFilesystem: write

    func write(nodeID id: UInt64, fh: UInt64, offset: UInt64, data: Data, flags: UInt32) async -> Result<UInt32, FUSEErrno> {
        guard let relPath = nodePath(for: id) else { return .failure(FUSEErrno(-ENOENT)) }
        let uPath = upperPath(relPath)
        let dir = (uPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // COW copy from lower if not already in upper
        if !FileManager.default.fileExists(atPath: uPath), let (lData, _) = lowerFiles[relPath] {
            _ = FileManager.default.createFile(atPath: uPath, contents: lData)
        }
        if !FileManager.default.fileExists(atPath: uPath) {
            _ = FileManager.default.createFile(atPath: uPath, contents: nil)
        }

        guard let fh = FileHandle(forWritingAtPath: uPath) else { return .failure(FUSEErrno(-EIO)) }
        fh.seek(toFileOffset: offset)
        fh.write(data)
        fh.closeFile()
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

        let id = nodeID(for: relPath)
        trackLookup(id)
        let attr = makeAttr(ino: id, mode: S_IFREG | (mode & 0o777), size: 0)
        var openOut = FUSEOpenOut()
        openOut.fh = id; openOut.open_flags = 0; openOut.padding = 0
        return .success((makeEntryOut(nodeID: id, attr: attr), openOut))
    }

    // MARK: - FUSEFilesystem: mkdir

    func mkdir(parent: UInt64, name: String, mode: UInt32) async -> Result<FUSEEntryOut, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let uPath = upperPath(relPath)
        do {
            try FileManager.default.createDirectory(atPath: uPath, withIntermediateDirectories: true)
        } catch { return .failure(FUSEErrno(-EIO)) }

        let whPath = upperDir + parentPath + "/.wh." + name
        try? FileManager.default.removeItem(atPath: whPath)

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
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(relPath)) }
        if inLower {
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: whDir + "/.wh." + name, contents: nil)
        }
        return .success(())
    }

    // MARK: - FUSEFilesystem: rmdir

    func rmdir(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let inUpper = existsInUpper(relPath)
        let inLower = existsInLower(relPath)
        if inUpper { try? FileManager.default.removeItem(atPath: upperPath(relPath)) }
        if inLower {
            let whDir = upperPath(parentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: whDir + "/.wh." + name, contents: nil)
        }
        return .success(())
    }

    // MARK: - FUSEFilesystem: rename

    func rename(oldParent: UInt64, oldName: String, newParent: UInt64, newName: String) async -> Result<Void, FUSEErrno> {
        guard let oldParentPath = nodePath(for: oldParent),
              let newParentPath = nodePath(for: newParent) else { return .failure(FUSEErrno(-ENOENT)) }
        let oldRelPath = oldParentPath == "/" ? "/\(oldName)" : "\(oldParentPath)/\(oldName)"
        let newRelPath = newParentPath == "/" ? "/\(newName)" : "\(newParentPath)/\(newName)"

        // COW copy if only in lower
        if !existsInUpper(oldRelPath), let (data, _) = lowerFiles[oldRelPath] {
            let uPath = upperPath(oldRelPath)
            let dir = (uPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: uPath, contents: data)
        }

        guard existsInUpper(oldRelPath) else { return .failure(FUSEErrno(-ENOENT)) }
        let srcUpper = upperPath(oldRelPath)
        let dstUpper = upperPath(newRelPath)
        let dstDir = (dstUpper as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dstUpper)
        do {
            try FileManager.default.moveItem(atPath: srcUpper, toPath: dstUpper)
        } catch { return .failure(FUSEErrno(-EIO)) }

        if existsInLower(oldRelPath) {
            let whDir = upperPath(oldParentPath)
            try? FileManager.default.createDirectory(atPath: whDir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: whDir + "/.wh." + oldName, contents: nil)
        }

        // Update inode tables
        if let id = inodes.removeValue(forKey: oldRelPath) {
            inodes[newRelPath] = id
            paths[id] = newRelPath
        }
        return .success(())
    }

    // MARK: - FUSEFilesystem: release

    func release(nodeID id: UInt64, fh: UInt64) async { }

    // MARK: - FUSEFilesystem: forget

    func forget(nodeID id: UInt64, nlookup: UInt64) async {
        guard var count = lookupCounts[id] else { return }
        if count <= nlookup {
            lookupCounts.removeValue(forKey: id)
            if id >= 100, let path = paths[id] {
                paths.removeValue(forKey: id)
                inodes.removeValue(forKey: path)
            }
        } else {
            count -= nlookup
            lookupCounts[id] = count
        }
    }
}

#endif // os(Linux)
