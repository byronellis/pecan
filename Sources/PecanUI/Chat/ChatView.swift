import Foundation

/// Colors and glyphs for the chat interface.
enum Style {
    static let accent = "\u{1B}[38;5;173m"
    static let border = "\u{1B}[38;5;244m"
    static let muted = "\u{1B}[38;5;246m"
    static let error = "\u{1B}[38;5;167m"
    static let reset = "\u{1B}[0m"
    static let prompt = "❯"
    static let spinner = ["·", "◦", "○", "◦"]
}

/// Lays out the live region: what is streaming, the rounded input box, and the status line.
struct ChatView {
    var width: Int
    var height: Int

    struct Content {
        var editor: LineEditor
        var placeholder: String
        /// The response line still being written, if a turn is streaming text.
        var streaming: String?
        /// Shown while waiting for the first text of a turn.
        var activity: String?
        var queued: [String]
        var status: String
        var hint: String?
    }

    func render(_ content: Content) -> (rows: [String], cursor: InlineScreen.Cursor) {
        var rows: [String] = []

        if let streaming = content.streaming, !streaming.isEmpty {
            // Only the tail: finished lines have already gone to the scrollback.
            rows += TextWidth.wrap(streaming, width: width).suffix(3)
        } else if let activity = content.activity {
            rows.append(Style.accent + TextWidth.truncate(activity, width: width) + Style.reset)
        }
        for message in content.queued {
            let line = TextWidth.truncate("\(Style.prompt) \(message.replacingOccurrences(of: "\n", with: " "))", width: width - 9)
            rows.append(Style.muted + line + "  (queued)" + Style.reset)
        }

        let (box, cursorInBox) = inputBox(content)
        let cursor = InlineScreen.Cursor(row: rows.count + cursorInBox.row, column: cursorInBox.column)
        rows += box

        let status = content.hint.map { "\(content.status) · \($0)" } ?? content.status
        rows.append(Style.muted + " " + TextWidth.truncate(status, width: width - 1) + Style.reset)
        return (rows, cursor)
    }

    /// The input in a box with soft corners. The cursor is relative to the box's top row.
    private func inputBox(_ content: Content) -> ([String], InlineScreen.Cursor) {
        // "│ ❯ " + text + " │"
        let inner = max(1, width - 6)
        let (lines, cursor) = layoutInput(content.editor, width: inner)
        // Leave room for everything else in the region, and keep the cursor's line in view.
        let visible = max(1, min(lines.count, height - 6))
        let first = min(max(0, cursor.row - visible + 1), lines.count - visible)

        var rows = [Style.border + "╭" + String(repeating: "─", count: max(0, width - 2)) + "╮" + Style.reset]
        for (index, line) in lines[first..<(first + visible)].enumerated() {
            let lead = first + index == 0 ? Style.accent + Style.prompt + Style.reset : " "
            let text = content.editor.isEmpty
                ? Style.muted + TextWidth.pad(TextWidth.truncate(content.placeholder, width: inner), to: inner) + Style.reset
                : TextWidth.pad(line, to: inner)
            rows.append(Style.border + "│" + Style.reset + " \(lead) " + text + " " + Style.border + "│" + Style.reset)
        }
        rows.append(Style.border + "╰" + String(repeating: "─", count: max(0, width - 2)) + "╯" + Style.reset)
        return (rows, InlineScreen.Cursor(row: 1 + cursor.row - first, column: 4 + cursor.column))
    }

    /// Breaks the input into rows of at most `width` columns, and finds the cursor among them.
    private func layoutInput(_ editor: LineEditor, width: Int) -> ([String], InlineScreen.Cursor) {
        var lines = [""]
        var column = 0
        var cursor = InlineScreen.Cursor(row: 0, column: 0)
        for (index, character) in editor.text.enumerated() {
            if index == editor.cursor {
                cursor = InlineScreen.Cursor(row: lines.count - 1, column: column)
            }
            if character == "\n" {
                lines.append("")
                column = 0
                continue
            }
            let w = TextWidth.of(character)
            if column + w > width {
                lines.append("")
                column = 0
                if index == editor.cursor { cursor = InlineScreen.Cursor(row: lines.count - 1, column: 0) }
            }
            lines[lines.count - 1].append(character)
            column += w
        }
        if editor.cursor == editor.text.count {
            if column >= width {
                lines.append("")
                column = 0
            }
            cursor = InlineScreen.Cursor(row: lines.count - 1, column: column)
        }
        return (lines, cursor)
    }
}
