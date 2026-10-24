import Foundation
import Synchronization

/// The controlling terminal: raw mode, size, output, and a stream of input bytes.
final class Terminal: Sendable {
    struct Size: Equatable, Sendable {
        var columns: Int
        var rows: Int
    }

    private let original = Mutex<termios?>(nil)

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    var size: Size {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 else {
            return Size(columns: 80, rows: 24)
        }
        return Size(columns: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    /// Raw input (no echo, no line buffering, no signal keys) and bracketed paste.
    func enterRawMode() {
        var current = termios()
        tcgetattr(STDIN_FILENO, &current)
        original.withLock { saved in
            if saved == nil { saved = current }
        }
        var raw = current
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?2004h")
    }

    func restore() {
        write("\u{1B}[?2004l\u{1B}[?25h")
        original.withLock { saved in
            if var saved {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
            }
        }
    }

    func write(_ text: String) {
        var text = text
        text.withUTF8 { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Input bytes as they arrive, read on a dedicated thread. Finishes at end of input.
    func input() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 {
                        continuation.yield(Array(buffer[0..<count]))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        continuation.finish()
                        return
                    }
                }
            }
            thread.start()
        }
    }

    /// Delivers the given signals as a stream instead of their default actions.
    static func signals(_ numbers: [Int32]) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            let sources = numbers.map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number)
                source.setEventHandler { continuation.yield(number) }
                source.resume()
                return source
            }
            continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
        }
    }
}
