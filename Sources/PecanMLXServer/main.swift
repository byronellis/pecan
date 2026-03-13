import Foundation
import Logging
import PecanShared
import SwiftProtobuf

func runMLXServer() async throws {
    let modelManager = ModelManager()

    let currentPath = FileManager.default.currentDirectoryPath
    let runDir = URL(fileURLWithPath: currentPath).appendingPathComponent(".run")
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

    let socketPath = runDir.appendingPathComponent("mlx.sock").path
    try? FileManager.default.removeItem(atPath: socketPath)

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

    logger.info("PecanMLXServer listening on \(socketPath)")

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

        let mgr = modelManager
        Task.detached {
            await handleConnection(fd: clientFD, modelManager: mgr)
        }
    }
}

func handleConnection(fd: Int32, modelManager: ModelManager) async {
    defer { close(fd) }

    // Read 4-byte length prefix
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let headerRead = read(fd, &lengthBytes, 4)
    guard headerRead == 4 else {
        logger.warning("Failed to read request length")
        return
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
    guard totalRead == messageLength else {
        logger.warning("Incomplete request: got \(totalRead) of \(messageLength) bytes")
        return
    }

    var response = Pecan_MLXResponse()

    do {
        let request = try Pecan_MLXRequest(serializedBytes: data)
        switch request.payload {
        case .loadModel(let req):
            response.requestID = req.requestID
            logger.info("Load model request: alias=\(req.alias) repo=\(req.huggingfaceRepo)")
            do {
                try await modelManager.load(alias: req.alias, repo: req.huggingfaceRepo)
                response.loadModel = .with { $0.alias = req.alias; $0.success = true }
            } catch {
                logger.error("Failed to load model '\(req.alias)': \(error)")
                response.error = .with { $0.errorMessage = error.localizedDescription }
            }

        case .unloadModel(let req):
            response.requestID = req.requestID
            await modelManager.unload(alias: req.alias)
            response.unloadModel = .with { $0.alias = req.alias; $0.success = true }

        case .generate(let req):
            response.requestID = req.requestID
            logger.info("Generate request: alias=\(req.alias) maxTokens=\(req.maxTokens)")
            do {
                let result = try await modelManager.generate(
                    alias: req.alias,
                    messages: req.messages,
                    prompt: req.prompt,
                    temperature: req.temperature,
                    maxTokens: Int(req.maxTokens)
                )
                response.generate = .with {
                    $0.text = result.text
                    $0.promptTokens = Int32(result.promptTokens)
                    $0.completionTokens = Int32(result.completionTokens)
                    $0.isFinal = true
                }
            } catch {
                logger.error("Generate failed: \(error)")
                response.error = .with { $0.errorMessage = error.localizedDescription }
            }

        case .listModels(let req):
            response.requestID = req.requestID
            let loaded = await modelManager.listLoaded()
            response.listModels = .with {
                $0.models = loaded.map { item in
                    .with { $0.alias = item.alias; $0.huggingfaceRepo = item.repo }
                }
            }

        case nil:
            logger.error("Empty MLX request")
            response.error = .with { $0.errorMessage = "Empty request payload" }
        }
    } catch {
        logger.error("Failed to decode MLX request: \(error)")
        response.error = .with { $0.errorMessage = "Invalid request: \(error.localizedDescription)" }
    }

    // Write length-prefixed response
    do {
        let responseData: [UInt8] = try response.serializedBytes()
        var length = UInt32(responseData.count).bigEndian
        _ = withUnsafeBytes(of: &length) { ptr in
            write(fd, ptr.baseAddress!, 4)
        }
        _ = responseData.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
    } catch {
        logger.error("Failed to encode response: \(error)")
    }
}

Task {
    do {
        try await runMLXServer()
    } catch {
        logger.critical("MLX Server error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
