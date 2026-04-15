import Testing
import Foundation
import PecanShared
@testable import PecanAgentCore

// MARK: - Helpers

/// A simple echo tool for use in tests.
private struct EchoTool: PecanTool, Sendable {
    let name = "test_echo"
    let description = "Echoes the input text"
    let parametersJSONSchema = """
    {"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
    """
    func execute(argumentsJSON: String) async throws -> String {
        return "echo: \(argumentsJSON)"
    }
}

/// A minimal AgentDependencies wired to fresh (empty) actor instances.
private func testDeps(extraTools: [any PecanTool] = []) async -> AgentDependencies {
    let tm = ToolManager()
    for tool in extraTools {
        await tm.register(tool: tool)
    }
    return AgentDependencies(
        toolManager: tm,
        promptComposer: PromptComposer(),
        hookManager: HookManager()
    )
}

// MARK: - sendTypedProgress

@Suite("sendTypedProgress")
struct SendTypedProgressTests {

    @Test("emits a progress event with correct type field")
    func basicTypeField() async throws {
        let sink = TestEventSink()
        try await sendTypedProgress(sink, type: "thinking")

        let events = await sink.sent
        #expect(events.count == 1)
        guard case .progress = events[0].payload else {
            Issue.record("expected a progress event")
            return
        }

        let json = try TestEventSink.decodeProgressJSON(events[0])
        #expect(json["type"] == "thinking")
    }

    @Test("includes extra fields alongside type")
    func extraFields() async throws {
        let sink = TestEventSink()
        try await sendTypedProgress(sink, type: "response", fields: ["text": "Hello world"])

        let events = await sink.sent
        #expect(events.count == 1)
        let json = try TestEventSink.decodeProgressJSON(events[0])
        #expect(json["type"] == "response")
        #expect(json["text"] == "Hello world")
    }

    @Test("tool_call type includes name and arguments fields")
    func toolCallFields() async throws {
        let sink = TestEventSink()
        try await sendTypedProgress(
            sink, type: "tool_call",
            fields: ["name": "read_file", "arguments": "{\"path\":\"/foo\"}"]
        )

        let json = try TestEventSink.decodeProgressJSON(await sink.sent[0])
        #expect(json["type"] == "tool_call")
        #expect(json["name"] == "read_file")
        #expect(json["arguments"] == "{\"path\":\"/foo\"}")
    }
}

// MARK: - onCompletionResponse — plain text

@Suite("CompletionResponse plain text")
struct CompletionResponsePlainTextTests {

    private func makeHandler(sink: TestEventSink) async -> AgentEventHandler {
        let deps = await testDeps()
        return AgentEventHandler(sink: sink, agentID: "a", sessionID: "s", deps: deps)
    }

    private func completionCommand(responseJson: String) -> Pecan_HostCommand {
        var resp = Pecan_LLMCompletionResponse()
        resp.requestID = UUID().uuidString
        resp.responseJson = responseJson
        var cmd = Pecan_HostCommand()
        cmd.completionResponse = resp
        return cmd
    }

    @Test("plain text reply emits assistant context message then response progress")
    func plainTextFlow() async throws {
        let sink = TestEventSink()
        let handler = await makeHandler(sink: sink)

        let responseJson = """
        {"choices":[{"message":{"role":"assistant","content":"Hi there"},"finish_reason":"stop"}]}
        """
        try await handler.handle(completionCommand(responseJson: responseJson))

        let events = await sink.sent
        // Must have at least: 1 context message (assistant) + 1 progress (response)
        #expect(events.count >= 2)

        let assistantMsgs = await sink.contextMessages(role: "assistant")
        #expect(assistantMsgs.count == 1)

        guard case .contextCommand(let c) = assistantMsgs[0].payload else {
            Issue.record("Expected contextCommand payload")
            return
        }
        #expect(c.addMessage.content == "Hi there")

        let responseProgress = await sink.progressEvents(type: "response")
        #expect(responseProgress.count == 1)

        let json = try TestEventSink.decodeProgressJSON(responseProgress[0])
        #expect(json["text"] == "Hi there")
    }

    @Test("error message from LLM emits response progress with error text")
    func llmErrorMessage() async throws {
        let sink = TestEventSink()
        let handler = await makeHandler(sink: sink)

        var resp = Pecan_LLMCompletionResponse()
        resp.requestID = UUID().uuidString
        resp.errorMessage = "rate limited"
        var cmd = Pecan_HostCommand()
        cmd.completionResponse = resp

        try await handler.handle(cmd)

        let responseProgress = await sink.progressEvents(type: "response")
        #expect(responseProgress.count == 1)

        let json = try TestEventSink.decodeProgressJSON(responseProgress[0])
        #expect(json["text"]?.contains("rate limited") == true)
    }
}

// MARK: - Tool execution

@Suite("Tool execution serialization")
struct ToolExecutionTests {

    @Test("tool call result context message has correct tool_call_id in metadataJson")
    func toolCallIdInContextMessage() async throws {
        let sink = TestEventSink()
        let deps = await testDeps(extraTools: [EchoTool()])
        let handler = AgentEventHandler(sink: sink, agentID: "a", sessionID: "s", deps: deps)

        let responseJson = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_abc123","type":"function","function":{"name":"test_echo","arguments":"{\\"text\\":\\"hello\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        var resp = Pecan_LLMCompletionResponse()
        resp.requestID = UUID().uuidString
        resp.responseJson = responseJson
        var cmd = Pecan_HostCommand()
        cmd.completionResponse = resp

        try await handler.handle(cmd)

        // Tool calls run in a spawned Task — wait for the tool result context message
        // Expected events: assistant ctx msg + tool_call progress + tool_result progress
        //                  + tool ctx msg (+ thinking progress + completion request)
        try await sink.waitForEvents(count: 4, timeout: 5.0)

        let toolCtxMsgs = await sink.contextMessages(role: "tool")
        #expect(toolCtxMsgs.count == 1)

        guard case .contextCommand(let c) = toolCtxMsgs[0].payload else {
            Issue.record("Expected contextCommand payload")
            return
        }
        let metaJson = c.addMessage.metadataJson
        #expect(!metaJson.isEmpty)

        let meta = try JSONDecoder().decode(
            [String: String].self,
            from: metaJson.data(using: .utf8)!
        )
        #expect(meta["tool_call_id"] == "call_abc123")
    }

    @Test("tool call progress events are emitted in order: tool_call then tool_result")
    func toolCallProgressOrder() async throws {
        let sink = TestEventSink()
        let deps = await testDeps(extraTools: [EchoTool()])
        let handler = AgentEventHandler(sink: sink, agentID: "a", sessionID: "s", deps: deps)

        let responseJson = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_xyz","type":"function","function":{"name":"test_echo","arguments":"{\\"text\\":\\"world\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        var resp = Pecan_LLMCompletionResponse()
        resp.requestID = UUID().uuidString
        resp.responseJson = responseJson
        var cmd = Pecan_HostCommand()
        cmd.completionResponse = resp

        try await handler.handle(cmd)
        try await sink.waitForEvents(count: 4, timeout: 5.0)

        let toolCallProgress = await sink.progressEvents(type: "tool_call")
        let toolResultProgress = await sink.progressEvents(type: "tool_result")
        #expect(toolCallProgress.count == 1)
        #expect(toolResultProgress.count == 1)

        // tool_call must appear before tool_result in the stream
        let allEvents = await sink.sent
        let callIdx = allEvents.firstIndex(where: { event in
            guard case .progress(let p) = event.payload,
                  let d = try? JSONSerialization.jsonObject(
                    with: p.statusMessage.data(using: .utf8) ?? Data()
                  ) as? [String: String]
            else { return false }
            return d["type"] == "tool_call"
        })
        let resultIdx = allEvents.firstIndex(where: { event in
            guard case .progress(let p) = event.payload,
                  let d = try? JSONSerialization.jsonObject(
                    with: p.statusMessage.data(using: .utf8) ?? Data()
                  ) as? [String: String]
            else { return false }
            return d["type"] == "tool_result"
        })
        if let ci = callIdx, let ri = resultIdx {
            #expect(ci < ri)
        } else {
            Issue.record("Could not find tool_call or tool_result progress events")
        }
    }

    @Test("tool result contains the tool name in progress payload")
    func toolResultContainsName() async throws {
        let sink = TestEventSink()
        let deps = await testDeps(extraTools: [EchoTool()])
        let handler = AgentEventHandler(sink: sink, agentID: "a", sessionID: "s", deps: deps)

        let responseJson = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"test_echo","arguments":"{\\"text\\":\\"ping\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        var resp = Pecan_LLMCompletionResponse()
        resp.requestID = UUID().uuidString
        resp.responseJson = responseJson
        var cmd = Pecan_HostCommand()
        cmd.completionResponse = resp

        try await handler.handle(cmd)
        try await sink.waitForEvents(count: 4, timeout: 5.0)

        let resultProgress = await sink.progressEvents(type: "tool_result")
        #expect(resultProgress.count == 1)

        let json = try TestEventSink.decodeProgressJSON(resultProgress[0])
        #expect(json["name"] == "test_echo")
        #expect(json["result"]?.contains("ping") == true)
    }
}

// MARK: - Tool definitions

@Suite("Tool definition serialization")
struct ToolDefinitionTests {

    @Test("getToolDefinitions produces valid JSON array with type:function entries")
    func basicStructure() async throws {
        let tm = ToolManager()
        await tm.register(tool: EchoTool())

        let data = try await tm.getToolDefinitions()
        let defs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(defs != nil)
        #expect(defs?.count == 1)

        let first = defs?.first
        #expect(first?["type"] as? String == "function")

        let fn = first?["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "test_echo")
        #expect((fn?["description"] as? String)?.isEmpty == false)
        #expect(fn?["parameters"] != nil)
    }

    @Test("getToolDefinitions respects tag filter")
    func tagFilter() async throws {
        struct TaggedTool: PecanTool, Sendable {
            let name = "tagged_tool"
            let description = "A tagged tool"
            let parametersJSONSchema = "{\"type\":\"object\",\"properties\":{}}"
            var tags: Set<String> { ["special"] }
            func execute(argumentsJSON: String) async throws -> String { "" }
        }

        let tm = ToolManager()
        await tm.register(tool: EchoTool())    // tags: ["core"] (default)
        await tm.register(tool: TaggedTool())  // tags: ["special"]

        let specialData = try await tm.getToolDefinitions(tags: ["special"])
        let specialDefs = try JSONSerialization.jsonObject(with: specialData) as? [[String: Any]]
        #expect(specialDefs?.count == 1)
        let fn = specialDefs?.first?["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "tagged_tool")

        let coreData = try await tm.getToolDefinitions(tags: ["core"])
        let coreDefs = try JSONSerialization.jsonObject(with: coreData) as? [[String: Any]]
        #expect(coreDefs?.count == 1)
        let coreFn = coreDefs?.first?["function"] as? [String: Any]
        #expect(coreFn?["name"] as? String == "test_echo")
    }
}
