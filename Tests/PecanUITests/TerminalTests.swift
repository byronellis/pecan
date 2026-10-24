import Foundation
import Testing
@testable import PecanUI

@Suite struct KeyDecoderTests {
    @Test func decodesArrowsSplitAcrossReads() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}[".utf8)) == [])
        #expect(decoder.decode(Array("A".utf8)) == [.up])
    }

    @Test func decodesUTF8SplitAcrossReads() {
        var decoder = KeyDecoder()
        let bytes = Array("é".utf8)
        #expect(decoder.decode([bytes[0]]) == [])
        #expect(decoder.decode([bytes[1]]) == [.character("é")])
    }

    @Test func loneEscapeWaitsForFlush() {
        var decoder = KeyDecoder()
        #expect(decoder.decode([0x1B]) == [])
        #expect(decoder.hasPendingEscape)
        #expect(decoder.flushEscape() == [.escape])
    }

    @Test func bracketedPasteIsOneKeyWithNormalizedNewlines() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}[200~one\r\ntw".utf8)) == [])
        #expect(decoder.decode(Array("o\u{1B}[201".utf8)) == [])
        #expect(decoder.decode(Array("~x".utf8)) == [.paste("one\ntwo"), .character("x")])
    }

    @Test func distinguishesEnterNewlineAndControlKeys() {
        var decoder = KeyDecoder()
        #expect(decoder.decode([0x0D, 0x0A, 0x1B, 0x0D, 0x03]) == [.enter, .newline, .newline, .control("c")])
    }

    @Test func decodesModifiedArrowsAsWordMotion() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}[1;5D\u{1B}[1;3C\u{1B}[3~".utf8)) == [.wordLeft, .wordRight, .delete])
    }
}

@Suite struct LineEditorTests {
    @Test func editsAndSubmits() {
        var editor = LineEditor()
        editor.insert("hello world")
        _ = editor.handle(.control("w"))
        #expect(editor.string == "hello ")
        #expect(editor.submit() == "hello ")
        #expect(editor.isEmpty)
    }

    @Test func browsesHistoryAndRestoresDraft() {
        var editor = LineEditor()
        editor.insert("first")
        _ = editor.submit()
        editor.insert("draft")
        _ = editor.handle(.up)
        #expect(editor.string == "first")
        _ = editor.handle(.down)
        #expect(editor.string == "draft")
    }

    @Test func upMovesBetweenLinesBeforeHistory() {
        var editor = LineEditor()
        editor.insert("ab\ncd")
        _ = editor.handle(.up)
        #expect(editor.cursor == 2)
        _ = editor.handle(.down)
        #expect(editor.cursor == 5)
    }

    @Test func controlUJoinsLinesAtLineStart() {
        var editor = LineEditor()
        editor.insert("one\ntwo")
        _ = editor.handle(.control("u"))
        #expect(editor.string == "one\n")
        _ = editor.handle(.control("u"))
        #expect(editor.string == "one")
    }
}

@Suite struct TextWidthTests {
    @Test func measuresWideCharacters() {
        setlocale(LC_CTYPE, "")
        #expect(TextWidth.of("abc") == 3)
        #expect(TextWidth.of("日本") == 4)
        #expect(TextWidth.of("👍") == 2)
    }

    @Test func wrapsAtSpacesWithHangingIndent() {
        let rows = TextWidth.wrapStyled("  • one two three four", width: 12, indent: "    ")
        #expect(rows == ["  • one two", "    three", "    four"])
    }

    @Test func wrapReappliesStyleAndIgnoresEscapesInWidth() {
        let bold = "\u{1B}[1m"
        let rows = TextWidth.wrapStyled("\(bold)aaaa bbbb", width: 5)
        #expect(rows == ["\(bold)aaaa", "\(bold)bbbb"])
    }

    @Test func hangingIndentFollowsListMarkers() {
        #expect(TextWidth.hangingIndent(for: "  • item") == "    ")
        #expect(TextWidth.hangingIndent(for: "12. item") == "    ")
        #expect(TextWidth.hangingIndent(for: "plain") == "")
    }
}
