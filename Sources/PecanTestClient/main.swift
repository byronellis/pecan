import Foundation
import GRPC
import NIO
import PecanShared

func main() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task {
            try? await group.shutdownGracefully()
        }
    }

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: 3000),
        transportSecurity: .plaintext,
        eventLoopGroup: group
    )

    let client = Pecan_ClientServiceAsyncClient(channel: channel)
    let call = client.makeStreamEventsCall()

    print("Starting session...")
    var startMsg = Pecan_ClientMessage()
    var startTask = Pecan_StartTaskRequest()
    startTask.initialPrompt = "Hello from test client"
    startMsg.startTask = startTask
    try await call.requestStream.send(startMsg)

    for try await message in call.responseStream {
        switch message.payload {
        case .sessionStarted(let started):
            print("Session started: \(started.sessionID)")
            // We got what we wanted, let's wait a bit to see if agent connects
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            call.requestStream.finish()
            return
        case .agentOutput(let output):
            print("Agent: \(output.text)")
        default:
            print("Received message: \(String(describing: message.payload))")
        }
    }
}

let task = Task {
    do {
        try await main()
        exit(0)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
