import Testing
@testable import GobiModel

@Suite("Applying LSP text edits")
struct TextEditsTests {
    private func apply(_ edits: [TextEdit], to text: String) -> String {
        let units = Array(text.utf16)
        let index = LineIndex(utf16: units)
        let result = TextEdits.apply(edits, to: units, lineIndex: index)
        return String(decoding: result, as: UTF16.self)
    }

    private func edit(_ startLine: Int, _ startColumn: Int, _ endLine: Int, _ endColumn: Int, _ text: String) -> TextEdit {
        TextEdit(start: LSPPosition(line: startLine, character: startColumn), end: LSPPosition(line: endLine, character: endColumn), newText: text)
    }

    @Test func aSingleReplacement() {
        #expect(apply([edit(0, 0, 0, 5, "howdy")], to: "hello world") == "howdy world")
    }

    @Test func severalEditsAreAppliedAgainstTheOriginalPositions() {
        let result = apply([edit(0, 0, 0, 1, "H"), edit(1, 0, 1, 1, "W")], to: "hello\nworld")
        #expect(result == "Hello\nWorld")
    }

    @Test func editsGivenOutOfOrderGiveTheSameResult() {
        let ordered = apply([edit(0, 0, 0, 1, "H"), edit(1, 0, 1, 1, "W")], to: "hello\nworld")
        let reversed = apply([edit(1, 0, 1, 1, "W"), edit(0, 0, 0, 1, "H")], to: "hello\nworld")
        #expect(ordered == reversed)
    }

    @Test func anInsertionAndADeletion() {
        #expect(apply([edit(0, 3, 0, 3, "-")], to: "abcdef") == "abc-def")
        #expect(apply([edit(0, 1, 0, 3, "")], to: "abcdef") == "adef")
    }

    @Test func aMultiLineReplacement() {
        #expect(apply([edit(0, 1, 2, 1, "X")], to: "abc\ndef\nghi") == "aXhi")
    }

    @Test func columnsCountUTF16UnitsSoAnEmojiIsTwo() {
        #expect(apply([edit(0, 3, 0, 4, "!")], to: "a😀b") == "a😀!")
    }

    @Test func noEditsLeavesTheTextAlone() {
        #expect(apply([], to: "same") == "same")
    }

    @Test func editsPastTheEndAreClamped() {
        #expect(apply([edit(5, 0, 5, 0, "end")], to: "abc") == "abcend")
    }

    @Test func theChangedRangeSpansTheFirstToTheLastEdit() {
        let units = Array("hello\nworld".utf16)
        let index = LineIndex(utf16: units)
        let range = TextEdits.affectedLines([edit(0, 0, 0, 1, "H"), edit(1, 0, 1, 1, "W")], lineIndex: index)
        #expect(range == 0 ... 1)
    }
}
