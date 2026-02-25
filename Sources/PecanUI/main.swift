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

actor TerminalManager {
    static let shared = TerminalManager()
    
    var currentInputBuffer = ""
    var cursorPosition = 0
    var prompt = "> "
    
    func printMessage(_ message: String) {
        // Clear current line
        print("\r\u{1B}[K", terminator: "")
        // Print message
        print(message + "\r", terminator: "\n")
        // Redraw input line
        redrawInput()
    }
    
    func redrawInput() {
        print("\r\u{1B}[K\(prompt)\(currentInputBuffer)", terminator: "")
        if cursorPosition < currentInputBuffer.count {
            print("\u{1B}[\(currentInputBuffer.count - cursorPosition)D", terminator: "")
        }
        fflush(stdout)
    }
    
    func insertChar(_ char: Character) {
        let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        currentInputBuffer.insert(char, at: idx)
        cursorPosition += 1
        redrawInput()
    }
    
    func backspace() {
        if cursorPosition > 0 {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition - 1)
            currentInputBuffer.remove(at: idx)
            cursorPosition -= 1
            redrawInput()
        }
    }
    
    func moveCursorLeft() {
        if cursorPosition > 0 {
            cursorPosition -= 1
            redrawInput()
        }
    }
    
    func moveCursorRight() {
        if cursorPosition < currentInputBuffer.count {
            cursorPosition += 1
            redrawInput()
        }
    }
    
    func clearInput() {
        currentInputBuffer = ""
        cursorPosition = 0
        redrawInput()
    }
    
    func getAndClearInput() -> String {
        let text = currentInputBuffer
        currentInputBuffer = ""
        cursorPosition = 0
        // Don't redraw yet, let the caller print the newline
        return text
    }
}

enum InputKey {
    case ctrlC
    case ctrlD
    case enter
    case backspace
    case escape
    case arrowLeft
    case arrowRight
    case character(Character)
    case unknown(UInt8)
}

func nextKey() -> InputKey? {
    guard keyPressed() else { return nil }
    let char = readChar()
    let ascii = char.asciiValue ?? 0
    
    switch ascii {
    case 3: return .ctrlC
    case 4: return .ctrlD
    case 10, 13: return .enter
    case 127: return .backspace
    case 27:
        // ESC sequence
        let next1 = readChar()
        if next1 == "[" {
            let next2 = readChar()
            if next2 == "D" { return .arrowLeft }
            if next2 == "C" { return .arrowRight }
        }
        return .escape
    case 32...126:
        return .character(char)
    default:
        // Attempt to pass through other printable characters (e.g. unicode)
        if char.isASCII == false {
            return .character(char)
        }
        return .unknown(ascii)
    }
}

func readInputLine() async -> String? {
    await TerminalManager.shared.redrawInput()
    
    while true {
        if let key = nextKey() {
            switch key {
            case .ctrlC:
                return nil
            case .ctrlD:
                let buf = await TerminalManager.shared.currentInputBuffer
                if buf.isEmpty { return nil }
            case .enter:
                print("\r\n", terminator: "")
                return await TerminalManager.shared.getAndClearInput()
            case .backspace:
                await TerminalManager.shared.backspace()
            case .arrowLeft:
                await TerminalManager.shared.moveCursorLeft()
            case .arrowRight:
                await TerminalManager.shared.moveCursorRight()
            case .character(let c):
                await TerminalManager.shared.insertChar(c)
            case .escape, .unknown:
                break
            }
        } else {
            // Tiny sleep to prevent 100% CPU while polling
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
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
                    await TerminalManager.shared.printMessage("[System]".yellow + " Session started: \(started.sessionID)")
                    
                case .agentOutput(let output):
                    // Use standard print to leverage terminal's native scrollback
                    await TerminalManager.shared.printMessage("[Agent]".green + " \(formatMarkdown(output.text))")
                    
                case .approvalRequest(let req):
                    await TerminalManager.shared.printMessage("[System]".yellow + " Tool Approval Required: \(req.toolName)\r\nArguments: \(req.argumentsJson)\r\nApprove? (y/n)")
                    
                case .taskCompleted(let comp):
                    await TerminalManager.shared.printMessage("[System]".yellow + " Task completed: \(comp.sessionID)")
                    
                case nil:
                    break
                }
            }
        } catch {
            await TerminalManager.shared.printMessage("[System] Disconnected from server: \(error)")
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
        guard let line = await readInputLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed == "/quit" || trimmed == "exit" {
            break
        }
        
        if !trimmed.isEmpty {
            // Echo locally for clarity (Terminal handles the scrollback inherently)
            await TerminalManager.shared.printMessage("[You]".blue + " \(trimmed)")
            
            guard let sid = currentSessionID else {
                await TerminalManager.shared.printMessage("[System]".yellow + " Waiting for session ID...")
                continue
            }
            
            var msg = Pecan_ClientMessage()
            var input = Pecan_TaskInput()
            input.sessionID = sid
            input.text = trimmed
            msg.userInput = input
            
            try await call.requestStream.send(msg)
        }
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
