/// Draws a live region at the bottom of the terminal, below everything already printed.
///
/// Finished output goes above the region with `print(_:)`, where it becomes ordinary terminal
/// scrollback, word-wrapped to the width at the time; only the region itself is redrawn.
/// Every row handed to `draw` must fit the terminal width, so each one occupies exactly one
/// screen row.
struct InlineScreen {
    struct Cursor {
        var row: Int
        var column: Int
    }

    private let terminal: Terminal
    /// Lines to print above the region on the next draw.
    private var pendingOutput: [String] = []
    /// The cursor's row within the region as last drawn, counted from its top.
    private var cursorRow = 0

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    /// Queues lines for the scrollback; they appear on the next `draw`.
    mutating func print(_ lines: [String]) {
        pendingOutput += lines
    }

    mutating func draw(_ rows: [String], cursor: Cursor?) {
        var frame = "\u{1B}[?2026h\u{1B}[?25l\r"
        if cursorRow > 0 { frame += "\u{1B}[\(cursorRow)A" }
        frame += "\u{1B}[J"
        let width = terminal.size.columns
        for line in pendingOutput {
            for row in TextWidth.wrapStyled(line, width: width, indent: TextWidth.hangingIndent(for: line)) {
                frame += row + "\u{1B}[0m\r\n"
            }
        }
        pendingOutput.removeAll()
        frame += rows.joined(separator: "\u{1B}[0m\r\n") + "\u{1B}[0m"

        let lastRow = max(0, rows.count - 1)
        if let cursor {
            let up = lastRow - cursor.row
            if up > 0 { frame += "\u{1B}[\(up)A" }
            frame += "\r"
            if cursor.column > 0 { frame += "\u{1B}[\(cursor.column)C" }
            frame += "\u{1B}[?25h"
            cursorRow = cursor.row
        } else {
            cursorRow = lastRow
        }
        frame += "\u{1B}[?2026l"
        terminal.write(frame)
    }

    /// Removes the region, leaving the cursor where it started, e.g. before exiting.
    mutating func clear() {
        draw([], cursor: nil)
    }
}
