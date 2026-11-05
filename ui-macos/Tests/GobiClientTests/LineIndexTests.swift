import Testing
@testable import GobiClient

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

    @Test func insertingANewlineSplitsALine() {
        var index = LineIndex(utf16: units("abcd"))
        index.replace(range: 2 ..< 2, with: units("\n"))
        #expect(index == LineIndex(utf16: units("ab\ncd")))
    }

    @Test func deletingAcrossLinesJoinsThem() {
        var index = LineIndex(utf16: units("one\ntwo\nthree"))
        index.replace(range: 1 ..< 10, with: [])
        #expect(index == LineIndex(utf16: units("oree")))
    }

    @Test func replacingWithMultipleLines() {
        var index = LineIndex(utf16: units("a\nb\nc"))
        index.replace(range: 2 ..< 3, with: units("x\ny\nz"))
        #expect(index == LineIndex(utf16: units("a\nx\ny\nz\nc")))
    }

    @Test func randomEditsAlwaysMatchARebuiltIndex() {
        var generator = SeededGenerator(seed: 42)
        var text = units("line one\nline two\n\nlast")
        var index = LineIndex(utf16: text)
        let alphabet = units("ab\n😀 ")
        for _ in 0 ..< 2000 {
            let start = Int.random(in: 0 ... text.count, using: &generator)
            let end = Int.random(in: start ... min(text.count, start + 8), using: &generator)
            let inserted = (0 ..< Int.random(in: 0 ... 5, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            text.replaceSubrange(start ..< end, with: inserted)
            index.replace(range: start ..< end, with: inserted)
            #expect(index == LineIndex(utf16: text))
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
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
