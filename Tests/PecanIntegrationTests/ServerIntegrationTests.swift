import Testing
import Foundation
import GRPC
import NIO
import PecanShared

/// Integration tests for pecan-server. Starts a real server subprocess + mock LLM,
/// then connects via gRPC to verify end-to-end behavior.
///
/// These tests do NOT start containers — the agent side is simulated by a
/// "fake agent" that connects as a gRPC client on the AgentService.
@Suite("ServerIntegration", .serialized)
struct ServerIntegrationTests {

    // MARK: - gRPC helpers

    func makeGroup() -> MultiThreadedEventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func makeUIClient(port: Int, group: MultiThreadedEventLoopGroup) throws -> Pecan_ClientServiceAsyncClient {
        let channel = try GRPCChannelPool.with(
            target: .host("127.0.0.1", port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )
        return Pecan_ClientServiceAsyncClient(channel: channel)
    }

    func makeAgentClient(port: Int, group: MultiThreadedEventLoopGroup) throws -> Pecan_AgentServiceAsyncClient {
        let channel = try GRPCChannelPool.with(
            target: .host("127.0.0.1", port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )
        return Pecan_AgentServiceAsyncClient(channel: channel)
    }

    // MARK: - Server startup

    @Test("server starts and writes server.json")
    func serverStarts() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        #expect(harness.serverPort > 0)
        #expect(harness.serverPort < 65536)
    }

    @Test("mock LLM is reachable from test harness")
    func mockLLMReachable() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let ok = try await harness.mockLLM.health()
        #expect(ok)
    }

    // MARK: - Session lifecycle

    @Test("UI client can start a task and receive SessionStarted")
    func startTask() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let client = try makeUIClient(port: harness.serverPort, group: group)
        let call = client.makeStreamEventsCall()
        defer { call.requestStream.finish() }

        var msg = Pecan_ClientMessage()
        msg.startTask = Pecan_StartTaskRequest.with {
            $0.initialPrompt = "Hello from integration test"
        }
        try await call.requestStream.send(msg)

        // Wait for SessionStarted
        var sessionID: String?
        for try await response in call.responseStream {
            if case .sessionStarted(let started) = response.payload {
                sessionID = started.sessionID
                break
            }
        }

        #expect(sessionID != nil)
        #expect(!(sessionID?.isEmpty ?? true))
    }

    @Test("ListSessionsRequest returns active sessions")
    func listSessions() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let client = try makeUIClient(port: harness.serverPort, group: group)
        let call = client.makeStreamEventsCall()
        defer { call.requestStream.finish() }

        // Start a task first
        var startMsg = Pecan_ClientMessage()
        startMsg.startTask = Pecan_StartTaskRequest.with {
            $0.initialPrompt = "Test session for listing"
        }
        try await call.requestStream.send(startMsg)

        // Wait for session started, then request list
        var sawList = false
        var listedCount = 0

        for try await response in call.responseStream {
            switch response.payload {
            case .sessionStarted:
                var listMsg = Pecan_ClientMessage()
                listMsg.listSessions = Pecan_ListSessionsRequest()
                try await call.requestStream.send(listMsg)

            case .sessionList(let list):
                listedCount = list.sessions.count
                sawList = true
                break

            default:
                break
            }
            if sawList { break }
        }

        #expect(sawList)
        #expect(listedCount >= 1)
    }

    // MARK: - Fake agent + LLM proxy

    @Test("fake agent registers and receives initial prompt via LLM proxy")
    func agentRegistrationAndLLMProxy() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        // UI: start a task, collect session ID
        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        var startMsg = Pecan_ClientMessage()
        startMsg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = "Build the project" }
        try await uiCall.requestStream.send(startMsg)

        var sessionID = ""
        for try await response in uiCall.responseStream {
            if case .sessionStarted(let s) = response.payload { sessionID = s.sessionID; break }
        }
        #expect(!sessionID.isEmpty)

        // Agent: open a single stream and drive the full flow within it
        let agentClient = try makeAgentClient(port: harness.serverPort, group: group)
        let agentCall = agentClient.makeConnectCall()
        defer { agentCall.requestStream.finish() }

        var regMsg = Pecan_AgentEvent()
        regMsg.register = Pecan_AgentRegistration.with {
            $0.agentID = UUID().uuidString
            $0.sessionID = sessionID
        }
        try await agentCall.requestStream.send(regMsg)

        let requestID = UUID().uuidString
        var registrationSucceeded = false
        var gotResponse = false

        // Single pass through the stream: handle registration then send LLM request
        for try await cmd in agentCall.responseStream {
            switch cmd.payload {
            case .registrationResponse(let resp):
                registrationSucceeded = resp.success
                // Immediately send LLM completion request on the same stream
                var completionMsg = Pecan_AgentEvent()
                completionMsg.completionRequest = Pecan_LLMCompletionRequest.with {
                    $0.requestID = requestID
                    $0.modelKey = "default"
                    $0.paramsJson = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"model\":\"mock\"}"
                }
                try await agentCall.requestStream.send(completionMsg)

            case .completionResponse(let resp) where resp.requestID == requestID:
                gotResponse = true
                #expect(resp.errorMessage.isEmpty)
                #expect(!resp.responseJson.isEmpty)
                agentCall.requestStream.finish()

            default:
                break
            }
            if gotResponse { break }
        }

        #expect(registrationSucceeded)
        #expect(gotResponse)

        let captured = try await harness.mockLLM.capturedRequests()
        #expect(!captured.isEmpty)
    }

    // MARK: - Tool execution

    @Test("fake agent can execute a built-in tool via server")
    func toolExecution() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        var startMsg = Pecan_ClientMessage()
        startMsg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = "Tool test" }
        try await uiCall.requestStream.send(startMsg)

        var sessionID = ""
        for try await r in uiCall.responseStream {
            if case .sessionStarted(let s) = r.payload { sessionID = s.sessionID; break }
        }

        let agentClient = try makeAgentClient(port: harness.serverPort, group: group)
        let agentCall = agentClient.makeConnectCall()
        defer { agentCall.requestStream.finish() }

        var regMsg = Pecan_AgentEvent()
        regMsg.register = Pecan_AgentRegistration.with {
            $0.agentID = UUID().uuidString; $0.sessionID = sessionID
        }
        try await agentCall.requestStream.send(regMsg)

        let toolRequestID = UUID().uuidString
        var gotToolResponse = false

        // Single pass: register, then send tool request, then wait for response
        for try await cmd in agentCall.responseStream {
            switch cmd.payload {
            case .registrationResponse:
                var toolMsg = Pecan_AgentEvent()
                toolMsg.toolRequest = Pecan_ToolExecutionRequest.with {
                    $0.requestID = toolRequestID
                    $0.toolName = "web_search"
                    $0.argumentsJson = "{\"query\":\"test query\"}"
                }
                try await agentCall.requestStream.send(toolMsg)

            case .toolResponse(let resp) where resp.requestID == toolRequestID:
                gotToolResponse = true
                agentCall.requestStream.finish()

            default:
                break
            }
            if gotToolResponse { break }
        }

        #expect(gotToolResponse)
    }
}
