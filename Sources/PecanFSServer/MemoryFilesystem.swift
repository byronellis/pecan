import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

// MARK: - MemoryFilesystem

/// A FUSE filesystem that exposes a key/value memory store as .md files.
/// Supports one level of subdirectories — path "/core/prefs.md" maps to key "core/prefs".
/// Directories are implicit: they exist whenever any file exists beneath them.
/// All state is protected by a lock since FUSE calls us from arbitrary threads.
final class MemoryFilesystem {
    private var entries: [String: String] = [:]  // key (e.g. "notes" or "core/prefs") -> content
    private var dirs: Set<String> = []           // explicit directories (e.g. "core")
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

        let rel = String(path.dropFirst())  // strip leading "/"

        // Check if it's a known directory (explicit mkdir or has files beneath it)
        let dirPrefix = rel + "/"
        lock.lock()
        let isDir = dirs.contains(rel) || entries.keys.contains { $0.hasPrefix(dirPrefix) }
        lock.unlock()
        if isDir {
            stbuf.pointee.st_mode = UInt16(S_IFDIR | 0o755)
            stbuf.pointee.st_nlink = 2
            return 0
        }

        // Check if it's a file
        guard let name = memoryKey(from: path) else { return -ENOENT }
        lock.lock(); let content = entries[name]; lock.unlock()
        guard let content else { return -ENOENT }
        stbuf.pointee.st_mode = UInt16(S_IFREG | 0o644)
        stbuf.pointee.st_nlink = 1
        stbuf.pointee.st_size = off_t(content.utf8.count)
        return 0
    }

    func readdir(_ path: String, buf: UnsafeMutableRawPointer?,
                 filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32 {
        pecan_fuse_fill(filler, buf, ".")
        pecan_fuse_fill(filler, buf, "..")

        // Prefix to match: "" for root, "core/" for /core
        let prefix: String
        if path == "/" {
            prefix = ""
        } else {
            prefix = String(path.dropFirst()) + "/"  // e.g. "core/"
        }

        lock.lock()
        let keys = Array(entries.keys)
        let allDirs = dirs
        lock.unlock()

        // Collect immediate children (files as "name.md", subdirs as "name")
        var seen = Set<String>()
        for key in keys {
            guard key.hasPrefix(prefix) else { continue }
            let rest = String(key.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                let dirName = String(rest[rest.startIndex..<slash])
                if seen.insert(dirName).inserted { pecan_fuse_fill(filler, buf, dirName) }
            } else {
                let fileName = "\(rest).md"
                if seen.insert(fileName).inserted { pecan_fuse_fill(filler, buf, fileName) }
            }
        }
        // Also include explicit empty directories
        for dir in allDirs {
            guard prefix.isEmpty ? !dir.contains("/") : dir.hasPrefix(String(prefix.dropLast())) else { continue }
            let name = prefix.isEmpty ? dir : String(dir.dropFirst(prefix.count))
            if !name.isEmpty && !name.contains("/") && seen.insert(name).inserted {
                pecan_fuse_fill(filler, buf, name)
            }
        }
        return 0
    }

    func mkdir(_ path: String) -> Int32 {
        let rel = String(path.dropFirst())
        guard !rel.isEmpty, !rel.contains("/") else { return -EPERM }  // only one level deep
        lock.lock(); dirs.insert(rel); lock.unlock()
        return 0
    }

    func rmdir(_ path: String) -> Int32 {
        let rel = String(path.dropFirst())
        let prefix = rel + "/"
        lock.lock()
        let hasFiles = entries.keys.contains { $0.hasPrefix(prefix) }
        if !hasFiles { dirs.remove(rel) }
        lock.unlock()
        return hasFiles ? -ENOTEMPTY : 0
    }

    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?,
              size: Int, offset: off_t) -> Int32 {
        guard let name = memoryKey(from: path) else { return -ENOENT }
        lock.lock(); let content = entries[name]; lock.unlock()
        guard let content else { return -ENOENT }
        let bytes = Array(content.utf8)
        let start = Int(offset)
        guard start < bytes.count else { return 0 }
        let slice = bytes[start ..< min(start + size, bytes.count)]
        slice.withUnsafeBytes { src in _ = memcpy(buf, src.baseAddress, src.count) }
        return Int32(slice.count)
    }

    func write(_ path: String, buf: UnsafePointer<CChar>?,
               size: Int, offset: off_t) -> Int32 {
        guard let name = memoryKey(from: path), let buf else { return -ENOENT }
        let newBytes = UnsafeRawBufferPointer(start: buf, count: size)
        let newChunk = String(bytes: newBytes, encoding: .utf8) ?? ""
        lock.lock()
        if offset == 0 {
            entries[name] = newChunk
        } else {
            var existing = entries[name] ?? ""
            let existingBytes = existing.utf8.count
            if Int(offset) > existingBytes {
                existing += String(repeating: " ", count: Int(offset) - existingBytes)
            }
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
        if let dir = persistPath, let updated {
            save(name: name, content: updated, to: dir)
        }
        return Int32(size)
    }

    func create(_ path: String, mode: mode_t) -> Int32 {
        guard let name = memoryKey(from: path) else { return -EINVAL }
        lock.lock()
        entries[name] = ""
        if let slash = name.firstIndex(of: "/") {
            dirs.insert(String(name[name.startIndex..<slash]))
        }
        lock.unlock()
        return 0
    }

    func unlink(_ path: String) -> Int32 {
        guard let name = memoryKey(from: path) else { return -ENOENT }
        lock.lock(); let existed = entries.removeValue(forKey: name) != nil; lock.unlock()
        if !existed { return -ENOENT }
        if let dir = persistPath {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(name).md")
        }
        return 0
    }

    func truncate(_ path: String, size: off_t) -> Int32 {
        guard let name = memoryKey(from: path) else { return -ENOENT }
        lock.lock()
        guard entries[name] != nil else { lock.unlock(); return -ENOENT }
        if size == 0 {
            entries[name] = ""
        } else if let existing = entries[name] {
            let bytes = Array(existing.utf8)
            entries[name] = String(bytes: Array(bytes.prefix(Int(size))), encoding: .utf8) ?? ""
        }
        lock.unlock()
        return 0
    }

    func rename(from: String, to: String) -> Int32 {
        guard let oldName = memoryKey(from: from),
              let newName = memoryKey(from: to) else { return -EINVAL }
        lock.lock()
        guard let content = entries.removeValue(forKey: oldName) else {
            lock.unlock(); return -ENOENT
        }
        entries[newName] = content
        lock.unlock()
        return 0
    }

    // MARK: - Helpers

    /// Convert a FUSE path like "/core/prefs.md" or "/notes.md" to a storage key
    /// like "core/prefs" or "notes". Returns nil for directories or invalid paths.
    private func memoryKey(from path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let rel = String(path.dropFirst())
        guard rel.hasSuffix(".md") else { return nil }
        return String(rel.dropLast(3))
    }

    // MARK: - Persistence

    private func load(from dir: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return }
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".md") else { continue }
            let name = String(file.dropLast(3))
            let content = (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
            entries[name] = content
        }
    }

    private func save(name: String, content: String, to dir: String) {
        let filePath = "\(dir)/\(name).md"
        let dirPath = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}
