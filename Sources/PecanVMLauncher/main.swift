import Foundation
import Logging

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
func handleConnection(fd: Int32, spawner: ContainerSpawner) async {
    defer { close(fd) }

    // Read all data until newline
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let bytesRead = read(fd, &buffer, buffer.count)
        if bytesRead <= 0 { break }
        data.append(contentsOf: buffer[0..<bytesRead])
        if data.contains(UInt8(ascii: "\n")) { break }
    }

    // Trim to first line
    if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
        data = data[data.startIndex..<newlineIndex]
    }

    guard !data.isEmpty else {
        logger.warning("Empty request received")
        return
    }

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    let response: LauncherResponse
    do {
        let request = try decoder.decode(LauncherRequest.self, from: data)
        switch request {
        case .spawn(let req):
            logger.info("Spawn request for session \(req.sessionID)")
            do {
                try await spawner.spawnAgent(sessionID: req.sessionID, grpcSocketPath: req.grpcSocketPath)
                response = .spawnOK(sessionID: req.sessionID)
            } catch {
                logger.error("Spawn failed for \(req.sessionID): \(error)")
                response = .spawnError(sessionID: req.sessionID, error: error.localizedDescription)
            }
        case .terminate(let req):
            logger.info("Terminate request for session \(req.sessionID)")
            do {
                try await spawner.terminateAgent(sessionID: req.sessionID)
                response = .terminateOK(sessionID: req.sessionID)
            } catch {
                logger.error("Terminate failed for \(req.sessionID): \(error)")
                response = .terminateError(sessionID: req.sessionID, error: error.localizedDescription)
            }
        }
    } catch {
        logger.error("Failed to decode request: \(error)")
        // Can't determine sessionID from malformed request
        response = LauncherResponse(type: "error", sessionID: "unknown", error: "Invalid request: \(error.localizedDescription)")
    }

    // Write response + newline
    do {
        var responseData = try encoder.encode(response)
        responseData.append(UInt8(ascii: "\n"))
        _ = responseData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
    } catch {
        logger.error("Failed to encode response: \(error)")
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
