import Testing
import Foundation

/// Tests for the mock LLM server itself — verifies request capture, response queuing,
/// and the control API work correctly before relying on them in higher-level tests.
///
/// These tests start pecan-mock-llm as a subprocess and interact with it via HTTP.
@Suite("MockLLM", .serialized)
struct MockLLMTests {

    // MARK: - Helpers

    func withMockLLM(_ body: (MockLLMClient) async throws -> Void) async throws {
        let buildDir = TestHarness.buildDirectory()
        let exe = buildDir.appendingPathComponent("pecan-mock-llm")
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw TestError.processLaunchFailed("pecan-mock-llm not found. Run 'swift build' first.")
        }

        // Use a port offset from PID to reduce test collisions
        let port = 18000 + (Int(ProcessInfo.processInfo.processIdentifier) % 500)
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--port", "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        defer { proc.terminate() }

        let client = MockLLMClient(port: port)
        try await client.waitUntilReady(timeout: 10)
        try await client.clearRequests()
        try await client.clearQueue()

        try await body(client)
    }

    func postCompletion(port: Int, messages: [[String: Any]]) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "model": "mock",
            "messages": messages
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Health

    @Test("health endpoint returns 200")
    func healthCheck() async throws {
        try await withMockLLM { client in
            let ok = try await client.health()
            #expect(ok == true)
        }
    }

    // MARK: - Default response

    @Test("returns default stop response when queue is empty")
    func defaultResponse() async throws {
        try await withMockLLM { client in
            let port = client.port
            let resp = try await postCompletion(port: port, messages: [
                ["role": "user", "content": "Hello"]
            ])
            let choices = resp["choices"] as? [[String: Any]]
            let first = choices?.first
            let message = first?["message"] as? [String: Any]
            #expect(message?["role"] as? String == "assistant")
            #expect(first?["finish_reason"] as? String == "stop")
        }
    }

    // MARK: - Request capture

    @Test("captures incoming requests")
    func capturesRequests() async throws {
        try await withMockLLM { client in
            let port = client.port
            _ = try await postCompletion(port: port, messages: [
                ["role": "system", "content": "You are a test agent."],
                ["role": "user", "content": "Ping"]
            ])

            let reqs = try await client.capturedRequests()
            #expect(reqs.count == 1)
            let msgs = reqs[0]["messages"] as? [[String: Any]]
            #expect(msgs?.count == 2)
            #expect(msgs?[0]["role"] as? String == "system")
            #expect(msgs?[1]["content"] as? String == "Ping")
        }
    }

    @Test("captures multiple requests in order")
    func capturesMultipleRequests() async throws {
        try await withMockLLM { client in
            let port = client.port
            for i in 1...3 {
                _ = try await postCompletion(port: port, messages: [
                    ["role": "user", "content": "Request \(i)"]
                ])
            }
            let reqs = try await client.capturedRequests()
            #expect(reqs.count == 3)
        }
    }

    @Test("clearRequests empties the capture log")
    func clearRequestsWorks() async throws {
        try await withMockLLM { client in
            let port = client.port
            _ = try await postCompletion(port: port, messages: [["role": "user", "content": "x"]])
            try await client.clearRequests()
            let reqs = try await client.capturedRequests()
            #expect(reqs.isEmpty)
        }
    }

    // MARK: - Response queue

    @Test("returns queued text response")
    func queuedTextResponse() async throws {
        try await withMockLLM { client in
            try await client.enqueueTextResponse("This is a scripted reply.")
            let port = client.port
            let resp = try await postCompletion(port: port, messages: [["role": "user", "content": "go"]])
            let choices = resp["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            #expect(msg?["content"] as? String == "This is a scripted reply.")
        }
    }

    @Test("queued responses consumed in FIFO order")
    func fifoQueue() async throws {
        try await withMockLLM { client in
            try await client.enqueueTextResponse("First")
            try await client.enqueueTextResponse("Second")
            let port = client.port
            let r1 = try await postCompletion(port: port, messages: [["role": "user", "content": "go"]])
            let r2 = try await postCompletion(port: port, messages: [["role": "user", "content": "go"]])
            let c1 = (r1["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            let c2 = (r2["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            #expect(c1?["content"] as? String == "First")
            #expect(c2?["content"] as? String == "Second")
        }
    }

    @Test("falls back to default after queue exhausted")
    func queueExhaustion() async throws {
        try await withMockLLM { client in
            try await client.enqueueTextResponse("Scripted")
            let port = client.port
            _ = try await postCompletion(port: port, messages: [["role": "user", "content": "1"]])
            let r2 = try await postCompletion(port: port, messages: [["role": "user", "content": "2"]])
            let choices = r2["choices"] as? [[String: Any]]
            #expect(choices?.first?["finish_reason"] as? String == "stop")
        }
    }

    @Test("queued tool call response has correct structure")
    func queuedToolCall() async throws {
        try await withMockLLM { client in
            try await client.enqueueToolCall(
                name: "read_file",
                arguments: "{\"path\":\"/project/main.swift\"}",
                callID: "call_test_001"
            )
            let port = client.port
            let resp = try await postCompletion(port: port, messages: [["role": "user", "content": "read a file"]])
            let choices = resp["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            let toolCalls = msg?["tool_calls"] as? [[String: Any]]
            #expect(toolCalls?.count == 1)
            #expect(toolCalls?.first?["id"] as? String == "call_test_001")
            let fn = toolCalls?.first?["function"] as? [String: Any]
            #expect(fn?["name"] as? String == "read_file")
            #expect(choices?.first?["finish_reason"] as? String == "tool_calls")
        }
    }

    @Test("clearQueue removes pending responses")
    func clearQueueWorks() async throws {
        try await withMockLLM { client in
            try await client.enqueueTextResponse("Should be cleared")
            try await client.clearQueue()
            let port = client.port
            let resp = try await postCompletion(port: port, messages: [["role": "user", "content": "go"]])
            let choices = resp["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            // Default response, not the queued one
            #expect(msg?["content"] as? String != "Should be cleared")
        }
    }
}
