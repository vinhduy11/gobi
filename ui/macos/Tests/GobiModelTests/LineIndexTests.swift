import Testing
@testable import GobiModel

private func units(_ text: String) -> [UInt16] { Array(text.utf16) }

@Suite("Line index")
struct LineIndexTests {
    @Test func mapsOffsetsToLineAndColumn() {
        let index = LineIndex(utf16: units("ab\ncd\n\nef"))
        #expect(index.lineCount == 4)
        #expect(index.position(at: 0) == LSPPosition(line: 0, character: 0))
        #expect(index.position(at: 2) == LSPPosition(line: 0, character: 2))   // just before the newline
        #expect(index.position(at: 3) == LSPPosition(line: 1, character: 0))
        #expect(index.position(at: 6) == LSPPosition(line: 2, character: 0))   // the empty line
        #expect(index.position(at: 9) == LSPPosition(line: 3, character: 2))   // end of text
    }

    @Test func columnsCountUTF16UnitsLikeTheProtocol() {
        let index = LineIndex(utf16: units("a😀b"))   // the emoji is two UTF-16 units
        #expect(index.position(at: 3) == LSPPosition(line: 0, character: 3))
        #expect(index.offset(of: LSPPosition(line: 0, character: 3)) == 3)
    }

    @Test func mapsPositionsBackToOffsetsAndClamps() {
        let index = LineIndex(utf16: units("ab\ncd"))
        #expect(index.offset(of: LSPPosition(line: 1, character: 1)) == 4)
        #expect(index.offset(of: LSPPosition(line: 0, character: 99)) == 2)    // clamps to the end of the line
        #expect(index.offset(of: LSPPosition(line: 9, character: 0)) == 5)     // past the last line: end of text
    }

    @Test func aTrailingNewlineStartsAnEmptyLastLine() {
        let index = LineIndex(utf16: units("ab\n"))
        #expect(index.lineCount == 2)
        #expect(index.position(at: 3) == LSPPosition(line: 1, character: 0))
    }

    @Test func emptyTextHasOneLine() {
        let index = LineIndex(utf16: [])
        #expect(index.lineCount == 1)
        #expect(index.position(at: 0) == LSPPosition(line: 0, character: 0))
    }

    // MARK: line breaks: \n, \r\n and a lone \r, as the protocol defines them

    @Test func aLoneCarriageReturnIsALineBreak() {
        let index = LineIndex(utf16: units("a\rbc\rd"))
        #expect(index.lineCount == 3)
        #expect(index.lineRange(0) == 0 ..< 1)
        #expect(index.lineRange(1) == 2 ..< 4)
        #expect(index.lineRange(2) == 5 ..< 6)
        #expect(index.position(at: 2) == LSPPosition(line: 1, character: 0))
        #expect(index.offset(of: LSPPosition(line: 1, character: 99)) == 4)
    }

    @Test func carriageReturnLineFeedIsOneBreakAndColumnsStopBeforeIt() {
        let index = LineIndex(utf16: units("a\r\nbc\r\nd"))
        #expect(index.lineCount == 3)
        #expect(index.lineRange(0) == 0 ..< 1)
        #expect(index.lineRange(1) == 3 ..< 5)
        #expect(index.position(at: 3) == LSPPosition(line: 1, character: 0))
        #expect(index.position(at: 2) == LSPPosition(line: 0, character: 1))   // between the CR and the LF: still the end of line 0
        #expect(index.offset(of: LSPPosition(line: 0, character: 99)) == 1)
    }

    @Test func mixedBreaksAndTrailingBreaks() {
        let index = LineIndex(utf16: units("a\rb\r\nc\nd\r"))
        #expect(index.lineCount == 5)
        #expect(index.lineRange(4) == 9 ..< 9)   // an empty last line after the final CR
        #expect(LineIndex(utf16: units("x\r\n")).lineCount == 2)
    }

    /// The same text and the same expectations as `TestPositionsFollowAllThreeLineBreaks` in core/internal/langsvc: the editor
    /// and the Go side must agree on every position.
    @Test func positionsAgreeWithTheGoSide() {
        let index = LineIndex(utf16: units("a\rbc\r\nd\ne"))
        let expected: [(Int, LSPPosition)] = [
            (0, LSPPosition(line: 0, character: 0)), (2, LSPPosition(line: 1, character: 0)), (4, LSPPosition(line: 1, character: 2)),
            (5, LSPPosition(line: 1, character: 2)), (6, LSPPosition(line: 2, character: 0)), (8, LSPPosition(line: 3, character: 0)),
            (9, LSPPosition(line: 3, character: 1)),
        ]
        for (offset, position) in expected { #expect(index.position(at: offset) == position, "offset \(offset)") }
        #expect(index.lineCount == 4)
        #expect(index.lineRange(1) == 2 ..< 4)
    }

    @Test func insertingALineFeedAfterACarriageReturnJoinsThemIntoOneBreak() {
        var text = units("a\rb")
        var index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 2 ..< 2, with: units("\n"))
        #expect(text == units("a\r\nb"))
        #expect(index.lineCount == 2)
        #expect(index == LineIndex(utf16: text))
    }

    @Test func insertingACarriageReturnBeforeALineFeedJoinsThemToo() {
        var text = units("a\nb")
        var index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 1 ..< 1, with: units("\r"))
        #expect(index.lineCount == 2)
        #expect(index == LineIndex(utf16: text))
    }

    @Test func typingBetweenACarriageReturnAndALineFeedSplitsTheBreak() {
        var text = units("a\r\nb")
        var index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 2 ..< 2, with: units("x"))
        #expect(text == units("a\rx\nb"))
        #expect(index.lineCount == 3)
        #expect(index == LineIndex(utf16: text))
    }

    @Test func deletingOneHalfOfACarriageReturnLineFeedLeavesTheOther() {
        var text = units("a\r\nb")
        var index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 2 ..< 3, with: [])   // delete the LF: a lone CR remains
        #expect(index.lineCount == 2)
        #expect(index == LineIndex(utf16: text))

        text = units("a\r\nb")
        index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 1 ..< 2, with: [])   // delete the CR: a lone LF remains
        #expect(index.lineCount == 2)
        #expect(index == LineIndex(utf16: text))
    }

    @Test func deletingTheBreakJoinsTheLines() {
        var text = units("one\r\ntwo\rthree")
        var index = LineIndex(utf16: text)
        applyEdit(&index, &text, range: 3 ..< 5, with: [])
        #expect(index == LineIndex(utf16: text))
        #expect(index.lineCount == 2)
    }

    // MARK: edits

    @Test func insertingANewlineSplitsALine() {
        var text = units("abcd")
        var index = LineIndex(utf16: text)
        let change = applyEdit(&index, &text, range: 2 ..< 2, with: units("\n"))
        #expect(index == LineIndex(utf16: text))
        #expect(change == LineChange(firstLine: 0, oldLineCount: 1, newLineCount: 2))
    }

    @Test func deletingAcrossLinesJoinsThem() {
        var text = units("one\ntwo\nthree")
        var index = LineIndex(utf16: text)
        let change = applyEdit(&index, &text, range: 1 ..< 10, with: [])
        #expect(index == LineIndex(utf16: text))
        #expect(change == LineChange(firstLine: 0, oldLineCount: 3, newLineCount: 1))
    }

    @Test func replacingWithMultipleLines() {
        var text = units("a\nb\nc")
        var index = LineIndex(utf16: text)
        let change = applyEdit(&index, &text, range: 2 ..< 3, with: units("x\ny\nz"))
        #expect(index == LineIndex(utf16: text))
        #expect(change == LineChange(firstLine: 1, oldLineCount: 1, newLineCount: 3))
    }

    @Test func theReportedChangeAlwaysAccountsForTheLineCount() {
        var generator = SeededGenerator(seed: 99)
        var text = units("one\r\ntwo\nthree\rfour")
        var index = LineIndex(utf16: text)
        let alphabet = units("ab\r\n 😀")
        for step in 0 ..< 4000 {
            let start = Int.random(in: 0 ... text.count, using: &generator)
            let end = Int.random(in: start ... min(text.count, start + 6), using: &generator)
            let inserted = (0 ..< Int.random(in: 0 ... 5, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let linesBefore = index.lineCount
            let change = applyEdit(&index, &text, range: start ..< end, with: inserted)
            guard index == LineIndex(utf16: text) else {
                Issue.record("index diverged from a rebuild at step \(step): range \(start)..<\(end), inserted \(inserted), text \(text)")
                return
            }
            guard index.lineCount - linesBefore == change.newLineCount - change.oldLineCount,
                  change.firstLine >= 0, change.firstLine + change.newLineCount <= index.lineCount else {
                Issue.record("change \(change) does not account for the line count at step \(step)")
                return
            }
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
