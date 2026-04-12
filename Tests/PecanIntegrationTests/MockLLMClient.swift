import Foundation

/// HTTP client for controlling the pecan-mock-llm server during integration tests.
struct MockLLMClient {
    let port: Int

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: - Health

    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await health()) == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        throw TestError.timeout("Mock LLM did not become ready in \(timeout)s")
    }

    func health() async throws -> Bool {
        let (_, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("control/health"))
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Request capture

    /// Returns all requests captured since last clear, as raw JSON objects.
    func capturedRequests() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("control/requests"))
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Clears all captured requests.
    func clearRequests() async throws {
        var req = URLRequest(url: base.appendingPathComponent("control/requests"))
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Response queue

    /// Enqueue a plain text response. The agent will receive this as a stop completion.
    func enqueueTextResponse(_ content: String, finishReason: String = "stop") async throws {
        let resp: [String: Any] = [
            "id": "mock-queued-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "mock",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": finishReason
            ]],
            "usage": ["prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30]
        ]
        try await enqueueRawResponse(resp)
    }

    /// Enqueue a tool-call response.
    func enqueueToolCall(name: String, arguments: String, callID: String? = nil) async throws {
        let id = callID ?? "call_\(UUID().uuidString.prefix(8))"
        let resp: [String: Any] = [
            "id": "mock-tool-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "mock",
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [[
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": arguments]
                    ]]
                ],
                "finish_reason": "tool_calls"
            ]],
            "usage": ["prompt_tokens": 20, "completion_tokens": 15, "total_tokens": 35]
        ]
        try await enqueueRawResponse(resp)
    }

    func enqueueRawResponse(_ body: [String: Any]) async throws {
        var req = URLRequest(url: base.appendingPathComponent("control/queue"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 204 { throw TestError.unexpected("Enqueue failed with status \(status)") }
    }

    func clearQueue() async throws {
        var req = URLRequest(url: base.appendingPathComponent("control/queue"))
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Assertion helpers

    /// Waits until at least `count` requests have been captured, then returns them.
    func waitForRequests(count: Int, timeout: TimeInterval = 15) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reqs = try await capturedRequests()
            if reqs.count >= count { return reqs }
            try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        let got = try await capturedRequests()
        throw TestError.timeout("Expected \(count) LLM request(s), got \(got.count) after \(timeout)s")
    }

    /// Returns the messages array from the most recent captured request.
    func lastRequestMessages() async throws -> [[String: Any]] {
        let reqs = try await capturedRequests()
        guard let last = reqs.last else { throw TestError.unexpected("No captured requests") }
        return (last["messages"] as? [[String: Any]]) ?? []
    }

    /// Returns the system message content from the most recent request.
    func lastSystemPrompt() async throws -> String? {
        let msgs = try await lastRequestMessages()
        return msgs.first(where: { $0["role"] as? String == "system" })?["content"] as? String
    }
}

// MARK: - Error types

enum TestError: Error, CustomStringConvertible {
    case timeout(String)
    case unexpected(String)
    case processLaunchFailed(String)

    var description: String {
        switch self {
        case .timeout(let msg): return "Timeout: \(msg)"
        case .unexpected(let msg): return "Unexpected: \(msg)"
        case .processLaunchFailed(let msg): return "Process launch failed: \(msg)"
        }
    }
}
