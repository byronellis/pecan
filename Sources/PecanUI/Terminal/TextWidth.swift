import Foundation

/// Display widths in terminal columns. `setlocale(LC_CTYPE, "")` must have run for `wcwidth`
/// to know anything beyond ASCII.
enum TextWidth {
    static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if first.properties.isEmojiPresentation
            || (first.properties.isEmoji && scalars.contains("\u{FE0F}")) {
            return 2
        }
        return max(0, Int(wcwidth(wchar_t(first.value))))
    }

    static func of(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $0 + of($1) }
    }

    /// Splits plain text (no escape sequences) into rows of at most `width` columns, breaking
    /// at spaces where possible. Always returns at least one row.
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }
        var rows: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var row = ""
            var rowWidth = 0
            var lastSpace: String.Index?
            for character in line {
                let w = of(character)
                if rowWidth + w > width {
                    if let space = lastSpace {
                        rows.append(String(row[..<space]))
                        row = String(row[row.index(after: space)...])
                    } else {
                        rows.append(row)
                        row = ""
                    }
                    rowWidth = of(row)
                    lastSpace = nil
                }
                if character == " " { lastSpace = row.endIndex }
                row.append(character)
                rowWidth += w
            }
            rows.append(row)
        }
        return rows
    }

    /// Word-wraps one line that may contain ANSI escape sequences. Continuation rows start with
    /// `indent` and re-apply the colors in effect where the row broke, since every row ends
    /// with a reset.
    static func wrapStyled(_ line: String, width: Int, indent: String = "") -> [String] {
        let indentWidth = of(indent)
        guard width > indentWidth else { return [line] }
        var rows: [String] = []
        var row = ""
        var rowWidth = 0
        var style = ""
        var breakPoint: (index: String.Index, style: String)?
        var i = line.startIndex
        while i < line.endIndex {
            let character = line[i]
            if character == "\u{1B}" {
                let end = escapeEnd(in: line, from: i)
                let sequence = String(line[i..<end])
                row += sequence
                if sequence.hasSuffix("m") {
                    style = sequence == "\u{1B}[0m" ? "" : style + sequence
                }
                i = end
                continue
            }
            let w = of(character)
            if rowWidth + w > width && rowWidth > indentWidth {
                if let breakPoint {
                    rows.append(String(row[..<breakPoint.index]))
                    row = indent + breakPoint.style + String(row[row.index(after: breakPoint.index)...])
                } else {
                    rows.append(row)
                    row = indent + style
                }
                rowWidth = visibleWidth(row)
                breakPoint = nil
            }
            if character == " " && rowWidth > indentWidth { breakPoint = (row.endIndex, style) }
            row.append(character)
            rowWidth += w
            i = line.index(after: i)
        }
        rows.append(row)
        return rows
    }

    /// Width of text ignoring escape sequences.
    static func visibleWidth(_ text: String) -> Int {
        var width = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1B}" {
                i = escapeEnd(in: text, from: i)
            } else {
                width += of(text[i])
                i = text.index(after: i)
            }
        }
        return width
    }

    /// The indent for a wrapped line's continuation rows: its own leading whitespace, plus the
    /// width of a list bullet or number so wrapped items line up under their text.
    static func hangingIndent(for line: String) -> String {
        var plain = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\u{1B}" {
                i = escapeEnd(in: line, from: i)
            } else {
                plain.append(line[i])
                i = line.index(after: i)
            }
        }
        let leading = plain.prefix { $0 == " " }
        let rest = plain.dropFirst(leading.count)
        var marker = 0
        if rest.hasPrefix("• ") || rest.hasPrefix("❯ ") || rest.hasPrefix("│ ") {
            marker = 2
        } else if let match = rest.firstMatch(of: #/^\d+[.)] /#) {
            marker = match.output.count
        }
        return String(repeating: " ", count: leading.count + marker)
    }

    /// The index just past the escape sequence starting at `start`.
    private static func escapeEnd(in text: String, from start: String.Index) -> String.Index {
        var j = text.index(after: start)
        guard j < text.endIndex else { return j }
        if text[j] == "[" {
            j = text.index(after: j)
            while j < text.endIndex, let ascii = text[j].asciiValue, !(0x40...0x7E).contains(ascii) {
                j = text.index(after: j)
            }
            if j < text.endIndex { j = text.index(after: j) }
        } else {
            j = text.index(after: j)
        }
        return j
    }

    /// Cuts plain text to `width` columns, marking the cut with an ellipsis.
    static func truncate(_ text: String, width: Int) -> String {
        guard of(text) > width else { return text }
        var result = ""
        var used = 0
        for character in text {
            let w = of(character)
            if used + w > width - 1 { break }
            result.append(character)
            used += w
        }
        return result + "…"
    }

    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - of(text)))
    }
}
