#if os(Linux)
import Foundation
import PecanOverlayCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - COWOverlayFilesystem

/// FUSE filesystem adapter over `COWOverlayCore`.
///
/// Manages inode ↔ path mappings and translates between FUSE protocol types
/// and the platform-agnostic `COWOverlayCore` operations.
actor COWOverlayFilesystem: FUSEFilesystem {

    // MARK: - Fields

    private let core: COWOverlayCore

    // Inode mappings: path (relative, e.g. "/") ↔ node ID
    private var inodes: [String: UInt64] = [:]
    private var paths: [UInt64: String] = [:]
    private var lookupCounts: [UInt64: UInt64] = [:]
    private var nextInode: UInt64 = 100

    // Hardcoded well-known node IDs for virtual paths
    private let rootNodeID: UInt64 = 1
    private let pecanDirNodeID: UInt64 = 2
    private let diffFileNodeID: UInt64 = 3
    private let changesFileNodeID: UInt64 = 4
    private let statusFileNodeID: UInt64 = 5

    // MARK: - Init

    init(lower: String, upper: String) {
        self.core = COWOverlayCore(lower: lower, upper: upper)
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
        paths[id]
    }

    private func trackLookup(_ id: UInt64) {
        lookupCounts[id] = (lookupCounts[id] ?? 0) + 1
    }

    // MARK: - Stat helpers

    private func makeAttr(ino: UInt64, mode: UInt32, size: UInt64, nlink: UInt32 = 1) -> FUSEAttr {
        var attr = FUSEAttr()
        attr.ino = ino
        attr.size = size
        attr.blocks = (size + 511) / 512
        let now = UInt64(Date().timeIntervalSince1970)
        attr.atime = now; attr.mtime = now; attr.ctime = now
        attr.atimensec = 0; attr.mtimensec = 0; attr.ctimensec = 0
        attr.mode = mode
        attr.nlink = nlink
        attr.uid = 0; attr.gid = 0; attr.rdev = 0
        attr.blksize = 4096; attr.padding = 0
        return attr
    }

    private func statToAttr(ino: UInt64, path: String) -> FUSEAttr? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        var attr = FUSEAttr()
        attr.ino = ino
        attr.size = UInt64(st.st_size)
        attr.blocks = UInt64(st.st_blocks)
        attr.atime = UInt64(st.st_atim.tv_sec); attr.mtime = UInt64(st.st_mtim.tv_sec); attr.ctime = UInt64(st.st_ctim.tv_sec)
        attr.atimensec = UInt32(st.st_atim.tv_nsec); attr.mtimensec = UInt32(st.st_mtim.tv_nsec); attr.ctimensec = UInt32(st.st_ctim.tv_nsec)
        attr.mode = UInt32(st.st_mode); attr.nlink = UInt32(st.st_nlink)
        attr.uid = st.st_uid; attr.gid = st.st_gid; attr.rdev = UInt32(st.st_rdev)
        attr.blksize = UInt32(st.st_blksize); attr.padding = 0
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

    // MARK: - FUSEFilesystem: lookup

    func lookup(parent: UInt64, name: String) async -> Result<FUSEEntryOut, FUSEErrno> {
        if parent == rootNodeID && name == ".pecan" {
            let attr = makeAttr(ino: pecanDirNodeID, mode: S_IFDIR | 0o555, size: 0, nlink: 2)
            trackLookup(pecanDirNodeID)
            return .success(makeEntryOut(nodeID: pecanDirNodeID, attr: attr))
        }

        if parent == pecanDirNodeID {
            switch name {
            case "diff":
                let data = await core.virtualContent(for: "/.pecan/diff") ?? Data()
                let attr = makeAttr(ino: diffFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(diffFileNodeID)
                return .success(makeEntryOut(nodeID: diffFileNodeID, attr: attr))
            case "changes":
                let data = await core.virtualContent(for: "/.pecan/changes") ?? Data()
                let attr = makeAttr(ino: changesFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(changesFileNodeID)
                return .success(makeEntryOut(nodeID: changesFileNodeID, attr: attr))
            case "status":
                let data = await core.virtualContent(for: "/.pecan/status") ?? Data()
                let attr = makeAttr(ino: statusFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))
                trackLookup(statusFileNodeID)
                return .success(makeEntryOut(nodeID: statusFileNodeID, attr: attr))
            default:
                return .failure(FUSEErrno(-ENOENT))
            }
        }

        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let dirPart = parentPath

        if await core.isWhitedOut(name, inDir: dirPart) { return .failure(FUSEErrno(-ENOENT)) }

        let uPath = await core.upperPath(relPath)
        if FileManager.default.fileExists(atPath: uPath) {
            let id = nodeID(for: relPath)
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: uPath, isDirectory: &isDir)
            let attr: FUSEAttr
            if let a = statToAttr(ino: id, path: uPath) { attr = a }
            else {
                let mode: UInt32 = isDir.boolValue ? (S_IFDIR | 0o755) : (S_IFREG | 0o644)
                attr = makeAttr(ino: id, mode: mode, size: 0)
            }
            trackLookup(id)
            return .success(makeEntryOut(nodeID: id, attr: attr))
        }

        let lPath = await core.lowerPath(relPath)
        if FileManager.default.fileExists(atPath: lPath) {
            let id = nodeID(for: relPath)
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: lPath, isDirectory: &isDir)
            let attr: FUSEAttr
            if let a = statToAttr(ino: id, path: lPath) { attr = a }
            else {
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
            return .success(makeAttrOut(attr: makeAttr(ino: rootNodeID, mode: S_IFDIR | 0o755, size: 0, nlink: 2)))
        case pecanDirNodeID:
            return .success(makeAttrOut(attr: makeAttr(ino: pecanDirNodeID, mode: S_IFDIR | 0o555, size: 0, nlink: 2)))
        case diffFileNodeID:
            let data = await core.virtualContent(for: "/.pecan/diff") ?? Data()
            return .success(makeAttrOut(attr: makeAttr(ino: diffFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))))
        case changesFileNodeID:
            let data = await core.virtualContent(for: "/.pecan/changes") ?? Data()
            return .success(makeAttrOut(attr: makeAttr(ino: changesFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))))
        case statusFileNodeID:
            let data = await core.virtualContent(for: "/.pecan/status") ?? Data()
            return .success(makeAttrOut(attr: makeAttr(ino: statusFileNodeID, mode: S_IFREG | 0o444, size: UInt64(data.count))))
        default:
            guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }
            let name = (relPath as NSString).lastPathComponent
            let dir = (relPath as NSString).deletingLastPathComponent
            let parentDir = dir.isEmpty ? "/" : dir
            if relPath != "/" && await core.isWhitedOut(name, inDir: parentDir) {
                return .failure(FUSEErrno(-ENOENT))
            }
            let uPath = await core.upperPath(relPath)
            if let attr = statToAttr(ino: nodeID, path: uPath) { return .success(makeAttrOut(attr: attr)) }
            let lPath = await core.lowerPath(relPath)
            if let attr = statToAttr(ino: nodeID, path: lPath) { return .success(makeAttrOut(attr: attr)) }
            return .failure(FUSEErrno(-ENOENT))
        }
    }

    // MARK: - FUSEFilesystem: setattr

    func setattr(nodeID: UInt64, valid: UInt32, size: UInt64?, mode: UInt32?) async -> Result<FUSEAttrOut, FUSEErrno> {
        if nodeID == diffFileNodeID || nodeID == changesFileNodeID || nodeID == statusFileNodeID {
            return .failure(FUSEErrno(-EROFS))
        }
        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }

        if let newSize = size, (valid & FATTR_SIZE) != 0 {
            let errno = await core.truncateFile(at: relPath, to: newSize)
            if errno != 0 { return .failure(FUSEErrno(-errno)) }
        }
        if let newMode = mode, (valid & FATTR_MODE) != 0 {
            await core.cowCopy(relPath)
            let uPath = await core.upperPath(relPath)
            _ = chmod(uPath, mode_t(newMode))
        }
        return await getattr(nodeID: nodeID)
    }

    // MARK: - FUSEFilesystem: opendir / readdir / releasedir

    func opendir(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        .success(UInt64(nodeID))
    }

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

            let children = await core.listDirectory(relPath)
            for (name, isDir) in children {
                let childPath = relPath == "/" ? "/\(name)" : "\(relPath)/\(name)"
                let childID: UInt64 = name == ".pecan" ? pecanDirNodeID : self.nodeID(for: childPath)
                entries.append((name, childID, isDir ? DT_DIR : DT_REG))
            }
            // Inject .pecan virtual dir at root
            if relPath == "/" && !children.contains(where: { $0.name == ".pecan" }) {
                entries.append((".pecan", pecanDirNodeID, DT_DIR))
            }
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

    func releasedir(nodeID: UInt64, fh: UInt64) async {}

    // MARK: - FUSEFilesystem: open / read / write / release

    func open(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        .success(UInt64(nodeID))
    }

    func read(nodeID: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        switch nodeID {
        case diffFileNodeID:
            return await serveVirtualFile("/.pecan/diff", offset: offset, size: size)
        case changesFileNodeID:
            return await serveVirtualFile("/.pecan/changes", offset: offset, size: size)
        case statusFileNodeID:
            return await serveVirtualFile("/.pecan/status", offset: offset, size: size)
        default:
            break
        }

        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }
        guard let data = await core.readFile(at: relPath, offset: offset, size: Int(size)) else {
            return .failure(FUSEErrno(-ENOENT))
        }
        return .success(data)
    }

    func write(nodeID: UInt64, fh: UInt64, offset: UInt64, data: Data, flags: UInt32) async -> Result<UInt32, FUSEErrno> {
        if nodeID == diffFileNodeID || nodeID == changesFileNodeID || nodeID == statusFileNodeID {
            return .failure(FUSEErrno(-EROFS))
        }
        guard let relPath = nodePath(for: nodeID) else { return .failure(FUSEErrno(-ENOENT)) }
        let errno = await core.writeFile(at: relPath, offset: offset, data: data)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        return .success(UInt32(data.count))
    }

    func release(nodeID: UInt64, fh: UInt64) async {}

    // MARK: - FUSEFilesystem: create / mkdir / unlink / rmdir / rename

    func create(parent: UInt64, name: String, mode: UInt32, flags: UInt32) async -> Result<(FUSEEntryOut, FUSEOpenOut), FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let errno = await core.createFile(at: relPath, mode: mode)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        let id = nodeID(for: relPath)
        trackLookup(id)
        let attr = makeAttr(ino: id, mode: S_IFREG | (mode & 0o777), size: 0)
        var openOut = FUSEOpenOut()
        openOut.fh = UInt64(id); openOut.open_flags = 0; openOut.padding = 0
        return .success((makeEntryOut(nodeID: id, attr: attr), openOut))
    }

    func mkdir(parent: UInt64, name: String, mode: UInt32) async -> Result<FUSEEntryOut, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let errno = await core.createDirectory(at: relPath, mode: mode)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        let id = nodeID(for: relPath)
        trackLookup(id)
        let attr = makeAttr(ino: id, mode: S_IFDIR | (mode & 0o777), size: 0, nlink: 2)
        return .success(makeEntryOut(nodeID: id, attr: attr))
    }

    func unlink(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let errno = await core.deleteFile(at: relPath)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        return .success(())
    }

    func rmdir(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard let parentPath = nodePath(for: parent) else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let errno = await core.deleteDirectory(at: relPath)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        return .success(())
    }

    func rename(oldParent: UInt64, oldName: String, newParent: UInt64, newName: String) async -> Result<Void, FUSEErrno> {
        guard let oldParentPath = nodePath(for: oldParent),
              let newParentPath = nodePath(for: newParent) else { return .failure(FUSEErrno(-ENOENT)) }
        let oldRelPath = oldParentPath == "/" ? "/\(oldName)" : "\(oldParentPath)/\(oldName)"
        let newRelPath = newParentPath == "/" ? "/\(newName)" : "\(newParentPath)/\(newName)"
        let errno = await core.rename(from: oldRelPath, to: newRelPath)
        if errno != 0 { return .failure(FUSEErrno(-errno)) }
        return .success(())
    }

    // MARK: - FUSEFilesystem: forget

    func forget(nodeID: UInt64, nlookup: UInt64) async {
        guard var count = lookupCounts[nodeID] else { return }
        if count <= nlookup {
            lookupCounts.removeValue(forKey: nodeID)
            if nodeID >= 100, let path = paths[nodeID] {
                paths.removeValue(forKey: nodeID)
                inodes.removeValue(forKey: path)
            }
        } else {
            count -= nlookup
            lookupCounts[nodeID] = count
        }
    }

    // MARK: - Private helpers

    private func serveVirtualFile(_ relPath: String, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        guard let data = await core.virtualContent(for: relPath) else { return .failure(FUSEErrno(-ENOENT)) }
        let start = Int(offset)
        guard start < data.count else { return .success(Data()) }
        let end = min(start + Int(size), data.count)
        return .success(data.subdata(in: start..<end))
    }
}

#endif // os(Linux)
