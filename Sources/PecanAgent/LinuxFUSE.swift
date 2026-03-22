#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - FUSE errno wrapper

/// Wraps a POSIX errno value as a Swift Error so it can be used in Result<T, FUSEErrno>.
struct FUSEErrno: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}

// MARK: - FUSE Opcodes

enum FUSEOpcode: UInt32 {
    case lookup       = 1
    case forget       = 2
    case getattr      = 3
    case setattr      = 4
    case mknod        = 8
    case mkdir        = 9
    case unlink       = 10
    case rmdir        = 11
    case rename       = 12
    case open         = 14
    case read         = 15
    case write        = 16
    case statfs       = 17
    case release      = 18
    case init_        = 26
    case opendir      = 27
    case readdir      = 28
    case releasedir   = 29
    case create       = 35
}

// MARK: - File type constants

let S_IFDIR: UInt32 = 0o040000
let S_IFREG: UInt32 = 0o100000

// MARK: - Dirent type constants

let DT_REG: UInt32 = 8
let DT_DIR: UInt32 = 4

// MARK: - FATTR constants for setattr

let FATTR_MODE: UInt32 = 1
let FATTR_SIZE: UInt32 = 8

// MARK: - FUSE structs (matching linux/fuse.h layout exactly)

struct FUSEInHeader {
    var len: UInt32 = 0
    var opcode: UInt32 = 0
    var unique: UInt64 = 0
    var nodeid: UInt64 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var pid: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEOutHeader {
    var len: UInt32 = 0
    var error: Int32 = 0
    var unique: UInt64 = 0
}

struct FUSEAttr {
    var ino: UInt64 = 0
    var size: UInt64 = 0
    var blocks: UInt64 = 0
    var atime: UInt64 = 0
    var mtime: UInt64 = 0
    var ctime: UInt64 = 0
    var atimensec: UInt32 = 0
    var mtimensec: UInt32 = 0
    var ctimensec: UInt32 = 0
    var mode: UInt32 = 0
    var nlink: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var rdev: UInt32 = 0
    var blksize: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEEntryOut {
    var nodeid: UInt64 = 0
    var generation: UInt64 = 0
    var entry_valid: UInt64 = 0
    var attr_valid: UInt64 = 0
    var entry_valid_nsec: UInt32 = 0
    var attr_valid_nsec: UInt32 = 0
    var attr: FUSEAttr = FUSEAttr()
}

struct FUSEAttrOut {
    var attr_valid: UInt64 = 0
    var attr_valid_nsec: UInt32 = 0
    var dummy: UInt32 = 0
    var attr: FUSEAttr = FUSEAttr()
}

struct FUSEInitIn {
    var major: UInt32 = 0
    var minor: UInt32 = 0
    var max_readahead: UInt32 = 0
    var flags: UInt32 = 0
}

struct FUSEInitOut {
    var major: UInt32 = 0
    var minor: UInt32 = 0
    var max_readahead: UInt32 = 0
    var flags: UInt32 = 0
    var max_background: UInt16 = 0
    var congestion_threshold: UInt16 = 0
    var max_write: UInt32 = 0
    var time_gran: UInt32 = 0
    var max_pages: UInt16 = 0
    var padding: UInt16 = 0
    var unused: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0,0,0,0,0,0,0)
}

struct FUSEOpenIn {
    var flags: UInt32 = 0
    var unused: UInt32 = 0
}

struct FUSEOpenOut {
    var fh: UInt64 = 0
    var open_flags: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEReadIn {
    var fh: UInt64 = 0
    var offset: UInt64 = 0
    var size: UInt32 = 0
    var read_flags: UInt32 = 0
    var lock_owner: UInt64 = 0
    var flags: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEWriteIn {
    var fh: UInt64 = 0
    var offset: UInt64 = 0
    var size: UInt32 = 0
    var write_flags: UInt32 = 0
    var lock_owner: UInt64 = 0
    var flags: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEWriteOut {
    var size: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSECreateIn {
    var flags: UInt32 = 0
    var mode: UInt32 = 0
    var umask: UInt32 = 0
    var padding: UInt32 = 0
}

struct FUSEMkdirIn {
    var mode: UInt32 = 0
    var umask: UInt32 = 0
}

struct FUSERenameIn {
    var newdir: UInt64 = 0
}

struct FUSESetAttrIn {
    var valid: UInt32 = 0
    var padding: UInt32 = 0
    var fh: UInt64 = 0
    var size: UInt64 = 0
    var lock_owner: UInt64 = 0
    var atime: UInt64 = 0
    var mtime: UInt64 = 0
    var ctime: UInt64 = 0
    var atimensec: UInt32 = 0
    var mtimensec: UInt32 = 0
    var ctimensec: UInt32 = 0
    var mode: UInt32 = 0
    var unused4: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var unused5: UInt32 = 0
}

struct FUSEGetAttrIn {
    var getattr_flags: UInt32 = 0
    var dummy: UInt32 = 0
    var fh: UInt64 = 0
}

struct FUSEReleaseIn {
    var fh: UInt64 = 0
    var flags: UInt32 = 0
    var release_flags: UInt32 = 0
    var lock_owner: UInt64 = 0
}

struct FUSEForgetIn {
    var nlookup: UInt64 = 0
}

// MARK: - Helper: build fuse_dirent

func buildDirent(ino: UInt64, offset: UInt64, type: UInt32, name: String) -> Data {
    var data = Data()
    // fuse_dirent layout: ino(u64), off(u64), namelen(u32), type(u32), name bytes
    var inoVal = ino
    var offVal = offset
    let nameBytes = Array(name.utf8)
    var nameLen = UInt32(nameBytes.count)
    var typeVal = type

    withUnsafeBytes(of: &inoVal) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &offVal) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &nameLen) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &typeVal) { data.append(contentsOf: $0) }
    data.append(contentsOf: nameBytes)
    // Pad to 8-byte alignment
    let total = 8 + 8 + 4 + 4 + nameBytes.count
    let padded = (total + 7) & ~7
    let padding = padded - total
    if padding > 0 {
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }
    return data
}

// MARK: - Open /dev/fuse

enum FUSEError: Error {
    case cannotCreateDevice(String)
    case cannotOpenDevice(String)
    case mountFailed(String)
}

func fuseOpenDevice() throws -> Int32 {
    let devPath = "/dev/fuse"
    var st = stat()
    if stat(devPath, &st) != 0 {
        // Create the device node
        // major=10, minor=229
        let devNum = (UInt(10) << 8) | UInt(229)
        let result = mknod(devPath, S_IFCHR | 0o600, devNum)
        if result != 0 {
            throw FUSEError.cannotCreateDevice("mknod \(devPath) failed: \(errno)")
        }
    }
    let fd = open(devPath, O_RDWR)
    if fd < 0 {
        throw FUSEError.cannotOpenDevice("open \(devPath) failed: \(errno)")
    }
    return fd
}

// MARK: - Mount FUSE

func fuseMountPoint(_ path: String, fd: Int32) throws {
    // Ensure the mount point directory exists
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

    // MS_NOSUID = 2, MS_NODEV = 4 on Linux
    let mountFlags: UInt = 2 | 4
    // rootmode is parsed by the kernel as octal (fsparam_u32oct), so pass "40755" not "16877"
    // 40755 (octal) = 16877 (decimal) = S_IFDIR | 0755
    let options = "fd=\(fd),rootmode=40755,user_id=0,group_id=0,allow_other"
    let result = path.withCString { targetPtr -> Int32 in
        "fuse".withCString { typePtr -> Int32 in
            options.withCString { dataPtr -> Int32 in
                mount("fuse", targetPtr, typePtr, mountFlags, dataPtr)
            }
        }
    }
    if result != 0 {
        let errStr = String(cString: strerror(errno))
        throw FUSEError.mountFailed("mount fuse at \(path) failed (errno \(errno)): \(errStr)")
    }
}

// MARK: - Unmount FUSE

func fuseUnmount(_ path: String) {
    _ = path.withCString { ptr in
        umount(ptr)
    }
}

// MARK: - Response builders

private func makeOutHeader(unique: UInt64, error: Int32, totalLen: Int) -> FUSEOutHeader {
    FUSEOutHeader(len: UInt32(totalLen), error: error, unique: unique)
}

func buildResponse(unique: UInt64, error: Int32) -> Data {
    let hdr = makeOutHeader(unique: unique, error: error, totalLen: MemoryLayout<FUSEOutHeader>.size)
    var data = Data(count: MemoryLayout<FUSEOutHeader>.size)
    data.withUnsafeMutableBytes { ptr in
        ptr.storeBytes(of: hdr, as: FUSEOutHeader.self)
    }
    return data
}

func buildResponse<T>(unique: UInt64, body: T) -> Data {
    let bodySize = MemoryLayout<T>.size
    let hdr = makeOutHeader(unique: unique, error: 0, totalLen: MemoryLayout<FUSEOutHeader>.size + bodySize)
    var data = Data(count: MemoryLayout<FUSEOutHeader>.size + bodySize)
    data.withUnsafeMutableBytes { ptr in
        ptr.storeBytes(of: hdr, as: FUSEOutHeader.self)
        var bodyVal = body
        withUnsafeBytes(of: &bodyVal) { bodyPtr in
            ptr.baseAddress!.advanced(by: MemoryLayout<FUSEOutHeader>.size)
                .copyMemory(from: bodyPtr.baseAddress!, byteCount: bodySize)
        }
    }
    return data
}

func buildResponse(unique: UInt64, body: Data) -> Data {
    let hdr = makeOutHeader(unique: unique, error: 0, totalLen: MemoryLayout<FUSEOutHeader>.size + body.count)
    var data = Data(count: MemoryLayout<FUSEOutHeader>.size)
    data.withUnsafeMutableBytes { ptr in
        ptr.storeBytes(of: hdr, as: FUSEOutHeader.self)
    }
    data.append(body)
    return data
}

// MARK: - Struct reader

func readStruct<T>(_ type: T.Type, from data: Data, offset: Int) -> T? {
    let size = MemoryLayout<T>.size
    guard offset + size <= data.count else { return nil }
    return data.withUnsafeBytes { ptr -> T in
        ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: T.self).pointee
    }
}

#endif // os(Linux)
