#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - MemoryFUSEFilesystem

/// FUSE filesystem backed by server-side SQLite memory storage via gRPC.
///
/// Mount structure (at /memory):
///   /              — root
///   /CORE.md       — session-scope memories tagged "CORE"
///   /NOTES.md      — session-scope memories tagged "NOTES"
///   /project/      — present if hasProject
///   /project/CORE.md
///   /team/         — present if hasTeam
///   /team/CORE.md
///
/// Reading a file renders all memories for (scope, tag) as <!-- memory:N --> blocks.
/// Truncating then writing replaces memories (applyMemoryDiff).
/// Writing without truncation appends a new memory entry (appendTag).
/// Creating a new .md file creates an empty tag (first write populates it).
/// Renaming a .md file renames the tag across all memories.
/// Unlinking a .md file deletes all memories for that tag.

actor MemoryFUSEFilesystem: FUSEFilesystem {

    // MARK: - Constants

    private let rootNodeID: UInt64 = 1
    private let projectDirNodeID: UInt64 = 2
    private let teamDirNodeID: UInt64 = 3

    // MARK: - State

    private var hasProject: Bool = false
    private var hasTeam: Bool = false

    // Inode table: path (relative, e.g. "/" or "/CORE.md" or "/project/CORE.md") <-> nodeID
    private var inodes: [String: UInt64] = ["/": 1, "/project": 2, "/team": 3]
    private var paths: [UInt64: String] = [1: "/", 2: "/project", 3: "/team"]
    private var lookupCounts: [UInt64: UInt64] = [:]
    private var nextInode: UInt64 = 100

    // Content cache: nodeID -> rendered file bytes (invalidated on writes)
    private var contentCache: [UInt64: Data] = [:]

    // Write state per nodeID
    private struct WriteState {
        var buffer: Data        // accumulated write data
        var truncated: Bool     // was setattr(size=0) called?
    }
    private var writeStates: [UInt64: WriteState] = [:]

    // MARK: - Init & Configure

    func configure(hasProject: Bool, hasTeam: Bool) {
        self.hasProject = hasProject
        self.hasTeam = hasTeam
        contentCache.removeAll()
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

    // MARK: - Path parsing

    /// Extract (scope, tag) from a path like "/CORE.md" or "/project/NOTES.md".
    private func scopeAndTag(for path: String) -> (scope: String, tag: String)? {
        if path.hasPrefix("/project/") {
            let filename = String(path.dropFirst("/project/".count))
            guard filename.hasSuffix(".md") else { return nil }
            return ("project", String(filename.dropLast(3)))
        }
        if path.hasPrefix("/team/") {
            let filename = String(path.dropFirst("/team/".count))
            guard filename.hasSuffix(".md") else { return nil }
            return ("team", String(filename.dropLast(3)))
        }
        // Session-scope tag at root
        let filename = String(path.dropFirst(1)) // strip leading /
        guard !filename.isEmpty, filename.hasSuffix(".md"), !filename.contains("/") else { return nil }
        return ("agent", String(filename.dropLast(3)))
    }

    // MARK: - Content fetching

    private func fetchContent(nodeID id: UInt64) async -> Data {
        if let cached = contentCache[id] { return cached }
        guard let path = nodePath(for: id),
              let (scope, tag) = scopeAndTag(for: path) else { return Data() }
        let text = (try? await MemoryClient.shared.readTag(scope: scope, tag: tag)) ?? ""
        let data = Data(text.utf8)
        contentCache[id] = data
        return data
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
        switch parent {
        case rootNodeID:
            // Check subdirectories
            if name == "project" && hasProject {
                let attr = makeAttr(ino: projectDirNodeID, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
                trackLookup(projectDirNodeID)
                return .success(makeEntryOut(nodeID: projectDirNodeID, attr: attr))
            }
            if name == "team" && hasTeam {
                let attr = makeAttr(ino: teamDirNodeID, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
                trackLookup(teamDirNodeID)
                return .success(makeEntryOut(nodeID: teamDirNodeID, attr: attr))
            }
            // Session-scope tag file
            guard name.hasSuffix(".md") else { return .failure(FUSEErrno(-ENOENT)) }
            let tag = String(name.dropLast(3))
            let relPath = "/\(name)"
            let id = nodeID(for: relPath)
            let content = await fetchContent(nodeID: id)
            // Always succeed for .md files (empty = new/nonexistent tag, still a valid file)
            let attr = makeAttr(ino: id, mode: S_IFREG | 0o644, size: UInt64(content.count))
            trackLookup(id)
            _ = tag
            return .success(makeEntryOut(nodeID: id, attr: attr))

        case projectDirNodeID:
            guard name.hasSuffix(".md") else { return .failure(FUSEErrno(-ENOENT)) }
            let relPath = "/project/\(name)"
            let id = nodeID(for: relPath)
            let content = await fetchContent(nodeID: id)
            let attr = makeAttr(ino: id, mode: S_IFREG | 0o644, size: UInt64(content.count))
            trackLookup(id)
            return .success(makeEntryOut(nodeID: id, attr: attr))

        case teamDirNodeID:
            guard name.hasSuffix(".md") else { return .failure(FUSEErrno(-ENOENT)) }
            let relPath = "/team/\(name)"
            let id = nodeID(for: relPath)
            let content = await fetchContent(nodeID: id)
            let attr = makeAttr(ino: id, mode: S_IFREG | 0o644, size: UInt64(content.count))
            trackLookup(id)
            return .success(makeEntryOut(nodeID: id, attr: attr))

        default:
            return .failure(FUSEErrno(-ENOENT))
        }
    }

    // MARK: - FUSEFilesystem: getattr

    func getattr(nodeID id: UInt64) async -> Result<FUSEAttrOut, FUSEErrno> {
        switch id {
        case rootNodeID:
            let attr = makeAttr(ino: id, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))
        case projectDirNodeID:
            let attr = makeAttr(ino: id, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))
        case teamDirNodeID:
            let attr = makeAttr(ino: id, mode: S_IFDIR | 0o755, size: 0, nlink: 2)
            return .success(makeAttrOut(attr: attr))
        default:
            // Tag file — return size from cache or fetch
            let data = await fetchContent(nodeID: id)
            // If there's a pending write, report the write buffer size
            if let ws = writeStates[id] {
                let attr = makeAttr(ino: id, mode: S_IFREG | 0o644, size: UInt64(ws.buffer.count))
                return .success(makeAttrOut(attr: attr))
            }
            let attr = makeAttr(ino: id, mode: S_IFREG | 0o644, size: UInt64(data.count))
            return .success(makeAttrOut(attr: attr))
        }
    }

    // MARK: - FUSEFilesystem: setattr

    func setattr(nodeID id: UInt64, valid: UInt32, size: UInt64?, mode: UInt32?) async -> Result<FUSEAttrOut, FUSEErrno> {
        // Directories are not setattrrable
        if id == rootNodeID || id == projectDirNodeID || id == teamDirNodeID {
            return .failure(FUSEErrno(-EPERM))
        }
        if let newSize = size, (valid & FATTR_SIZE) != 0, newSize == 0 {
            // Truncate to zero: mark as replace mode, clear content cache
            contentCache.removeValue(forKey: id)
            writeStates[id] = WriteState(buffer: Data(), truncated: true)
        }
        return await getattr(nodeID: id)
    }

    // MARK: - FUSEFilesystem: opendir

    func opendir(nodeID id: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno> {
        .success(id)
    }

    // MARK: - FUSEFilesystem: readdir

    func readdir(nodeID id: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        var entries: [(name: String, ino: UInt64, type: UInt32)] = []

        switch id {
        case rootNodeID:
            entries.append((".", rootNodeID, DT_DIR))
            entries.append(("..", rootNodeID, DT_DIR))
            if hasProject { entries.append(("project", projectDirNodeID, DT_DIR)) }
            if hasTeam    { entries.append(("team",    teamDirNodeID,    DT_DIR)) }
            // Always include CORE, then any additional tags from the DB
            var tagSet: [String] = ["CORE"]
            let agentTags = (try? await MemoryClient.shared.listTags(scope: "agent")) ?? []
            for tag in agentTags where !tagSet.contains(tag) { tagSet.append(tag) }
            for tag in tagSet {
                let filename = "\(tag).md"
                let relPath = "/\(filename)"
                let childID = nodeID(for: relPath)
                entries.append((filename, childID, DT_REG))
            }

        case projectDirNodeID:
            entries.append((".", projectDirNodeID, DT_DIR))
            entries.append(("..", rootNodeID, DT_DIR))
            var tagSet: [String] = ["CORE"]
            let projectTags = (try? await MemoryClient.shared.listTags(scope: "project")) ?? []
            for tag in projectTags where !tagSet.contains(tag) { tagSet.append(tag) }
            for tag in tagSet {
                let filename = "\(tag).md"
                let relPath = "/project/\(filename)"
                let childID = nodeID(for: relPath)
                entries.append((filename, childID, DT_REG))
            }

        case teamDirNodeID:
            entries.append((".", teamDirNodeID, DT_DIR))
            entries.append(("..", rootNodeID, DT_DIR))
            var tagSet: [String] = ["CORE"]
            let teamTags = (try? await MemoryClient.shared.listTags(scope: "team")) ?? []
            for tag in teamTags where !tagSet.contains(tag) { tagSet.append(tag) }
            for tag in tagSet {
                let filename = "\(tag).md"
                let relPath = "/team/\(filename)"
                let childID = nodeID(for: relPath)
                entries.append((filename, childID, DT_REG))
            }

        default:
            return .failure(FUSEErrno(-ENOTDIR))
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
        // O_TRUNC is handled via setattr(size=0) which the kernel issues before open or right after
        .success(id)
    }

    // MARK: - FUSEFilesystem: read

    func read(nodeID id: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno> {
        // If there's a pending write buffer, serve from it
        if let ws = writeStates[id] {
            let start = Int(offset)
            guard start < ws.buffer.count else { return .success(Data()) }
            let end = min(start + Int(size), ws.buffer.count)
            return .success(ws.buffer.subdata(in: start..<end))
        }
        let data = await fetchContent(nodeID: id)
        let start = Int(offset)
        guard start < data.count else { return .success(Data()) }
        let end = min(start + Int(size), data.count)
        return .success(data.subdata(in: start..<end))
    }

    // MARK: - FUSEFilesystem: write

    func write(nodeID id: UInt64, fh: UInt64, offset: UInt64, data: Data, flags: UInt32) async -> Result<UInt32, FUSEErrno> {
        guard nodePath(for: id) != nil, scopeAndTag(for: nodePath(for: id)!) != nil else {
            return .failure(FUSEErrno(-ENOENT))
        }
        var ws = writeStates[id] ?? WriteState(buffer: Data(), truncated: false)
        // Grow buffer to fit the write if needed
        let start = Int(offset)
        let end = start + data.count
        if ws.buffer.count < end {
            ws.buffer.append(Data(repeating: 0, count: end - ws.buffer.count))
        }
        ws.buffer.replaceSubrange(start..<end, with: data)
        writeStates[id] = ws
        return .success(UInt32(data.count))
    }

    // MARK: - FUSEFilesystem: create

    func create(parent: UInt64, name: String, mode: UInt32, flags: UInt32) async -> Result<(FUSEEntryOut, FUSEOpenOut), FUSEErrno> {
        guard name.hasSuffix(".md") else { return .failure(FUSEErrno(-EINVAL)) }

        let relPath: String
        switch parent {
        case rootNodeID:       relPath = "/\(name)"
        case projectDirNodeID: relPath = "/project/\(name)"
        case teamDirNodeID:    relPath = "/team/\(name)"
        default: return .failure(FUSEErrno(-ENOENT))
        }

        let id = nodeID(for: relPath)
        trackLookup(id)
        // Initialize with empty write state (truncated=true since it's a new file)
        writeStates[id] = WriteState(buffer: Data(), truncated: true)
        let attr = makeAttr(ino: id, mode: S_IFREG | (mode & 0o777), size: 0)
        var openOut = FUSEOpenOut()
        openOut.fh = id; openOut.open_flags = 0; openOut.padding = 0
        return .success((makeEntryOut(nodeID: id, attr: attr), openOut))
    }

    // MARK: - FUSEFilesystem: mkdir (not supported)

    func mkdir(parent: UInt64, name: String, mode: UInt32) async -> Result<FUSEEntryOut, FUSEErrno> {
        .failure(FUSEErrno(-EPERM))
    }

    // MARK: - FUSEFilesystem: unlink

    func unlink(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        guard name.hasSuffix(".md") else { return .failure(FUSEErrno(-ENOENT)) }
        let relPath: String
        switch parent {
        case rootNodeID:       relPath = "/\(name)"
        case projectDirNodeID: relPath = "/project/\(name)"
        case teamDirNodeID:    relPath = "/team/\(name)"
        default: return .failure(FUSEErrno(-ENOENT))
        }
        guard let (scope, tag) = scopeAndTag(for: relPath) else { return .failure(FUSEErrno(-ENOENT)) }
        do {
            try await MemoryClient.shared.unlinkTag(scope: scope, tag: tag)
            // Clean up inode
            if let id = inodes.removeValue(forKey: relPath) {
                paths.removeValue(forKey: id)
                contentCache.removeValue(forKey: id)
                writeStates.removeValue(forKey: id)
            }
            return .success(())
        } catch {
            return .failure(FUSEErrno(-EIO))
        }
    }

    // MARK: - FUSEFilesystem: rmdir (not supported)

    func rmdir(parent: UInt64, name: String) async -> Result<Void, FUSEErrno> {
        .failure(FUSEErrno(-EPERM))
    }

    // MARK: - FUSEFilesystem: rename

    func rename(oldParent: UInt64, oldName: String, newParent: UInt64, newName: String) async -> Result<Void, FUSEErrno> {
        // Only support renaming within the same directory and only .md files
        guard oldParent == newParent,
              oldName.hasSuffix(".md"), newName.hasSuffix(".md") else { return .failure(FUSEErrno(-EINVAL)) }

        let prefix: String
        let scope: String
        switch oldParent {
        case rootNodeID:       prefix = "/"; scope = "agent"
        case projectDirNodeID: prefix = "/project/"; scope = "project"
        case teamDirNodeID:    prefix = "/team/"; scope = "team"
        default: return .failure(FUSEErrno(-ENOENT))
        }

        let oldTag = String(oldName.dropLast(3))
        let newTag = String(newName.dropLast(3))
        do {
            try await MemoryClient.shared.renameTag(scope: scope, from: oldTag, to: newTag)
            // Update inode tables
            let oldPath = prefix + oldName
            let newPath = prefix + newName
            if let id = inodes.removeValue(forKey: oldPath) {
                inodes[newPath] = id
                paths[id] = newPath
                contentCache.removeValue(forKey: id)
            }
            return .success(())
        } catch {
            return .failure(FUSEErrno(-EIO))
        }
    }

    // MARK: - FUSEFilesystem: release

    func release(nodeID id: UInt64, fh: UInt64) async {
        guard let ws = writeStates.removeValue(forKey: id),
              let path = nodePath(for: id),
              let (scope, tag) = scopeAndTag(for: path) else { return }

        let content = String(decoding: ws.buffer, as: UTF8.self)
        contentCache.removeValue(forKey: id) // invalidate so next read fetches fresh

        do {
            if ws.truncated {
                // Full replace: apply diff from the written content
                try await MemoryClient.shared.writeTag(scope: scope, tag: tag, content: content)
            } else if !ws.buffer.isEmpty {
                // Append mode: new memory entry
                try await MemoryClient.shared.appendTag(scope: scope, tag: tag, content: content)
            }
        } catch {
            // Errors here are unfortunate but FUSE release can't return an error
        }
    }

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
