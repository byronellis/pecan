import Foundation
import PecanShared
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Running sessions index

struct SessionEntry: Codable {
    var sessionID: String
    var agentName: String
    var projectName: String
    var teamName: String
    var networkEnabled: Bool
    var persistent: Bool
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agentName = "agent_name"
        case projectName = "project_name"
        case teamName = "team_name"
        case networkEnabled = "network_enabled"
        case persistent
        case startedAt = "started_at"
    }
}

func readSessionsIndex() -> [SessionEntry] {
    let path = FileManager.default.currentDirectoryPath + "/.run/sessions.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
    return (try? JSONDecoder().decode([SessionEntry].self, from: data)) ?? []
}

func resolveSessionID(_ nameOrID: String) -> String? {
    let sessions = readSessionsIndex()
    // Exact session ID match
    if sessions.contains(where: { $0.sessionID == nameOrID }) { return nameOrID }
    // Agent name match (case-insensitive, first match)
    let lower = nameOrID.lowercased()
    return sessions.first { $0.agentName.lowercased() == lower }?.sessionID
}

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

// pecan-shell list
if args.count >= 2 && args[1] == "list" {
    let sessions = readSessionsIndex()
    if sessions.isEmpty {
        print("No running sessions.")
    } else {
        print(String(format: "%-20s  %-36s  %-15s  %s", "NAME", "SESSION ID", "PROJECT", "STARTED"))
        print(String(repeating: "-", count: 90))
        for s in sessions {
            let proj = s.projectName.isEmpty ? "-" : s.projectName
            let started = String(s.startedAt.prefix(19)).replacingOccurrences(of: "T", with: " ")
            print(String(format: "%-20s  %-36s  %-15s  %s",
                s.agentName, s.sessionID, proj, started))
        }
    }
    exit(0)
}

guard args.count >= 2 else {
    fputs("Usage: pecan-shell list\n", stderr)
    fputs("       pecan-shell <name|session-id> [command ...]\n", stderr)
    exit(1)
}

let nameOrID = args[1]
guard let sessionID = resolveSessionID(nameOrID) else {
    fputs("error: no running session named '\(nameOrID)'\n", stderr)
    fputs("Run 'pecan-shell list' to see running sessions.\n", stderr)
    exit(1)
}

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

print("[pecan-shell] connected to \(sessionID) (\(nameOrID))")

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
