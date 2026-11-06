import Testing
@testable import GobiModel

@Suite("Invisible marks")
struct InvisibleMarksTests {
    @Test func tabsTrailingSpacesAndLineEnd() {
        let marks = InvisibleMarks.find(in: "\tx  \n")
        #expect(marks == [InvisibleMark(offset: 0, symbol: "→"), InvisibleMark(offset: 2, symbol: "·"), InvisibleMark(offset: 3, symbol: "·"), InvisibleMark(offset: 4, symbol: "¶")])
    }

    @Test func spacesInsideTheLineAreNotMarked() {
        #expect(InvisibleMarks.find(in: "a b\n") == [InvisibleMark(offset: 3, symbol: "¶")])
    }

    @Test func aLastLineWithoutABreakHasNoLineEndMark() {
        #expect(InvisibleMarks.find(in: "a ") == [InvisibleMark(offset: 1, symbol: "·")])
    }

    @Test func crlfMarksTheReturn() {
        #expect(InvisibleMarks.find(in: "a\r\n") == [InvisibleMark(offset: 1, symbol: "¶")])
    }
}
