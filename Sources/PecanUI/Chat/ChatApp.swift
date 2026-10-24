import Foundation
import PecanProtocol
import PecanSettings

/// The interactive chat: everything the user sees and types, driven by one event loop.
@MainActor
final class ChatApp {
    private enum Event {
        case input([UInt8])
        case inputClosed
        case escapeTimeout
        case notification(InboundNotification)
        case disconnected
        case turnEnded(Result<SendMessage.Result, any Error>)
        case tick
        case signal(Int32)
    }

    private struct Turn {
        let startedAt = ContinuousClock.now
        /// Response text not yet ending in a newline, so not yet formatted and printed.
        var partialLine = ""
        var receivedText = false
        var formatter = MarkdownFormatter()
    }

    private let rpc: RPCConnection
    private var session: SessionInfo
    private let terminal = Terminal()
    private var screen: InlineScreen
    private var decoder = KeyDecoder()
    private var editor = LineEditor()
    private var turn: Turn?
    private var queued: [String] = []
    private var usage = TokenUsage.zero
    private var hint: (text: String, until: ContinuousClock.Instant)?
    private var lastInterrupt: ContinuousClock.Instant?
    private var running = true
    private let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation

    init(rpc: RPCConnection, session: SessionInfo) {
        self.rpc = rpc
        self.session = session
        screen = InlineScreen(terminal: terminal)
        (events, sink) = AsyncStream.makeStream()
    }

    func run() async {
        setlocale(LC_CTYPE, "")
        terminal.enterRawMode()
        defer {
            screen.clear()
            terminal.restore()
        }
        startEventSources()
        printBanner()
        draw()

        for await event in events {
            handle(event)
            guard running else { break }
            draw()
        }
    }

    // MARK: - Events

    private func startEventSources() {
        let sink = self.sink
        let terminal = self.terminal
        let rpc = self.rpc
        Task.detached {
            for await bytes in terminal.input() { sink.yield(.input(bytes)) }
            sink.yield(.inputClosed)
        }
        Task.detached {
            for await notification in rpc.notifications { sink.yield(.notification(notification)) }
            sink.yield(.disconnected)
        }
        Task.detached {
            for await number in Terminal.signals([SIGWINCH, SIGTERM, SIGHUP, SIGCONT]) {
                sink.yield(.signal(number))
            }
        }
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                sink.yield(.tick)
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .input(let bytes):
            for key in decoder.decode(bytes) { handle(key) }
            if decoder.hasPendingEscape {
                let sink = self.sink
                Task {
                    try? await Task.sleep(for: .milliseconds(40))
                    sink.yield(.escapeTimeout)
                }
            }
        case .escapeTimeout:
            for key in decoder.flushEscape() { handle(key) }
        case .inputClosed:
            running = false
        case .notification(let notification):
            receive(notification)
        case .disconnected:
            screen.print([Style.error + "✗ lost the connection to the pecan server" + Style.reset])
            running = false
        case .turnEnded(let result):
            endTurn(result)
        case .tick:
            if let hint, hint.until < .now { self.hint = nil }
        case .signal(SIGWINCH), .signal(SIGCONT):
            break
        case .signal:
            running = false
        }
    }

    private func handle(_ key: Key) {
        switch key {
        case .enter:
            submit()
        case .escape:
            if turn != nil { interruptTurn() }
        case .control("c"):
            if turn != nil {
                interruptTurn()
            } else if !editor.isEmpty {
                editor.clear()
            } else if let last = lastInterrupt, ContinuousClock.now - last < .seconds(2) {
                running = false
            } else {
                lastInterrupt = .now
                showHint("press ctrl-c again to exit")
            }
        case .control("d") where editor.isEmpty:
            running = false
        case .control("l"):
            terminal.write("\u{1B}[2J\u{1B}[H")
        case .control("z"):
            suspend()
        default:
            _ = editor.handle(key)
        }
    }

    private func showHint(_ text: String) {
        hint = (text, .now + .seconds(2))
    }

    /// Ctrl-Z: give the terminal back, stop, and pick up again on `fg`.
    private func suspend() {
        screen.clear()
        terminal.restore()
        kill(getpid(), SIGTSTP)
        terminal.enterRawMode()
    }

    // MARK: - Turns

    private func submit() {
        var text = editor.string
        // A trailing backslash continues the message on a new line.
        if text.hasSuffix("\\") {
            _ = editor.handle(.backspace)
            editor.insert("\n")
            return
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = editor.submit()

        if text.hasPrefix("/") {
            command(text)
        } else if turn != nil {
            queued.append(text)
        } else {
            startTurn(text)
        }
    }

    private func startTurn(_ text: String) {
        printUserMessage(text)
        turn = Turn()
        let rpc = self.rpc
        let sink = self.sink
        let params = SendMessage.Params(sessionID: session.id, text: text)
        Task {
            do {
                let result = try await rpc.call(SendMessage.self, params, timeout: nil)
                sink.yield(.turnEnded(.success(result)))
            } catch {
                sink.yield(.turnEnded(.failure(error)))
            }
        }
    }

    private func interruptTurn() {
        let rpc = self.rpc
        let params = CancelTurn.Params(sessionID: session.id)
        Task { _ = try? await rpc.call(CancelTurn.self, params) }
        queued.removeAll()
    }

    private func receive(_ notification: InboundNotification) {
        guard notification.method == SessionEvent.name,
              let params = try? notification.decode(SessionEvent.self),
              params.sessionID == session.id
        else { return }
        switch params.event {
        case .text(let delta):
            appendResponse(delta)
        case .usage(let latest):
            usage = latest
        }
    }

    private func appendResponse(_ delta: String) {
        guard var current = turn else { return }
        current.receivedText = true
        current.partialLine += delta
        var output: [String] = []
        while let newline = current.partialLine.firstIndex(of: "\n") {
            output += current.formatter.line(String(current.partialLine[..<newline]))
            current.partialLine.removeSubrange(...newline)
        }
        turn = current
        screen.print(output)
    }

    private func endTurn(_ result: Result<SendMessage.Result, any Error>) {
        guard var finished = turn else { return }
        turn = nil
        var output: [String] = []
        if !finished.partialLine.isEmpty {
            output += finished.formatter.line(finished.partialLine)
        }
        output += finished.formatter.finish()

        switch result {
        case .success(let response):
            usage = response.usage
        case .failure(let error as RPCError) where error.code == RPCError.cancelled:
            output.append(Style.muted + "⎿ interrupted" + Style.reset)
        case .failure(let error):
            output.append(Style.error + "✗ \(error)" + Style.reset)
        }
        screen.print(output + [""])

        if !queued.isEmpty {
            startTurn(queued.removeFirst())
        }
    }

    // MARK: - Commands

    private func command(_ text: String) {
        let name = text.split(separator: " ").first.map(String.init) ?? text
        switch name {
        case "/exit", "/quit":
            running = false
        case "/help":
            screen.print([
                Style.muted + "  /new     start a new session" + Style.reset,
                Style.muted + "  /fork    continue in a copy of this session" + Style.reset,
                Style.muted + "  /exit    quit (or ctrl-d)" + Style.reset,
                Style.muted + "  enter sends · alt-enter, ctrl-j or a trailing \\ adds a line" + Style.reset,
                Style.muted + "  esc or ctrl-c stops a reply" + Style.reset,
                "",
            ])
        case "/new":
            replaceSession(announce: "new session") { rpc, _ in
                try await rpc.call(OpenSession.self, .init())
            }
        case "/fork":
            replaceSession(announce: "forked") { rpc, current in
                try await rpc.call(ForkSession.self, .init(sessionID: current))
            }
        default:
            screen.print([Style.error + "✗ unknown command \(name); try /help" + Style.reset, ""])
        }
    }

    /// Switches the chat to the session `open` creates, given the connection and current session.
    private func replaceSession(
        announce: String,
        _ open: @escaping @Sendable (RPCConnection, SessionID) async throws -> SessionInfo
    ) {
        guard turn == nil else {
            showHint("wait for the reply to finish")
            return
        }
        let rpc = self.rpc
        let current = session.id
        Task {
            do {
                let info = try await open(rpc, current)
                self.session = info
                self.usage = .zero
                self.screen.print([Style.muted + "⎿ \(announce) \(info.id.prefix(8))" + Style.reset, ""])
            } catch {
                self.screen.print([Style.error + "✗ \(error)" + Style.reset, ""])
            }
            self.draw()
        }
    }

    // MARK: - Drawing

    private func printBanner() {
        let build = BuildInfo.current
        screen.print([
            Style.accent + "pecan" + Style.reset + Style.muted + " \(build.version) · \(session.model.name) model · /help for help" + Style.reset,
            "",
        ])
    }

    private func printUserMessage(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        screen.print(lines.enumerated().map { index, line in
            (index == 0 ? Style.accent + Style.prompt + Style.reset + " " : "  ") + line
        } + [""])
    }

    private func draw() {
        let size = terminal.size
        let view = ChatView(width: size.columns, height: size.rows)
        let (rows, cursor) = view.render(ChatView.Content(
            editor: editor,
            placeholder: "Message pecan",
            streaming: turn?.partialLine,
            activity: activityLine(),
            queued: queued,
            status: statusLine(),
            hint: hint?.text))
        screen.draw(rows, cursor: cursor)
    }

    private func activityLine() -> String? {
        guard let turn, !turn.receivedText else { return nil }
        let elapsed = ContinuousClock.now - turn.startedAt
        let frame = Style.spinner[Int(elapsed / .milliseconds(240)) % Style.spinner.count]
        return "\(frame) Thinking… \(Int(elapsed.components.seconds))s"
    }

    private func statusLine() -> String {
        var parts = [session.model.name]
        if session.kind != .main { parts.append("\(session.kind.rawValue) \(session.id.prefix(8))") }
        let used = usage.input + usage.output
        if used > 0 {
            let percent = session.model.contextSize > 0 ? used * 100 / session.model.contextSize : 0
            parts.append("↑ \(usage.input.formatted()) · ↓ \(usage.output.formatted())")
            parts.append("\(used.formatted()) / \(session.model.contextSize.formatted()) (\(percent)%)")
        }
        if turn != nil { parts.append("esc to stop") }
        return parts.joined(separator: " · ")
    }
}
