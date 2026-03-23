import Foundation
import Logging
import PecanShared
import SwiftProtobuf

@available(macOS 15.0, *)
func runLauncher() async throws {
    let spawner = ContainerSpawner()

    let currentPath = FileManager.default.currentDirectoryPath
    let runDir = URL(fileURLWithPath: currentPath).appendingPathComponent(".run")
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

    let socketPath = runDir.appendingPathComponent("launcher.sock").path
    // Remove stale socket
    try? FileManager.default.removeItem(atPath: socketPath)

    // Create Unix domain socket
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        logger.error("Failed to create socket: \(String(cString: strerror(errno)))")
        exit(1)
    }

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

    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        logger.error("Failed to bind socket: \(String(cString: strerror(errno)))")
        close(fd)
        exit(1)
    }

    guard listen(fd, 5) == 0 else {
        logger.error("Failed to listen on socket: \(String(cString: strerror(errno)))")
        close(fd)
        exit(1)
    }

    logger.info("PecanVMLauncher listening on \(socketPath)")

    // Accept connections in a loop
    while true {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(fd, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else {
            logger.error("Accept failed: \(String(cString: strerror(errno)))")
            continue
        }

        // Handle each connection in a detached task
        let spawnerRef = spawner
        Task.detached {
            await handleConnection(fd: clientFD, spawner: spawnerRef)
        }
    }
}

@available(macOS 15.0, *)
func writeLauncherResponse(fd: Int32, response: Pecan_LauncherResponse) {
    do {
        let responseData: [UInt8] = try response.serializedBytes()
        var length = UInt32(responseData.count).bigEndian
        _ = withUnsafeBytes(of: &length) { ptr in write(fd, ptr.baseAddress!, 4) }
        _ = responseData.withUnsafeBufferPointer { ptr in write(fd, ptr.baseAddress!, ptr.count) }
    } catch {
        logger.error("Failed to encode response: \(error)")
    }
}

@available(macOS 15.0, *)
func handleConnection(fd: Int32, spawner: ContainerSpawner) async {
    // Read 4-byte length prefix
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let headerRead = read(fd, &lengthBytes, 4)
    guard headerRead == 4 else {
        logger.warning("Failed to read request length")
        close(fd)
        return
    }
    let messageLength = Int(UInt32(bigEndian: lengthBytes.withUnsafeBufferPointer {
        $0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
    }))

    // Read message body
    var data = Data(count: messageLength)
    var totalRead = 0
    while totalRead < messageLength {
        let n = data.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress! + totalRead, messageLength - totalRead)
        }
        if n <= 0 { break }
        totalRead += n
    }
    guard totalRead == messageLength else {
        logger.warning("Incomplete request: got \(totalRead) of \(messageLength) bytes")
        close(fd)
        return
    }

    var response = Pecan_LauncherResponse()

    do {
        let request = try Pecan_LauncherRequest(serializedBytes: data)
        switch request.payload {
        case .spawn(let req):
            logger.info("Spawn request for session \(req.sessionID)")
            response.sessionID = req.sessionID
            do {
                try await spawner.spawnAgent(sessionID: req.sessionID, grpcSocketPath: req.grpcSocketPath, agentName: req.agentName, mounts: req.mounts)
                response.success = true
            } catch {
                logger.error("Spawn failed for \(req.sessionID): \(error)")
                response.success = false
                response.errorMessage = error.localizedDescription
            }
            writeLauncherResponse(fd: fd, response: response)
            close(fd)

        case .terminate(let req):
            logger.info("Terminate request for session \(req.sessionID)")
            response.sessionID = req.sessionID
            do {
                try await spawner.terminateAgent(sessionID: req.sessionID)
                response.success = true
            } catch {
                logger.error("Terminate failed for \(req.sessionID): \(error)")
                response.success = false
                response.errorMessage = error.localizedDescription
            }
            writeLauncherResponse(fd: fd, response: response)
            close(fd)

        case .exec(let req):
            logger.info("Exec request for session \(req.sessionID): \(req.command)")
            response.sessionID = req.sessionID
            response.success = true
            writeLauncherResponse(fd: fd, response: response)
            // fd stays open — execShell relays stdio then closes it
            await spawner.execShell(sessionID: req.sessionID, command: Array(req.command), socketFD: fd)

        case nil:
            logger.error("Empty launcher request")
            response.errorMessage = "Empty request payload"
            writeLauncherResponse(fd: fd, response: response)
            close(fd)
        }
    } catch {
        logger.error("Failed to decode request: \(error)")
        response.errorMessage = "Invalid request: \(error.localizedDescription)"
        writeLauncherResponse(fd: fd, response: response)
        close(fd)
    }
}

Task {
    do {
        if #available(macOS 15.0, *) {
            try await runLauncher()
        } else {
            logger.error("macOS 15.0 or later is required")
            exit(1)
        }
    } catch {
        logger.critical("Launcher error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
