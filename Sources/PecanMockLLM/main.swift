/// pecan-mock-llm — Scriptable OpenAI-compatible HTTP stub for integration tests.
///
/// Endpoints:
///   POST /v1/chat/completions  — Returns next queued response (or default). Records request.
///   GET  /control/health       — 200 OK
///   GET  /control/requests     — JSON array of all captured requests
///   DELETE /control/requests   — Clear captured requests; returns 204
///   GET  /control/queue        — JSON array of queued responses
///   POST /control/queue        — Enqueue a scripted response body; returns 204
///   DELETE /control/queue      — Clear response queue; returns 204
///
/// Usage:
///   pecan-mock-llm [--port <n>]   (default port: 11434)

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Thread-safe state

final class MockState: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []   // raw JSON strings
    private var _queue: [String] = []      // raw JSON response strings

    func recordRequest(_ json: String) {
        lock.withLock { _requests.append(json) }
    }

    func dequeueResponse() -> String? {
        lock.withLock { _queue.isEmpty ? nil : _queue.removeFirst() }
    }

    func enqueueResponse(_ json: String) {
        lock.withLock { _queue.append(json) }
    }

    func allRequests() -> String {
        let items = lock.withLock { _requests }
        return "[\(items.joined(separator: ","))]"
    }

    func allQueued() -> String {
        let items = lock.withLock { _queue }
        return "[\(items.joined(separator: ","))]"
    }

    func clearRequests() {
        lock.withLock { _requests = [] }
    }

    func clearQueue() {
        lock.withLock { _queue = [] }
    }
}

let mockState = MockState()

// MARK: - Default response

func makeDefaultResponse(requestBody: [String: Any]?) -> String {
    // Check if caller requested tools — if so, return stop with no tool calls
    let id = "mock-\(UUID().uuidString.prefix(8))"
    let created = Int(Date().timeIntervalSince1970)
    let resp: [String: Any] = [
        "id": id,
        "object": "chat.completion",
        "created": created,
        "model": "mock",
        "choices": [[
            "index": 0,
            "message": [
                "role": "assistant",
                "content": "Task complete."
            ],
            "finish_reason": "stop"
        ]],
        "usage": [
            "prompt_tokens": 50,
            "completion_tokens": 5,
            "total_tokens": 55
        ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: resp)
    return String(data: data, encoding: .utf8)!
}

// MARK: - HTTP helpers

func readHTTPRequest(fd: Int32) -> (method: String, path: String, headers: [String: String], body: Data)? {
    // Read byte-by-byte until we see \r\n\r\n
    var headerBuf = [UInt8]()
    let term = Array("\r\n\r\n".utf8)
    var oneByte = [UInt8](repeating: 0, count: 1)

    while headerBuf.count < 65536 {
        guard read(fd, &oneByte, 1) == 1 else { return nil }
        headerBuf.append(oneByte[0])
        if headerBuf.count >= 4, Array(headerBuf.suffix(4)) == term { break }
    }

    guard let headerStr = String(bytes: headerBuf, encoding: .utf8) else { return nil }
    let lines = headerStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }
    let method = parts[0]
    let path = parts[1]

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where line.contains(":") {
        let idx = line.firstIndex(of: ":")!
        let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }

    var body = Data()
    if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
        var buf = [UInt8](repeating: 0, count: len)
        var read_so_far = 0
        while read_so_far < len {
            let n = read(fd, &buf[read_so_far], len - read_so_far)
            if n <= 0 { break }
            read_so_far += n
        }
        body = Data(buf.prefix(read_so_far))
    }

    return (method: method, path: path, headers: headers, body: body)
}

func writeHTTPResponse(fd: Int32, status: Int, statusText: String, body: String, contentType: String = "application/json") {
    let bodyBytes = body.utf8
    let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n\(body)"
    response.withCString { ptr in
        _ = Foundation.write(fd, ptr, strlen(ptr))
    }
}

// MARK: - Request handler

func handleConnection(fd: Int32) {
    defer { close(fd) }

    guard let req = readHTTPRequest(fd: fd) else { return }
    let method = req.method.uppercased()
    let path = req.path.components(separatedBy: "?")[0]  // strip query string

    switch (method, path) {
    case ("POST", "/v1/chat/completions"):
        let bodyStr = String(data: req.body, encoding: .utf8) ?? "{}"
        let parsed = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        mockState.recordRequest(bodyStr)

        let responseBody: String
        if let queued = mockState.dequeueResponse() {
            responseBody = queued
        } else {
            responseBody = makeDefaultResponse(requestBody: parsed)
        }
        writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: responseBody)

    case ("GET", "/control/health"):
        writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: "{\"status\":\"ok\"}")

    case ("GET", "/control/requests"):
        writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: mockState.allRequests())

    case ("DELETE", "/control/requests"):
        mockState.clearRequests()
        writeHTTPResponse(fd: fd, status: 204, statusText: "No Content", body: "")

    case ("GET", "/control/queue"):
        writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: mockState.allQueued())

    case ("POST", "/control/queue"):
        let bodyStr = String(data: req.body, encoding: .utf8) ?? ""
        guard !bodyStr.isEmpty else {
            writeHTTPResponse(fd: fd, status: 400, statusText: "Bad Request", body: "{\"error\":\"empty body\"}")
            return
        }
        // Validate it's valid JSON
        guard (try? JSONSerialization.jsonObject(with: req.body)) != nil else {
            writeHTTPResponse(fd: fd, status: 400, statusText: "Bad Request", body: "{\"error\":\"invalid JSON\"}")
            return
        }
        mockState.enqueueResponse(bodyStr)
        writeHTTPResponse(fd: fd, status: 204, statusText: "No Content", body: "")

    case ("DELETE", "/control/queue"):
        mockState.clearQueue()
        writeHTTPResponse(fd: fd, status: 204, statusText: "No Content", body: "")

    default:
        writeHTTPResponse(fd: fd, status: 404, statusText: "Not Found", body: "{\"error\":\"not found\"}")
    }
}

// MARK: - Main

var port: UInt16 = 11434
var args = CommandLine.arguments.dropFirst()
while !args.isEmpty {
    let arg = args.removeFirst()
    if arg == "--port", let next = args.first, let p = UInt16(next) {
        port = p
        args = args.dropFirst()
    }
}

let serverFD = socket(AF_INET, SOCK_STREAM, 0)
guard serverFD >= 0 else {
    fputs("error: failed to create socket\n", stderr)
    exit(1)
}

var reuse: Int32 = 1
setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr = in_addr(s_addr: INADDR_ANY)

let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0 else {
    fputs("error: failed to bind port \(port): \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

listen(serverFD, 64)

// Write port to stdout so parent processes can discover it
print("MOCK_LLM_PORT=\(port)")
fflush(stdout)

fputs("pecan-mock-llm listening on port \(port)\n", stderr)

while true {
    let clientFD = accept(serverFD, nil, nil)
    if clientFD < 0 { continue }
    Thread.detachNewThread {
        handleConnection(fd: clientFD)
    }
}
