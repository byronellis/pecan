import Foundation
import ANSITerminal
import GRPC
import NIO
import PecanShared

// Helper to format basic Markdown to ANSI
func formatMarkdown(_ text: String) -> String {
    // A very naive markdown formatter just for bold and italics
    // Real implementation would use a proper Markdown parser
    var formatted = text
    
    // Bold: **text** -> \u{001B}[1mtext\u{001B}[22m
    let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.*?)\\*\\*")
    let boldRange = NSRange(location: 0, length: formatted.utf16.count)
    formatted = boldRegex.stringByReplacingMatches(in: formatted, options: [], range: boldRange, withTemplate: "\u{001B}[1m$1\u{001B}[22m")
    
    // Italics: *text* -> \u{001B}[3mtext\u{001B}[23m
    let italicRegex = try! NSRegularExpression(pattern: "\\*(.*?)\\*")
    let italicRange = NSRange(location: 0, length: formatted.utf16.count)
    formatted = italicRegex.stringByReplacingMatches(in: formatted, options: [], range: italicRange, withTemplate: "\u{001B}[3m$1\u{001B}[23m")
    
    return formatted
}

func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan UI...\r")
        exit(0)
    }
    
    // Load config just to verify we can parse ~/.pecan/config.yaml
    do {
        let config = try Config.load()
        print("Loaded config. Default model: \(config.defaultModel ?? config.models.first?.key ?? "unknown")\r", terminator: "\n")
    } catch {
        // Suppress warning if not setup yet
    }
    
    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: 3000),
        transportSecurity: .plaintext,
        eventLoopGroup: group
    )

    let client = Pecan_ClientServiceAsyncClient(channel: channel)
    
    // Open Bidirectional Stream
    let call = client.makeStreamEventsCall()
    
    // UI Setup
    clearScreen()
    moveTo(1, 1)
    print("🥜 Pecan Interactive UI".bold + "\r", terminator: "\n")
    print("Connecting to server at 127.0.0.1:3000...\r\n", terminator: "\n")
    
    var currentSessionID: String? = nil

    // Start a task to listen for server messages
    let receiverTask = Task {
        do {
            for try await message in call.responseStream {
                switch message.payload {
                case .sessionStarted(let started):
                    currentSessionID = started.sessionID
                    print("\r\n[System]".yellow + " Session started: \(started.sessionID)\r", terminator: "\n")
                    print("\r> ", terminator: "")
                    fflush(stdout)
                    
                case .agentOutput(let output):
                    // Use standard print to leverage terminal's native scrollback
                    print("\r\n[Agent]".green + " \(formatMarkdown(output.text))\r", terminator: "\n")
                    print("\r> ", terminator: "")
                    fflush(stdout)
                    
                case .approvalRequest(let req):
                    print("\r\n[System]".yellow + " Tool Approval Required: \(req.toolName)\r", terminator: "\n")
                    print("Arguments: \(req.argumentsJson)\r", terminator: "\n")
                    print("Approve? (y/n)\r", terminator: "\n")
                    print("\r> ", terminator: "")
                    fflush(stdout)
                    
                case .taskCompleted(let comp):
                    print("\r\n[System]".yellow + " Task completed: \(comp.sessionID)\r", terminator: "\n")
                    print("\r> ", terminator: "")
                    fflush(stdout)
                    
                case nil:
                    break
                }
            }
        } catch {
            print("\r\n[System] Disconnected from server: \(error)\r", terminator: "\n")
        }
    }
    
    // Send an initial task to kick things off
    var initialMsg = Pecan_ClientMessage()
    var startTask = Pecan_StartTaskRequest()
    startTask.initialPrompt = "Initialize new session"
    initialMsg.startTask = startTask
    try await call.requestStream.send(initialMsg)
    
    // Input Loop
    while true {
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed == "/quit" || trimmed == "exit" {
            break
        }
        
        if !trimmed.isEmpty {
            // Echo locally for clarity (Terminal handles the scrollback inherently)
            moveUp()
            clearLine()
            print("\r[You]".blue + " \(trimmed)\r", terminator: "\n")
            
            guard let sid = currentSessionID else {
                print("\r[System]".yellow + " Waiting for session ID...\r", terminator: "\n")
                continue
            }
            
            var msg = Pecan_ClientMessage()
            var input = Pecan_TaskInput()
            input.sessionID = sid
            input.text = trimmed
            msg.userInput = input
            
            try await call.requestStream.send(msg)
        }
        print("\r> ", terminator: "")
        fflush(stdout)
    }
    
    print("\r\nExiting Pecan UI...\r", terminator: "\n")
    
    // Cleanup
    call.requestStream.finish()
    receiverTask.cancel()
    
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        print("Error: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
