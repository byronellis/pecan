import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Global filesystem instance
// FUSE callbacks are C function pointers and cannot capture state, so we
// use a process-global. FUSE is inherently single-mount-per-process anyway.
nonisolated(unsafe) var _fs: MemoryFilesystem?

// MARK: - FUSE callback globals (C-callable Swift functions)

func cb_getattr(_ path: UnsafePointer<CChar>?, _ stbuf: UnsafeMutablePointer<stat>?) -> Int32 {
    guard let fs = _fs, let path, let stbuf else { return -ENOENT }
    return fs.getattr(String(cString: path), stbuf)
}

func cb_readdir(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutableRawPointer?,
                _ filler: UnsafeMutableRawPointer?, _ offset: off_t) -> Int32 {
    guard let fs = _fs, let path else { return -ENOENT }
    return fs.readdir(String(cString: path), buf: buf, filler: filler, offset: offset)
}

func cb_read(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutablePointer<CChar>?,
             _ size: Int, _ offset: off_t) -> Int32 {
    guard let fs = _fs, let path else { return -EIO }
    return fs.read(String(cString: path), buf: buf, size: size, offset: offset)
}

func cb_write(_ path: UnsafePointer<CChar>?, _ buf: UnsafePointer<CChar>?,
              _ size: Int, _ offset: off_t) -> Int32 {
    guard let fs = _fs, let path else { return -EIO }
    return fs.write(String(cString: path), buf: buf, size: size, offset: offset)
}

func cb_create(_ path: UnsafePointer<CChar>?, _ mode: mode_t) -> Int32 {
    guard let fs = _fs, let path else { return -EINVAL }
    return fs.create(String(cString: path), mode: mode)
}

func cb_unlink(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let fs = _fs, let path else { return -ENOENT }
    return fs.unlink(String(cString: path))
}

func cb_truncate(_ path: UnsafePointer<CChar>?, _ size: off_t) -> Int32 {
    guard let fs = _fs, let path else { return -ENOENT }
    return fs.truncate(String(cString: path), size: size)
}

func cb_rename(_ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?) -> Int32 {
    guard let fs = _fs, let from, let to else { return -EINVAL }
    return fs.rename(from: String(cString: from), to: String(cString: to))
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: pecan-fs-server <mountpoint> [--persist <dir>]\n", stderr)
    exit(1)
}

// Parse --persist <dir> option
var persistPath: String? = nil
if let idx = args.firstIndex(of: "--persist"), idx + 1 < args.count {
    persistPath = args[idx + 1]
    if let dir = persistPath {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}

// Set up the filesystem and wire callbacks
_fs = MemoryFilesystem(persistPath: persistPath)
pecan_cb_getattr  = cb_getattr
pecan_cb_readdir  = cb_readdir
pecan_cb_read     = cb_read
pecan_cb_write    = cb_write
pecan_cb_create   = cb_create
pecan_cb_unlink   = cb_unlink
pecan_cb_truncate = cb_truncate
pecan_cb_rename   = cb_rename

// Build argc/argv for FUSE (strip our own --persist args, keep mountpoint + any -f/-d)
var fuseArgs: [String] = [args[0]]
var skip = false
for arg in args.dropFirst() {
    if skip { skip = false; continue }
    if arg == "--persist" { skip = true; continue }
    fuseArgs.append(arg)
}

// Run FUSE in foreground (-f) so the process stays alive as a child
if !fuseArgs.contains("-f") && !fuseArgs.contains("-d") {
    fuseArgs.append("-f")
}

var cArgs = fuseArgs.map { strdup($0) }
let exitCode = cArgs.withUnsafeMutableBufferPointer { ptr in
    pecan_fuse_main(Int32(ptr.count), ptr.baseAddress)
}
cArgs.forEach { free($0) }
exit(exitCode)
