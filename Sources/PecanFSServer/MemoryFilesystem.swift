import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

// MARK: - MemoryFilesystem

/// A FUSE filesystem that exposes a key/value memory store as .md files.
/// All state is protected by a lock since FUSE calls us from arbitrary threads.
final class MemoryFilesystem {
    private var entries: [String: String] = [:]  // name (no ext) -> content
    private let lock = NSLock()
    private let persistPath: String?

    init(persistPath: String? = nil) {
        self.persistPath = persistPath
        if let path = persistPath {
            load(from: path)
        }
    }

    // MARK: - FUSE callbacks

    func getattr(_ path: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32 {
        if path == "/" {
            stbuf.pointee.st_mode = UInt16(S_IFDIR | 0o755)
            stbuf.pointee.st_nlink = 2
            return 0
        }
        guard let name = memoryName(from: path) else { return -ENOENT }
        lock.lock(); let content = entries[name]; lock.unlock()
        guard let content else { return -ENOENT }
        stbuf.pointee.st_mode = UInt16(S_IFREG | 0o644)
        stbuf.pointee.st_nlink = 1
        stbuf.pointee.st_size = off_t(content.utf8.count)
        return 0
    }

    func readdir(_ path: String, buf: UnsafeMutableRawPointer?,
                 filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32 {
        guard path == "/" else { return -ENOENT }
        pecan_fuse_fill(filler, buf, ".")
        pecan_fuse_fill(filler, buf, "..")
        lock.lock(); let names = Array(entries.keys); lock.unlock()
        for name in names {
            pecan_fuse_fill(filler, buf, "\(name).md")
        }
        return 0
    }

    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?,
              size: Int, offset: off_t) -> Int32 {
        guard let name = memoryName(from: path) else { return -ENOENT }
        lock.lock(); let content = entries[name]; lock.unlock()
        guard let content else { return -ENOENT }
        let bytes = Array(content.utf8)
        let start = Int(offset)
        guard start < bytes.count else { return 0 }
        let slice = bytes[start ..< min(start + size, bytes.count)]
        slice.withUnsafeBytes { src in
            _ = memcpy(buf, src.baseAddress, src.count)
        }
        return Int32(slice.count)
    }

    func write(_ path: String, buf: UnsafePointer<CChar>?,
               size: Int, offset: off_t) -> Int32 {
        guard let name = memoryName(from: path), let buf else { return -ENOENT }
        let newBytes = UnsafeRawBufferPointer(start: buf, count: size)
        let newChunk = String(bytes: newBytes, encoding: .utf8) ?? ""
        lock.lock()
        if offset == 0 {
            entries[name] = newChunk
        } else {
            var existing = entries[name] ?? ""
            // Pad with spaces if writing past end
            let existingBytes = existing.utf8.count
            if Int(offset) > existingBytes {
                existing += String(repeating: " ", count: Int(offset) - existingBytes)
            }
            // Replace bytes at offset
            var allBytes = Array(existing.utf8)
            let start = Int(offset)
            let newSlice = Array(newBytes.bindMemory(to: UInt8.self))
            if start + newSlice.count <= allBytes.count {
                allBytes.replaceSubrange(start ..< start + newSlice.count, with: newSlice)
            } else {
                allBytes = Array(allBytes.prefix(start)) + newSlice
            }
            entries[name] = String(bytes: allBytes, encoding: .utf8) ?? existing
        }
        let updated = entries[name]
        lock.unlock()
        if let path = persistPath, let updated {
            save(name: name, content: updated, to: path)
        }
        return Int32(size)
    }

    func create(_ path: String, mode: mode_t) -> Int32 {
        guard let name = memoryName(from: path) else { return -EINVAL }
        lock.lock(); entries[name] = ""; lock.unlock()
        return 0
    }

    func unlink(_ path: String) -> Int32 {
        guard let name = memoryName(from: path) else { return -ENOENT }
        lock.lock(); let existed = entries.removeValue(forKey: name) != nil; lock.unlock()
        if !existed { return -ENOENT }
        if let dir = persistPath {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(name).md")
        }
        return 0
    }

    func truncate(_ path: String, size: off_t) -> Int32 {
        guard let name = memoryName(from: path) else { return -ENOENT }
        lock.lock()
        guard entries[name] != nil else { lock.unlock(); return -ENOENT }
        if size == 0 {
            entries[name] = ""
        } else if let existing = entries[name] {
            let bytes = Array(existing.utf8)
            let truncated = Array(bytes.prefix(Int(size)))
            entries[name] = String(bytes: truncated, encoding: .utf8) ?? ""
        }
        lock.unlock()
        return 0
    }

    func rename(from: String, to: String) -> Int32 {
        guard let oldName = memoryName(from: from),
              let newName = memoryName(from: to) else { return -EINVAL }
        lock.lock()
        guard let content = entries.removeValue(forKey: oldName) else {
            lock.unlock(); return -ENOENT
        }
        entries[newName] = content
        lock.unlock()
        return 0
    }

    // MARK: - Helpers

    private func memoryName(from path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let file = String(path.dropFirst())
        guard file.hasSuffix(".md") else { return nil }
        return String(file.dropLast(3))
    }

    // MARK: - Persistence (simple per-file .md in a backing directory)

    private func load(from dir: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for file in files where file.hasSuffix(".md") {
            let name = String(file.dropLast(3))
            let content = (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
            entries[name] = content
        }
    }

    private func save(name: String, content: String, to dir: String) {
        try? content.write(toFile: "\(dir)/\(name).md", atomically: true, encoding: .utf8)
    }
}
