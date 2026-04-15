import Testing
import Foundation
import GRPC
import NIO
import PecanShared

/// Integration tests covering SessionManager state behaviors.
///
/// These tests use the real server + mock LLM (no containers) and verify the
/// state bookkeeping that will be decomposed in Phase 2. They serve as a
/// regression harness: if any behavior breaks during refactoring, these tests
/// will catch it.
///
/// Each test drives a **single** iteration of the gRPC response stream
/// (gRPC async streams allow only one iterator per stream).
@Suite("SessionState", .serialized)
struct SessionStateTests {

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

    // MARK: - Pending command delivery

    /// Verify that commands sent before the agent registers are queued and
    /// delivered immediately when the agent connects.
    @Test("commands sent before agent registers are delivered on connect")
    func pendingCommandDelivery() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        // 1. Start session — wait for SessionStarted in a single stream pass
        var uiMsg = Pecan_ClientMessage()
        uiMsg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = "pending test" }
        try await uiCall.requestStream.send(uiMsg)

        var sessionID = ""
        for try await response in uiCall.responseStream {
            if case .sessionStarted(let s) = response.payload {
                sessionID = s.sessionID

                // 2. Send user input while no agent is registered.
                //    The server should queue this as a pending HostCommand.
                var inputMsg = Pecan_ClientMessage()
                inputMsg.userInput = Pecan_TaskInput.with {
                    $0.sessionID = sessionID
                    $0.text = "Hello from before agent registered"
                }
                try await uiCall.requestStream.send(inputMsg)
                break
            }
        }
        #expect(!sessionID.isEmpty)

        // Give the server a moment to process the input and queue it
        try await Task.sleep(nanoseconds: 150_000_000)

        // 3. Register the fake agent. It should immediately receive the queued command.
        let agentClient = try makeAgentClient(port: harness.serverPort, group: group)
        let agentCall = agentClient.makeConnectCall()
        defer { agentCall.requestStream.finish() }

        var regMsg = Pecan_AgentEvent()
        regMsg.register = Pecan_AgentRegistration.with {
            $0.agentID = UUID().uuidString
            $0.sessionID = sessionID
        }
        try await agentCall.requestStream.send(regMsg)

        var receivedRegistration = false
        var receivedPendingCommand = false
        let deadline = Date().addingTimeInterval(5)

        for try await cmd in agentCall.responseStream {
            switch cmd.payload {
            case .registrationResponse(let resp):
                receivedRegistration = resp.success
            case .processInput(let pi):
                if pi.text == "Hello from before agent registered" {
                    receivedPendingCommand = true
                }
            default:
                break
            }
            if receivedRegistration && receivedPendingCommand { break }
            if Date() > deadline { break }
        }

        #expect(receivedRegistration, "Agent registration should succeed")
        #expect(receivedPendingCommand, "Pending command should be delivered after agent registers")
    }

    // MARK: - Network state query

    /// Verify that /network (status query) returns a response to the UI stream
    /// without triggering a container restart (status is idempotent).
    @Test("/network status command returns current state to UI")
    func networkStatusQuery() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        var uiMsg = Pecan_ClientMessage()
        uiMsg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = "network test" }
        try await uiCall.requestStream.send(uiMsg)

        var gotNetworkStatus = false
        let deadline = Date().addingTimeInterval(8)

        for try await response in uiCall.responseStream {
            switch response.payload {
            case .sessionStarted(let s):
                // Send /network slash command (status only — no container restart)
                var slashMsg = Pecan_ClientMessage()
                slashMsg.userInput = Pecan_TaskInput.with {
                    $0.sessionID = s.sessionID
                    $0.text = "/network"
                }
                try await uiCall.requestStream.send(slashMsg)

            case .agentOutput(let out) where out.text.contains("Network:"):
                gotNetworkStatus = true
                // Default state is disabled
                #expect(out.text.contains("disabled") || out.text.contains("enabled"),
                        "Response should state current network status")

            default:
                break
            }
            if gotNetworkStatus { break }
            if Date() > deadline { break }
        }

        #expect(gotNetworkStatus, "Server should respond to /network with status output on the UI stream")
    }

    // MARK: - Agent busy state

    /// Verify that sending user input marks the session as busy, visible in
    /// the session list response.
    @Test("session is marked busy when user input is sent")
    func agentBusyState() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        var uiMsg = Pecan_ClientMessage()
        uiMsg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = "busy test" }
        try await uiCall.requestStream.send(uiMsg)

        var sessionID = ""
        var initiallyNotBusy = false
        var markedBusy = false

        // State machine: 0=waiting for start, 1=checking initial list,
        // 2=sent input, 3=checking busy list
        var state = 0
        let deadline = Date().addingTimeInterval(10)

        for try await response in uiCall.responseStream {
            switch response.payload {
            case .sessionStarted(let s) where state == 0:
                sessionID = s.sessionID
                state = 1
                // Request initial session list
                var listMsg = Pecan_ClientMessage()
                listMsg.listSessions = Pecan_ListSessionsRequest()
                try await uiCall.requestStream.send(listMsg)

            case .sessionList(let list) where state == 1:
                // Verify session is not busy before any input
                if let info = list.sessions.first(where: { $0.sessionID == sessionID }) {
                    initiallyNotBusy = !info.isBusy
                }
                state = 2
                // Now send non-slash input (no agent registered — queued, but marks busy)
                var inputMsg = Pecan_ClientMessage()
                inputMsg.userInput = Pecan_TaskInput.with {
                    $0.sessionID = sessionID
                    $0.text = "do something"
                }
                try await uiCall.requestStream.send(inputMsg)
                // Small delay so the server processes the input before we list
                try await Task.sleep(nanoseconds: 200_000_000)
                var listMsg2 = Pecan_ClientMessage()
                listMsg2.listSessions = Pecan_ListSessionsRequest()
                try await uiCall.requestStream.send(listMsg2)

            case .sessionList(let list) where state == 2:
                // Check that the session is now busy
                if let info = list.sessions.first(where: { $0.sessionID == sessionID }) {
                    markedBusy = info.isBusy
                }
                state = 3

            default:
                break
            }
            if state == 3 { break }
            if Date() > deadline { break }
        }

        #expect(!sessionID.isEmpty)
        #expect(initiallyNotBusy, "Session should not be busy before any user input")
        #expect(markedBusy, "Session should be marked busy after user input sent to (no-agent) session")
    }

    // MARK: - Multiple session isolation

    /// Verify two concurrent sessions are tracked independently and both
    /// appear in the session list with distinct IDs.
    @Test("multiple sessions tracked independently in session list")
    func multipleSessionIsolation() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)
        let uiCall = uiClient.makeStreamEventsCall()
        defer { uiCall.requestStream.finish() }

        // Send two startTask requests back-to-back
        for prompt in ["session-alpha", "session-beta"] {
            var msg = Pecan_ClientMessage()
            msg.startTask = Pecan_StartTaskRequest.with { $0.initialPrompt = prompt }
            try await uiCall.requestStream.send(msg)
        }

        var collectedIDs: [String] = []
        let deadline = Date().addingTimeInterval(10)

        for try await response in uiCall.responseStream {
            if case .sessionStarted(let s) = response.payload {
                collectedIDs.append(s.sessionID)
                if collectedIDs.count == 2 {
                    // Both sessions started — now request the list
                    var listMsg = Pecan_ClientMessage()
                    listMsg.listSessions = Pecan_ListSessionsRequest()
                    try await uiCall.requestStream.send(listMsg)
                }
            }
            if case .sessionList(let list) = response.payload, collectedIDs.count == 2 {
                let listedIDs = list.sessions.map(\.sessionID)
                #expect(collectedIDs[0] != collectedIDs[1], "Two sessions must have distinct IDs")
                #expect(listedIDs.contains(collectedIDs[0]), "Session A must appear in list")
                #expect(listedIDs.contains(collectedIDs[1]), "Session B must appear in list")
                break
            }
            if Date() > deadline { break }
        }

        #expect(collectedIDs.count == 2, "Both sessions should have sent SessionStarted")
    }

    // MARK: - Session reattach

    /// Verify that a persistent session can be detached and reattached from a
    /// new UI connection, getting the correct session ID back.
    @Test("persistent session can be detached and reattached")
    func persistentSessionReattach() async throws {
        let harness = try await TestHarness.start()
        defer { Task { await harness.stop() } }

        let group = makeGroup()
        defer { Task { try? await group.shutdownGracefully() } }

        let uiClient = try makeUIClient(port: harness.serverPort, group: group)

        // --- First connection: start a persistent session ---
        let uiCallA = uiClient.makeStreamEventsCall()

        var startMsg = Pecan_ClientMessage()
        startMsg.startTask = Pecan_StartTaskRequest.with {
            $0.initialPrompt = "reattach test"
            $0.persistent = true
        }
        try await uiCallA.requestStream.send(startMsg)

        var sessionID = ""
        for try await response in uiCallA.responseStream {
            if case .sessionStarted(let s) = response.payload {
                sessionID = s.sessionID

                // Immediately detach
                var detachMsg = Pecan_ClientMessage()
                detachMsg.detachSession = Pecan_DetachSession.with { $0.sessionID = sessionID }
                try await uiCallA.requestStream.send(detachMsg)
                break
            }
        }
        #expect(!sessionID.isEmpty)

        // Close the first connection
        uiCallA.requestStream.finish()
        try await Task.sleep(nanoseconds: 400_000_000)

        // --- Second connection: reattach ---
        let uiCallB = uiClient.makeStreamEventsCall()
        defer { uiCallB.requestStream.finish() }

        var reattachMsg = Pecan_ClientMessage()
        reattachMsg.reattach = Pecan_ReattachRequest.with { $0.sessionID = sessionID }
        try await uiCallB.requestStream.send(reattachMsg)

        var reattachedID = ""
        let deadline = Date().addingTimeInterval(8)
        for try await response in uiCallB.responseStream {
            if case .sessionStarted(let s) = response.payload {
                reattachedID = s.sessionID
                break
            }
            if Date() > deadline { break }
        }

        #expect(reattachedID == sessionID, "Reattach must return the same session ID: got '\(reattachedID)'")
    }
}
