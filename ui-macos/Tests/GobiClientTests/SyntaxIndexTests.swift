import Testing
@testable import GobiClient

private func lines(of units: [UInt16]) -> LineIndex { LineIndex(utf16: units) }

private func fetcher(_ units: [UInt16], _ index: LineIndex) -> (Int) -> [UInt16] {
    { line in Array(units[index.lineRange(line)]) }
}

private func build(_ text: String, _ language: SyntaxLanguage = .go) -> (SyntaxIndex, [UInt16], LineIndex) {
    let units = Array(text.utf16)
    let index = lines(of: units)
    return (SyntaxIndex(language: language, lineCount: index.lineCount, fetchLine: fetcher(units, index)), units, index)
}

/// Edits the text, its line index and the syntax index together, returning the lines whose tokens may have changed.
@discardableResult
private func edit(_ syntax: inout SyntaxIndex, _ units: inout [UInt16], _ index: inout LineIndex, range: Range<Int>, with replacement: [UInt16]) -> Range<Int> {
    let change = applyEdit(&index, &units, range: range, with: replacement)
    return syntax.update(firstLine: change.firstLine, oldLineCount: change.oldLineCount, newLineCount: change.newLineCount, fetchLine: fetcher(units, index))
}

@Suite("Syntax index")
struct SyntaxIndexTests {
    @Test func tracksMultiLineConstructsAcrossLines() {
        let (syntax, _, _) = build("a := 1\n/* start\nmiddle\nend */ b\n`raw\nstill raw`\nreturn")
        #expect(syntax.tokens(line: 0).map(\.kind) == [.number])
        #expect(syntax.tokens(line: 2).map(\.kind) == [.comment])         // "middle" is inside the block comment
        #expect(syntax.tokens(line: 3).map(\.kind) == [.comment])
        #expect(syntax.tokens(line: 5).map(\.kind) == [.string])
        #expect(syntax.tokens(line: 6).map(\.kind) == [.keyword])
    }

    @Test func openingACommentRecoloursTheLinesBelow() {
        var (syntax, units, index) = build("x := 1\ny := 2\nz := 3")
        // Insert "/*" at the start of line 0.
        let changed = edit(&syntax, &units, &index, range: 0 ..< 0, with: [0x2F, 0x2A])
        #expect(changed == 0 ..< 3)
        #expect(syntax.tokens(line: 2).map(\.kind) == [.comment])
    }

    @Test func updatesStopAsSoonAsTheStateConverges() {
        var (syntax, units, index) = build((0 ..< 1000).map { "x\($0) := \($0)" }.joined(separator: "\n"))
        let changed = edit(&syntax, &units, &index, range: 3 ..< 3, with: [0x31])
        #expect(changed == 0 ..< 1)
    }

    @Test func handlesLinesBeingAddedAndRemoved() {
        var (syntax, units, index) = build("a\nb\nc")
        let breakAt = 2   // after "a\n", split "b" into "b" + newline + "b2"
        let inserted = Array("\nb2".utf16)
        edit(&syntax, &units, &index, range: (breakAt + 1) ..< (breakAt + 1), with: inserted)
        let (rebuilt, _, _) = build(String(decoding: units, as: UTF16.self))
        #expect(syntax == rebuilt)

        edit(&syntax, &units, &index, range: 2 ..< 6, with: [])
        let (rebuiltAgain, _, _) = build(String(decoding: units, as: UTF16.self))
        #expect(syntax == rebuiltAgain)
    }

    @Test(arguments: [SyntaxLanguage.go, .json, .markdown])
    func randomEditsAlwaysMatchARebuild(language: SyntaxLanguage) {
        var generator = SeededGenerator(seed: 7)
        var units = Array("package p\n/* c */\r\nfunc f() { s := `a\nb` // t\r\treturn \"x\" }\n```\n# h\n{\"k\": [1, true]}\n".utf16)
        var index = lines(of: units)
        var syntax = SyntaxIndex(language: language, lineCount: index.lineCount, fetchLine: fetcher(units, index))
        let alphabet = Array("/*`\"'\n\r #-{}:,x1 ".utf16)
        for step in 0 ..< 1500 {
            let start = Int.random(in: 0 ... units.count, using: &generator)
            let end = Int.random(in: start ... min(units.count, start + 6), using: &generator)
            let inserted = (0 ..< Int.random(in: 0 ... 4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }

            edit(&syntax, &units, &index, range: start ..< end, with: inserted)

            let rebuilt = SyntaxIndex(language: language, lineCount: index.lineCount, fetchLine: fetcher(units, index))
            if syntax != rebuilt {
                Issue.record("diverged from a full rebuild at step \(step) for \(language)")
                return
            }
        }
    }
}
