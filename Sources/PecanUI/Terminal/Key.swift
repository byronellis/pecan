/// A decoded keypress or paste.
enum Key: Equatable {
    case character(Character)
    case paste(String)
    case enter
    /// Alt-Enter or Ctrl-J: a newline inside the input.
    case newline
    case backspace
    case delete
    case tab
    case escape
    case up, down, left, right
    case wordLeft, wordRight
    case home, end
    /// Ctrl plus a letter, lowercased (`"c"` for Ctrl-C).
    case control(Character)
}

/// Turns raw terminal bytes into keys. Holds partial sequences across reads, since an escape
/// sequence or a UTF-8 character can be split between them.
struct KeyDecoder {
    private var buffer: [UInt8] = []
    private var paste: [UInt8]?

    private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    /// True when the buffer holds a lone ESC that may still be the start of a sequence. The
    /// caller decides, after a short wait, that it was the Escape key with `flushEscape()`.
    var hasPendingEscape: Bool { buffer == [0x1B] }

    mutating func flushEscape() -> [Key] {
        guard hasPendingEscape else { return [] }
        buffer.removeAll()
        return [.escape]
    }

    mutating func decode(_ bytes: [UInt8]) -> [Key] {
        buffer += bytes
        var keys: [Key] = []
        while !buffer.isEmpty {
            if var pasted = paste {
                if let end = buffer.firstRange(of: Self.pasteEnd) {
                    pasted += buffer[..<end.lowerBound]
                    buffer.removeSubrange(..<end.upperBound)
                    paste = nil
                    let text = String(decoding: pasted, as: UTF8.self)
                    keys.append(.paste(text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")))
                } else {
                    // Keep a possible partial end marker in the buffer.
                    let keep = min(buffer.count, Self.pasteEnd.count - 1)
                    pasted += buffer[..<(buffer.count - keep)]
                    buffer.removeFirst(buffer.count - keep)
                    paste = pasted
                    break
                }
                continue
            }
            guard let (key, length) = next() else { break }
            buffer.removeFirst(length)
            if let key { keys.append(key) }
        }
        return keys
    }

    /// The key at the front of the buffer and how many bytes it used, nil if incomplete. A nil
    /// key with a length skips bytes that mean nothing to us.
    private mutating func next() -> (Key?, Int)? {
        let byte = buffer[0]
        switch byte {
        case 0x1B:
            return escapeSequence()
        case 0x0D:
            return (.enter, 1)
        case 0x0A:
            return (.newline, 1)
        case 0x09:
            return (.tab, 1)
        case 0x7F, 0x08:
            return (.backspace, 1)
        case 0x01...0x1A:
            return (.control(Character(UnicodeScalar(byte + 0x60))), 1)
        case 0x00...0x1F:
            return (nil, 1)
        default:
            return utf8Character()
        }
    }

    private func utf8Character() -> (Key?, Int)? {
        let length = switch buffer[0] {
        case 0xF0...: 4
        case 0xE0...: 3
        case 0xC0...: 2
        default: 1
        }
        guard buffer.count >= length else { return nil }
        let text = String(decoding: buffer[0..<length], as: UTF8.self)
        return (text.first.map(Key.character), length)
    }

    private mutating func escapeSequence() -> (Key?, Int)? {
        guard buffer.count >= 2 else { return nil }
        switch buffer[1] {
        case UInt8(ascii: "["):
            // CSI: parameters and intermediates, then a final byte in 0x40...0x7E.
            guard let finalIndex = buffer.dropFirst(2).firstIndex(where: { (0x40...0x7E).contains($0) }) else {
                return nil
            }
            let sequence = Array(buffer[0...finalIndex])
            if sequence == Self.pasteStart {
                paste = []
                return (nil, sequence.count)
            }
            let parameters = String(decoding: buffer[2..<finalIndex], as: UTF8.self)
            return (csiKey(parameters: parameters, final: buffer[finalIndex]), sequence.count)
        case UInt8(ascii: "O"):
            guard buffer.count >= 3 else { return nil }
            let key: Key? = switch buffer[2] {
            case UInt8(ascii: "A"): .up
            case UInt8(ascii: "B"): .down
            case UInt8(ascii: "C"): .right
            case UInt8(ascii: "D"): .left
            case UInt8(ascii: "H"): .home
            case UInt8(ascii: "F"): .end
            default: nil
            }
            return (key, 3)
        case 0x0D:
            return (.newline, 2)
        case UInt8(ascii: "b"):
            return (.wordLeft, 2)
        case UInt8(ascii: "f"):
            return (.wordRight, 2)
        case 0x7F:
            return (.control("w"), 2)
        default:
            // Unknown Alt combination: drop the ESC and let the next key decode normally.
            return (nil, 1)
        }
    }

    private func csiKey(parameters: String, final: UInt8) -> Key? {
        let modifier = parameters.split(separator: ";").dropFirst().first.flatMap { Int($0) } ?? 1
        // xterm modifiers: 3 = Alt, 5 = Ctrl.
        let byWord = modifier == 3 || modifier == 5
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return byWord ? .wordRight : .right
        case UInt8(ascii: "D"): return byWord ? .wordLeft : .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "~"):
            switch parameters.split(separator: ";").first {
            case "1", "7": return .home
            case "4", "8": return .end
            case "3": return .delete
            default: return nil
            }
        default:
            return nil
        }
    }
}
