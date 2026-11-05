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
        units.insert(contentsOf: [0x2F, 0x2A], at: 0)
        index.replace(range: 0 ..< 0, with: [0x2F, 0x2A])
        let changed = syntax.update(firstLine: 0, oldLineCount: 1, newLineCount: 1, fetchLine: fetcher(units, index))
        #expect(changed == 0 ..< 3)
        #expect(syntax.tokens(line: 2).map(\.kind) == [.comment])
    }

    @Test func updatesStopAsSoonAsTheStateConverges() {
        var (syntax, units, index) = build((0 ..< 1000).map { "x\($0) := \($0)" }.joined(separator: "\n"))
        units.insert(0x31, at: 3)
        index.replace(range: 3 ..< 3, with: [0x31])
        let changed = syntax.update(firstLine: 0, oldLineCount: 1, newLineCount: 1, fetchLine: fetcher(units, index))
        #expect(changed == 0 ..< 1)
    }

    @Test func handlesLinesBeingAddedAndRemoved() {
        var (syntax, units, index) = build("a\nb\nc")
        let breakAt = 2   // after "a\n", split "b" into "b" + newline + "b2"
        let inserted = Array("\nb2".utf16)
        units.insert(contentsOf: inserted, at: breakAt + 1)
        index.replace(range: (breakAt + 1) ..< (breakAt + 1), with: inserted)
        _ = syntax.update(firstLine: 1, oldLineCount: 1, newLineCount: 2, fetchLine: fetcher(units, index))
        let (rebuilt, _, _) = build(String(decoding: units, as: UTF16.self))
        #expect(syntax == rebuilt)

        units.removeSubrange(2 ..< 6)
        index.replace(range: 2 ..< 6, with: [])
        _ = syntax.update(firstLine: 1, oldLineCount: 2, newLineCount: 1, fetchLine: fetcher(units, index))
        let (rebuiltAgain, _, _) = build(String(decoding: units, as: UTF16.self))
        #expect(syntax == rebuiltAgain)
    }

    @Test(arguments: [SyntaxLanguage.go, .json, .markdown])
    func randomEditsAlwaysMatchARebuild(language: SyntaxLanguage) {
        var generator = SeededGenerator(seed: 7)
        var units = Array("package p\n/* c */\nfunc f() { s := `a\nb` // t\n\treturn \"x\" }\n```\n# h\n{\"k\": [1, true]}\n".utf16)
        var index = lines(of: units)
        var syntax = SyntaxIndex(language: language, lineCount: index.lineCount, fetchLine: fetcher(units, index))
        let alphabet = Array("/*`\"'\n #-{}:,x1 ".utf16)
        for step in 0 ..< 1500 {
            let start = Int.random(in: 0 ... units.count, using: &generator)
            let end = Int.random(in: start ... min(units.count, start + 6), using: &generator)
            let inserted = (0 ..< Int.random(in: 0 ... 4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }

            let firstLine = index.position(at: start).line
            let oldLineCount = index.position(at: end).line - firstLine + 1
            units.replaceSubrange(start ..< end, with: inserted)
            index.replace(range: start ..< end, with: inserted)
            let newLineCount = inserted.filter { $0 == 0x0A }.count + 1
            _ = syntax.update(firstLine: firstLine, oldLineCount: oldLineCount, newLineCount: newLineCount, fetchLine: fetcher(units, index))

            let rebuilt = SyntaxIndex(language: language, lineCount: index.lineCount, fetchLine: fetcher(units, index))
            if syntax != rebuilt {
                Issue.record("diverged from a full rebuild at step \(step) for \(language)")
                return
            }
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
