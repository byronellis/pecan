import Foundation
import GRDB
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

// MARK: - MemoryFilesystem

/// SQLite-backed FUSE filesystem exposing memory records as virtual .md files.
///
/// Path structure:
///   /TAG.md           → agent session DB, memories with tag `tag` (filename lowercased)
///   /project/TAG.md   → project DB (absent if no project DB provided)
///   /team/TAG.md      → team DB    (absent if no team DB provided)
///
/// File format — each .md file renders all memories for that tag:
///   <!-- memory:1 -->
///   Content of first memory.
///
///   <!-- memory:2 -->
///   Content of second memory.
///
/// Write semantics:
///   truncate(0) + write(offset=0, full doc) → diff blocks by ID; INSERT/UPDATE/DELETE
///   write(offset >= current rendered size)  → append: INSERT new memory with that content
///   Pending bytes are flushed to the DB on file release (close).
final class MemoryFilesystem {

    // MARK: - DB references

    private let agentDB: DatabaseQueue
    private let projectDB: DatabaseQueue?
    private let teamDB: DatabaseQueue?

    // MARK: - Pending write buffer

    private enum WriteMode {
        case replace            // started with truncate(0)
        case append(baseSize: Int)  // started at offset >= rendered size
    }

    private struct PendingWrite {
        var mode: WriteMode
        var bytes: [UInt8]
    }

    private let lock = NSLock()
    private var pending: [String: PendingWrite] = [:]

    // MARK: - Init

    init(agentDBPath: String, projectDBPath: String?, teamDBPath: String?) {
        do {
            self.agentDB = try DatabaseQueue(path: agentDBPath)
        } catch {
            fatalError("Cannot open agent DB at \(agentDBPath): \(error)")
        }
        self.projectDB = projectDBPath.flatMap { try? DatabaseQueue(path: $0) }
        self.teamDB    = teamDBPath.flatMap    { try? DatabaseQueue(path: $0) }
    }

    // MARK: - Path resolution

    private struct FileRef {
        let db: DatabaseQueue
        let tag: String     // lowercase, e.g. "core"
    }

    /// Returns a FileRef if `path` points to a .md file, nil for directories or unknown paths.
    private func fileRef(for path: String) -> FileRef? {
        let rel = String(path.dropFirst())  // strip leading /
        guard rel.hasSuffix(".md"), !rel.isEmpty else { return nil }
        let name = String(rel.dropLast(3))  // strip .md
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return FileRef(db: agentDB, tag: parts[0].lowercased())
        case 2 where parts[0] == "project":
            return projectDB.map { FileRef(db: $0, tag: parts[1].lowercased()) }
        case 2 where parts[0] == "team":
            return teamDB.map { FileRef(db: $0, tag: parts[1].lowercased()) }
        default:
            return nil
        }
    }

    // MARK: - Rendering

    private func render(db: DatabaseQueue, tag: String) -> String {
        let rows: [(id: Int64, content: String)]
        do {
            rows = try db.read { conn in
                try Row.fetchAll(conn, sql: """
                    SELECT m.id, m.content FROM memories m
                    JOIN memory_tags mt ON mt.memoryId = m.id
                    WHERE mt.tag = ?
                    ORDER BY m.id ASC
                    """, arguments: [tag]).map { ($0["id"], $0["content"]) }
            }
        } catch { return "" }
        guard !rows.isEmpty else { return "" }

        var out = ""
        for row in rows {
            if !out.isEmpty { out += "\n" }
            out += "<!-- memory:\(row.id) -->\n"
            out += row.content
            if !row.content.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    // MARK: - Block parsing

    private func parseBlocks(_ content: String) -> [(id: Int64?, content: String)] {
        var result: [(id: Int64?, content: String)] = []
        var currentID: Int64? = nil
        var currentLines: [String] = []

        func flush() {
            let body = currentLines
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .reversed()
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .reversed()
                .joined(separator: "\n")
            if !body.isEmpty || currentID != nil {
                result.append((id: currentID, content: body.isEmpty ? "" : body + "\n"))
            }
        }

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("<!-- memory:"), line.hasSuffix(" -->") {
                flush()
                let inner = line.dropFirst(12).dropLast(4)
                currentID = Int64(inner.trimmingCharacters(in: .whitespaces))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return result
    }

    // MARK: - DB mutations

    private func applyDiff(db conn: DatabaseQueue, tag: String, blocks: [(id: Int64?, content: String)]) {
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try conn.write { db in
                let existingIDs = try Int64.fetchAll(db, sql: """
                    SELECT m.id FROM memories m
                    JOIN memory_tags mt ON mt.memoryId = m.id
                    WHERE mt.tag = ? ORDER BY m.id ASC
                    """, arguments: [tag])

                let incomingIDs = Set(blocks.compactMap(\.id))

                // Delete memories removed from the document
                for id in existingIDs where !incomingIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                }

                for block in blocks {
                    if let id = block.id {
                        try db.execute(sql: "UPDATE memories SET content=?, updatedAt=? WHERE id=?",
                                       arguments: [block.content, now, id])
                    } else {
                        try db.execute(sql: "INSERT INTO memories (content, createdAt, updatedAt) VALUES (?,?,?)",
                                       arguments: [block.content, now, now])
                        let newID = db.lastInsertedRowID
                        try db.execute(sql: "INSERT INTO memory_tags (memoryId, tag) VALUES (?,?)",
                                       arguments: [newID, tag])
                    }
                }
            }
        } catch {
            fputs("MemoryFilesystem applyDiff error: \(error)\n", stderr)
        }
    }

    private func insertMemory(db conn: DatabaseQueue, tag: String, content: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try conn.write { db in
                try db.execute(sql: "INSERT INTO memories (content, createdAt, updatedAt) VALUES (?,?,?)",
                               arguments: [content, now, now])
                let newID = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO memory_tags (memoryId, tag) VALUES (?,?)",
                               arguments: [newID, tag])
            }
        } catch {
            fputs("MemoryFilesystem insertMemory error: \(error)\n", stderr)
        }
    }

    // MARK: - Pending write flush

    func release(_ path: String) -> Int32 {
        guard let ref = fileRef(for: path) else { return 0 }
        flush(path: path, ref: ref)
        return 0
    }

    private func flush(path: String, ref: FileRef) {
        lock.lock()
        let pw = pending.removeValue(forKey: path)
        lock.unlock()
        guard let pw else { return }

        let content = String(bytes: pw.bytes, encoding: .utf8) ?? ""
        switch pw.mode {
        case .replace:
            let blocks = parseBlocks(content)
            applyDiff(db: ref.db, tag: ref.tag, blocks: blocks)
        case .append:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            insertMemory(db: ref.db, tag: ref.tag, content: trimmed + "\n")
        }
    }

    // MARK: - FUSE: getattr

    func getattr(_ path: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32 {
        if path == "/" {
            stbuf.pointee.st_mode = UInt16(S_IFDIR | 0o755)
            stbuf.pointee.st_nlink = 2
            return 0
        }
        let rel = String(path.dropFirst())
        switch rel {
        case "project" where projectDB != nil,
             "team"    where teamDB    != nil:
            stbuf.pointee.st_mode = UInt16(S_IFDIR | 0o755)
            stbuf.pointee.st_nlink = 2
            return 0
        default:
            break
        }
        guard let ref = fileRef(for: path) else { return -ENOENT }
        let rendered = render(db: ref.db, tag: ref.tag)
        // File exists even if currently empty (allows create + write pattern)
        stbuf.pointee.st_mode = UInt16(S_IFREG | 0o644)
        stbuf.pointee.st_nlink = 1
        stbuf.pointee.st_size = off_t(rendered.utf8.count)
        return 0
    }

    // MARK: - FUSE: readdir

    func readdir(_ path: String, buf: UnsafeMutableRawPointer?,
                 filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32 {
        pecan_fuse_fill(filler, buf, ".")
        pecan_fuse_fill(filler, buf, "..")
        switch path {
        case "/":
            for tag in listTags(db: agentDB) {
                pecan_fuse_fill(filler, buf, "\(tag.uppercased()).md")
            }
            if projectDB != nil { pecan_fuse_fill(filler, buf, "project") }
            if teamDB    != nil { pecan_fuse_fill(filler, buf, "team") }
        case "/project" where projectDB != nil:
            for tag in listTags(db: projectDB!) {
                pecan_fuse_fill(filler, buf, "\(tag.uppercased()).md")
            }
        case "/team" where teamDB != nil:
            for tag in listTags(db: teamDB!) {
                pecan_fuse_fill(filler, buf, "\(tag.uppercased()).md")
            }
        default:
            return -ENOENT
        }
        return 0
    }

    private func listTags(db: DatabaseQueue) -> [String] {
        (try? db.read { conn in
            try String.fetchAll(conn, sql: "SELECT DISTINCT tag FROM memory_tags ORDER BY tag ASC")
        }) ?? []
    }

    // MARK: - FUSE: read

    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?,
              size: Int, offset: off_t) -> Int32 {
        guard let ref = fileRef(for: path) else { return -ENOENT }
        // Flush any pending write so the read reflects the latest state
        lock.lock(); let hasPending = pending[path] != nil; lock.unlock()
        if hasPending { flush(path: path, ref: ref) }

        let rendered = render(db: ref.db, tag: ref.tag)
        let bytes = Array(rendered.utf8)
        let start = Int(offset)
        guard start <= bytes.count else { return 0 }
        let slice = bytes[start ..< min(start + size, bytes.count)]
        if !slice.isEmpty {
            slice.withUnsafeBytes { src in _ = memcpy(buf, src.baseAddress, src.count) }
        }
        return Int32(slice.count)
    }

    // MARK: - FUSE: truncate

    func truncate(_ path: String, size: off_t) -> Int32 {
        guard let _ = fileRef(for: path) else { return -ENOENT }
        if size == 0 {
            lock.lock()
            pending[path] = PendingWrite(mode: .replace, bytes: [])
            lock.unlock()
        }
        return 0
    }

    // MARK: - FUSE: write

    func write(_ path: String, buf: UnsafePointer<CChar>?,
               size: Int, offset: off_t) -> Int32 {
        guard let ref = fileRef(for: path), let buf else { return -ENOENT }
        let chunk = Array(UnsafeRawBufferPointer(start: buf, count: size).bindMemory(to: UInt8.self))
        let writeOffset = Int(offset)

        lock.lock()
        if pending[path] != nil {
            // Accumulate into existing buffer
            var pw = pending[path]!
            let end = writeOffset + chunk.count
            if end > pw.bytes.count {
                pw.bytes.append(contentsOf: repeatElement(UInt8(0), count: end - pw.bytes.count))
            }
            pw.bytes.replaceSubrange(writeOffset ..< writeOffset + chunk.count, with: chunk)
            pending[path] = pw
            lock.unlock()
        } else {
            lock.unlock()
            // Determine mode from offset
            let renderedSize = render(db: ref.db, tag: ref.tag).utf8.count
            var pw: PendingWrite
            if writeOffset >= renderedSize {
                // Append: new content beyond end of file
                pw = PendingWrite(mode: .append(baseSize: renderedSize), bytes: chunk)
            } else {
                // Replace: starts at beginning (or mid-file with no truncate)
                var base = Array(render(db: ref.db, tag: ref.tag).utf8)
                let end = writeOffset + chunk.count
                if end > base.count { base.append(contentsOf: repeatElement(UInt8(0), count: end - base.count)) }
                base.replaceSubrange(writeOffset ..< writeOffset + chunk.count, with: chunk)
                pw = PendingWrite(mode: .replace, bytes: base)
            }
            lock.lock(); pending[path] = pw; lock.unlock()
        }
        return Int32(size)
    }

    // MARK: - FUSE: create

    func create(_ path: String, mode: mode_t) -> Int32 {
        guard let _ = fileRef(for: path) else { return -EINVAL }
        return 0  // tag file is virtual; memories appear once written
    }

    // MARK: - FUSE: unlink

    func unlink(_ path: String) -> Int32 {
        guard let ref = fileRef(for: path) else { return -ENOENT }
        do {
            try ref.db.write { db in
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT m.id FROM memories m
                    JOIN memory_tags mt ON mt.memoryId = m.id WHERE mt.tag = ?
                    """, arguments: [ref.tag])
                for id in ids {
                    try db.execute(sql: "DELETE FROM memory_tags WHERE memoryId = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                }
            }
        } catch { return -EIO }
        lock.lock(); pending.removeValue(forKey: path); lock.unlock()
        return 0
    }

    // MARK: - FUSE: rename

    func rename(from: String, to: String) -> Int32 {
        guard let src = fileRef(for: from),
              let dst = fileRef(for: to),
              src.db === dst.db else { return -EINVAL }
        do {
            try src.db.write { db in
                try db.execute(sql: "UPDATE memory_tags SET tag = ? WHERE tag = ?",
                               arguments: [dst.tag, src.tag])
            }
        } catch { return -EIO }
        return 0
    }
}
