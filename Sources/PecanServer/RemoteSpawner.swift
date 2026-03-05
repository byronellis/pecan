import Foundation
import Logging

// IPC protocol types — duplicated from PecanVMLauncher to avoid coupling targets.

private enum LauncherRequest: Codable {
    case spawn(SpawnRequest)
    case terminate(TerminateRequest)

    struct SpawnRequest: Codable {
        let type: String
        let sessionID: String
        let grpcSocketPath: String
        let agentName: String
        let mounts: [MountSpec]
    }

    struct TerminateRequest: Codable {
        let type: String
        let sessionID: String
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "spawn":
            self = .spawn(try SpawnRequest(from: decoder))
        case "terminate":
            self = .terminate(try TerminateRequest(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .spawn(let req): try req.encode(to: encoder)
        case .terminate(let req): try req.encode(to: encoder)
        }
    }
}

private struct LauncherResponse: Codable {
    let type: String
    let sessionID: String
    let error: String?
}

/// Spawns agents by sending IPC commands to the pecan-vm-launcher process over a Unix socket.
public actor RemoteSpawner: AgentSpawner {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func spawnAgent(sessionID: String, agentName: String, workspacePath: String, shares: [MountSpec]) async throws {
        let currentPath = FileManager.default.currentDirectoryPath
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let grpcSocketPath = "\(currentPath)/.run/grpc.sock"

        // Build the full mounts list
        var mounts: [MountSpec] = [
            MountSpec(source: workspacePath, destination: "/home/\(agentName)", readOnly: false),
            MountSpec(source: "\(currentPath)/.build/aarch64-swift-linux-musl/release", destination: "/opt/pecan", readOnly: true),
            MountSpec(source: "\(homeDir)/.pecan/tools", destination: "/home/\(agentName)/.pecan/tools", readOnly: true),
        ]
        mounts.append(contentsOf: shares)

        let request = LauncherRequest.SpawnRequest(
            type: "spawn",
            sessionID: sessionID,
            grpcSocketPath: grpcSocketPath,
            agentName: agentName,
            mounts: mounts
        )
        let response = try await sendRequest(request)
        if response.type == "spawn_error" {
            throw NSError(
                domain: "RemoteSpawner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Unknown spawn error"]
            )
        }
    }

    public func terminateAgent(sessionID: String) async throws {
        let request = LauncherRequest.TerminateRequest(
            type: "terminate",
            sessionID: sessionID
        )
        let response = try await sendRequest(request)
        if response.type == "terminate_error" {
            throw NSError(
                domain: "RemoteSpawner", code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Unknown terminate error"]
            )
        }
    }

    private func sendRequest<T: Encodable>(_ request: T) async throws -> LauncherResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "RemoteSpawner", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create socket: \(String(cString: strerror(errno)))"])
        }
        defer { close(fd) }

        // Connect to launcher socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "Socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "RemoteSpawner", code: 4,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to connect to launcher at \(socketPath): \(String(cString: strerror(errno)))"])
        }

        // Set read timeout to 30s for VM boot time
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Send request + newline
        var requestData = try JSONEncoder().encode(request)
        requestData.append(UInt8(ascii: "\n"))
        let writeResult = requestData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
        guard writeResult == requestData.count else {
            throw NSError(domain: "RemoteSpawner", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to write request"])
        }

        // Read response
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
            if responseData.contains(UInt8(ascii: "\n")) { break }
        }

        if let newlineIndex = responseData.firstIndex(of: UInt8(ascii: "\n")) {
            responseData = responseData[responseData.startIndex..<newlineIndex]
        }

        guard !responseData.isEmpty else {
            throw NSError(domain: "RemoteSpawner", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Empty response from launcher"])
        }

        return try JSONDecoder().decode(LauncherResponse.self, from: responseData)
    }
}
