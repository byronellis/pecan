import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Global filesystem instance
nonisolated(unsafe) var _fs: (any PecanFuseFS)?

// MARK: - MemoryFilesystem protocol conformance
extension MemoryFilesystem: PecanFuseFS {}

// MARK: - FUSE callbacks

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

func cb_release(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let fs = _fs, let path else { return 0 }
    return fs.release(String(cString: path))
}

func cb_mkdir(_ path: UnsafePointer<CChar>?, _ mode: mode_t) -> Int32 {
    guard let fs = _fs, let path else { return -ENOENT }
    return fs.mkdir(String(cString: path), mode: mode)
}

func cb_rmdir(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let fs = _fs, let path else { return -ENOENT }
    return fs.rmdir(String(cString: path))
}

// MARK: - Entry point

let args = CommandLine.arguments

func argValue(_ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let mode = argValue("--mode") ?? "memory"

guard args.count >= 2, !args[1].hasPrefix("--") else {
    fputs("Usage: pecan-fs-server <mountpoint> [--mode memory|skills] [--agent-db <path>] [--project-db <path>] [--team-db <path>] [--skills-dir <path>]\n", stderr)
    exit(1)
}

switch mode {
case "skills":
    guard let skillsDir = argValue("--skills-dir") else {
        fputs("Error: --skills-dir <path> is required for --mode skills\n", stderr)
        exit(1)
    }
    _fs = SkillsFilesystem(skillsDir: skillsDir)

case "overlay":
    guard let lowerDir = argValue("--lower-dir"),
          let upperDir = argValue("--upper-dir") else {
        fputs("Error: overlay mode requires --lower-dir and --upper-dir\n", stderr)
        exit(1)
    }
    let sid = argValue("--session-id") ?? "unknown"
    _fs = OverlayFilesystem(lowerDir: lowerDir, upperDir: upperDir, sessionID: sid)

default: // "memory"
    guard let agentDBPath = argValue("--agent-db") else {
        fputs("Error: --agent-db <path> is required for --mode memory\n", stderr)
        exit(1)
    }
    _fs = MemoryFilesystem(
        agentDBPath: agentDBPath,
        projectDBPath: argValue("--project-db"),
        teamDBPath: argValue("--team-db")
    )
}

pecan_cb_getattr  = cb_getattr
pecan_cb_readdir  = cb_readdir
pecan_cb_read     = cb_read
pecan_cb_write    = cb_write
pecan_cb_create   = cb_create
pecan_cb_unlink   = cb_unlink
pecan_cb_truncate = cb_truncate
pecan_cb_rename   = cb_rename
pecan_cb_release  = cb_release
// Wire mkdir/rmdir for overlay mode; other modes leave them unwired (directories are virtual)
if mode == "overlay" {
    pecan_cb_mkdir = cb_mkdir
    pecan_cb_rmdir = cb_rmdir
}

// Build FUSE argc/argv: strip our flags, keep mountpoint + any -f/-d
let ourFlags: Set<String> = ["--agent-db", "--project-db", "--team-db", "--mode", "--skills-dir",
                              "--lower-dir", "--upper-dir", "--session-id"]
var fuseArgs: [String] = [args[0]]
var skip = false
for arg in args.dropFirst() {
    if skip { skip = false; continue }
    if ourFlags.contains(arg) { skip = true; continue }
    fuseArgs.append(arg)
}
if !fuseArgs.contains("-f") && !fuseArgs.contains("-d") {
    fuseArgs.append("-f")
}

var cArgs = fuseArgs.map { strdup($0) }
let exitCode = cArgs.withUnsafeMutableBufferPointer { ptr in
    pecan_fuse_main(Int32(ptr.count), ptr.baseAddress)
}
cArgs.forEach { free($0) }
exit(exitCode)
