import Foundation
import PecanShared
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Socket helpers

func connectToLauncher() -> Int32 {
    let currentPath = FileManager.default.currentDirectoryPath
    let socketPath = "\(currentPath)/.run/launcher.sock"

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("error: failed to create socket\n", stderr)
        exit(1)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "Socket path too long")
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        fputs("error: failed to connect to launcher at \(socketPath): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }
    return fd
}

func sendRequest(_ request: Pecan_LauncherRequest, fd: Int32) throws {
    let data: [UInt8] = try request.serializedBytes()
    var length = UInt32(data.count).bigEndian
    _ = withUnsafeBytes(of: &length) { write(fd, $0.baseAddress!, 4) }
    _ = data.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
}

func readResponse(fd: Int32) throws -> Pecan_LauncherResponse {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    guard read(fd, &lengthBytes, 4) == 4 else {
        throw NSError(domain: "PecanShell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read response length"])
    }
    let messageLength = Int(UInt32(bigEndian: lengthBytes.withUnsafeBufferPointer {
        $0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
    }))
    var data = Data(count: messageLength)
    var totalRead = 0
    while totalRead < messageLength {
        let n = data.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress! + totalRead, messageLength - totalRead)
        }
        if n <= 0 { break }
        totalRead += n
    }
    return try Pecan_LauncherResponse(serializedBytes: data)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: pecan-shell <session-id> [command ...]\n", stderr)
    exit(1)
}

let sessionID = args[1]
let command = Array(args.dropFirst(2))

// Build exec request
var execReq = Pecan_LauncherExecRequest()
execReq.sessionID = sessionID
execReq.command = command
var req = Pecan_LauncherRequest()
req.exec = execReq

let fd = connectToLauncher()

do {
    try sendRequest(req, fd: fd)
    let response = try readResponse(fd: fd)
    guard response.success else {
        fputs("error: \(response.errorMessage)\n", stderr)
        close(fd)
        exit(1)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    close(fd)
    exit(1)
}

print("[pecan-shell] connected to \(sessionID)")

// Stdin → socket
let stdinTask = Task.detached {
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
    defer { buf.deallocate() }
    while true {
        let n = read(STDIN_FILENO, buf, 4096)
        if n <= 0 { break }
        var written = 0
        while written < n {
            let w = write(fd, buf + written, n - written)
            if w <= 0 { return }
            written += w
        }
    }
}

// Socket → stdout
let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buf.deallocate() }
while true {
    let n = read(fd, buf, 4096)
    if n <= 0 { break }
    var written = 0
    while written < n {
        let w = write(STDOUT_FILENO, buf + written, n - written)
        if w <= 0 { break }
        written += w
    }
}

stdinTask.cancel()
print("[pecan-shell] disconnected")
close(fd)
