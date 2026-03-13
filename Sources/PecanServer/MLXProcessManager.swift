import Foundation
import Logging
import PecanShared
import SwiftProtobuf

/// Manages the pecan-mlx-server child process lifecycle.
public final class MLXProcessManager: Sendable {
    private let process: Process
    public let socketPath: String

    /// Spawns the mlx-server as a child process and waits for its socket to appear.
    public init() throws {
        let currentPath = FileManager.default.currentDirectoryPath
        socketPath = "\(currentPath)/.run/mlx.sock"

        // Resolve binary: sibling of the running server binary, fallback to .build/debug/
        let serverBinary = CommandLine.arguments[0]
        let serverDir = (serverBinary as NSString).deletingLastPathComponent
        var mlxPath = "\(serverDir)/pecan-mlx-server"
        if !FileManager.default.isExecutableFile(atPath: mlxPath) {
            mlxPath = "\(currentPath)/.build/debug/pecan-mlx-server"
        }

        guard FileManager.default.isExecutableFile(atPath: mlxPath) else {
            throw MLXManagerError.binaryNotFound(mlxPath)
        }

        // Remove stale socket
        try? FileManager.default.removeItem(atPath: socketPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mlxPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: currentPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        proc.terminationHandler = { p in
            logger.error("pecan-mlx-server exited unexpectedly (status \(p.terminationStatus))")
        }

        try proc.run()
        logger.info("Launched pecan-mlx-server (pid \(proc.processIdentifier)) from \(mlxPath)")
        self.process = proc
    }

    /// Waits for the MLX server Unix socket to appear.
    public func waitForSocket(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                logger.info("MLX server socket ready at \(socketPath)")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw MLXManagerError.socketTimeout(socketPath)
    }

    /// Sends a request to the MLX server and returns the response.
    public func sendRequest(_ request: Pecan_MLXRequest, timeout: TimeInterval = 120) throws -> Pecan_MLXResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MLXManagerError.socketError("Failed to create socket: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

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
            throw MLXManagerError.socketError("Failed to connect to MLX server at \(socketPath): \(String(cString: strerror(errno)))")
        }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Send length-prefixed protobuf
        let requestData: [UInt8] = try request.serializedBytes()
        var length = UInt32(requestData.count).bigEndian
        let headerWritten = withUnsafeBytes(of: &length) { ptr in
            write(fd, ptr.baseAddress!, 4)
        }
        guard headerWritten == 4 else {
            throw MLXManagerError.socketError("Failed to write request length")
        }
        let bodyWritten = requestData.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
        guard bodyWritten == requestData.count else {
            throw MLXManagerError.socketError("Failed to write request body")
        }

        // Read length-prefixed response
        var responseLengthBytes = [UInt8](repeating: 0, count: 4)
        let headerRead = read(fd, &responseLengthBytes, 4)
        guard headerRead == 4 else {
            throw MLXManagerError.socketError("Failed to read response length")
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
            throw MLXManagerError.socketError("Incomplete response from MLX server")
        }

        return try Pecan_MLXResponse(serializedBytes: responseData)
    }

    /// Terminates the MLX server process.
    public func shutdown() {
        guard process.isRunning else { return }
        logger.info("Terminating pecan-mlx-server (pid \(process.processIdentifier))")
        process.terminate()
        process.waitUntilExit()
    }

    public enum MLXManagerError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case socketTimeout(String)
        case socketError(String)

        public var description: String {
            switch self {
            case .binaryNotFound(let path): return "MLX server binary not found at \(path)"
            case .socketTimeout(let path): return "Timed out waiting for MLX server socket at \(path)"
            case .socketError(let msg): return msg
            }
        }
    }
}
