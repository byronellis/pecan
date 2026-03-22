import Foundation
import PecanShared
import SwiftProtobuf
import Logging

/// Spawns agents by sending IPC commands to the pecan-vm-launcher process over a Unix socket.
public actor RemoteSpawner: AgentSpawner {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func spawnAgent(sessionID: String, agentName: String, workspacePath: String, shares: [MountSpec]) async throws {
        let currentPath = FileManager.default.currentDirectoryPath
        let grpcSocketPath = "\(currentPath)/.run/grpc.sock"

        // Build the full mounts list
        var mounts: [Pecan_LauncherMountSpec] = [
            .with { $0.source = workspacePath; $0.destination = "/home/\(agentName)"; $0.readOnly = false },
            .with { $0.source = "\(currentPath)/.build/aarch64-swift-linux-musl/release"; $0.destination = "/opt/pecan"; $0.readOnly = true },
        ]

        // Convert MountSpec shares to protobuf
        for share in shares {
            mounts.append(.with { $0.source = share.source; $0.destination = share.destination; $0.readOnly = share.readOnly })
        }

        var request = Pecan_LauncherRequest()
        request.spawn = .with {
            $0.sessionID = sessionID
            $0.grpcSocketPath = grpcSocketPath
            $0.agentName = agentName
            $0.mounts = mounts
        }

        let response = try await sendRequest(request)
        if !response.success {
            throw NSError(
                domain: "RemoteSpawner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage.isEmpty ? "Unknown spawn error" : response.errorMessage]
            )
        }
    }

    public func terminateAgent(sessionID: String) async throws {
        var request = Pecan_LauncherRequest()
        request.terminate = .with { $0.sessionID = sessionID }

        let response = try await sendRequest(request)
        if !response.success {
            throw NSError(
                domain: "RemoteSpawner", code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage.isEmpty ? "Unknown terminate error" : response.errorMessage]
            )
        }
    }

    private func sendRequest(_ request: Pecan_LauncherRequest) async throws -> Pecan_LauncherResponse {
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

        // Send length-prefixed protobuf
        let requestData: [UInt8] = try request.serializedBytes()
        var length = UInt32(requestData.count).bigEndian
        let headerWritten = withUnsafeBytes(of: &length) { ptr in
            write(fd, ptr.baseAddress!, 4)
        }
        guard headerWritten == 4 else {
            throw NSError(domain: "RemoteSpawner", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to write request length"])
        }
        let bodyWritten = requestData.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
        guard bodyWritten == requestData.count else {
            throw NSError(domain: "RemoteSpawner", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to write request body"])
        }

        // Read length-prefixed response
        var responseLengthBytes = [UInt8](repeating: 0, count: 4)
        let headerRead = read(fd, &responseLengthBytes, 4)
        guard headerRead == 4 else {
            throw NSError(domain: "RemoteSpawner", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to read response length"])
        }
        let responseLength = Int(UInt32(bigEndian: responseLengthBytes.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        }))

        var responseData = Data(count: responseLength)
        var totalRead = 0
        while totalRead < responseLength {
            let n = responseData.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress! + totalRead, responseLength - totalRead)
            }
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead == responseLength else {
            throw NSError(domain: "RemoteSpawner", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Incomplete response from launcher"])
        }

        return try Pecan_LauncherResponse(serializedBytes: responseData)
    }
}
