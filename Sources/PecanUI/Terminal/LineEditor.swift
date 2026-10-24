/// The text being typed: a buffer with a cursor, readline-style editing, and history.
struct LineEditor {
    private(set) var text: [Character] = []
    /// Index into `text` where the next character goes.
    private(set) var cursor = 0
    private var history: [String] = []
    /// Position while browsing history; `history.count` means the line being written.
    private var historyIndex = 0
    private var draft: [Character] = []

    var isEmpty: Bool { text.isEmpty }
    var string: String { String(text) }

    mutating func insert(_ string: String) {
        text.insert(contentsOf: string, at: cursor)
        cursor += string.count
    }

    mutating func clear() {
        text.removeAll()
        cursor = 0
        historyIndex = history.count
    }

    /// Returns the line and starts a new one, remembering it in history.
    mutating func submit() -> String {
        let line = string
        if !line.isEmpty && history.last != line {
            history.append(line)
        }
        clear()
        return line
    }

    /// Applies an editing key. Returns false for keys it doesn't handle.
    mutating func handle(_ key: Key) -> Bool {
        switch key {
        case .character(let character): insert(String(character))
        case .paste(let pasted): insert(pasted)
        case .newline: insert("\n")
        case .backspace:
            if cursor > 0 {
                cursor -= 1
                text.remove(at: cursor)
            }
        case .delete, .control("d"):
            if cursor < text.count { text.remove(at: cursor) }
        case .left, .control("b"): cursor = max(0, cursor - 1)
        case .right, .control("f"): cursor = min(text.count, cursor + 1)
        case .home, .control("a"): cursor = lineStart(cursor)
        case .end, .control("e"): cursor = lineEnd(cursor)
        case .wordLeft: cursor = wordStart(before: cursor)
        case .wordRight: cursor = wordEnd(after: cursor)
        case .control("w"):
            let start = wordStart(before: cursor)
            text.removeSubrange(start..<cursor)
            cursor = start
        case .control("u"):
            // At the start of a line, joins it to the one before.
            let start = cursor > 0 && lineStart(cursor) == cursor ? cursor - 1 : lineStart(cursor)
            text.removeSubrange(start..<cursor)
            cursor = start
        case .control("k"):
            text.removeSubrange(cursor..<lineEnd(cursor))
        case .up: moveVertically(by: -1)
        case .down: moveVertically(by: 1)
        default: return false
        }
        return true
    }

    /// Up and Down move between lines of a multi-line input, and through history from its
    /// first and last lines.
    private mutating func moveVertically(by step: Int) {
        let start = lineStart(cursor)
        let column = cursor - start
        if step < 0, start > 0 {
            let previousStart = lineStart(start - 1)
            cursor = min(previousStart + column, start - 1)
        } else if step > 0, lineEnd(cursor) < text.count {
            let nextStart = lineEnd(cursor) + 1
            cursor = min(nextStart + column, lineEnd(nextStart))
        } else {
            browseHistory(by: step)
        }
    }

    private mutating func browseHistory(by step: Int) {
        let target = historyIndex + step
        guard target >= 0, target <= history.count else { return }
        if historyIndex == history.count { draft = text }
        historyIndex = target
        text = target == history.count ? draft : Array(history[target])
        cursor = text.count
    }

    private func lineStart(_ index: Int) -> Int {
        var i = index
        while i > 0 && text[i - 1] != "\n" { i -= 1 }
        return i
    }

    private func lineEnd(_ index: Int) -> Int {
        var i = index
        while i < text.count && text[i] != "\n" { i += 1 }
        return i
    }

    private func wordStart(before index: Int) -> Int {
        var i = index
        while i > 0 && text[i - 1].isWhitespace { i -= 1 }
        while i > 0 && !text[i - 1].isWhitespace { i -= 1 }
        return i
    }

    private func wordEnd(after index: Int) -> Int {
        var i = index
        while i < text.count && text[i].isWhitespace { i += 1 }
        while i < text.count && !text[i].isWhitespace { i += 1 }
        return i
    }
}
