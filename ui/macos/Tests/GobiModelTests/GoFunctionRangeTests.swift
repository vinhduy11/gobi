import Testing
@testable import GobiModel

@Suite("Go function range")
struct GoFunctionRangeTests {
    private func lines(_ text: String) -> [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    @Test func plainFunctionEndsAtItsClosingBrace() {
        let source = lines("package p\n\nfunc alpha() {\n\tif x {\n\t}\n}\n\nfunc beta() {}\n")
        #expect(GoFunctionRange.lines(in: source, from: 3) == 3 ... 6)
        #expect(GoFunctionRange.lines(in: source, from: 8) == 8 ... 8)
    }

    @Test func bracesInStringsRunesRawStringsAndCommentsAreIgnored() {
        let source = lines("func alpha() {\n\ts := \"}\\\"}\"\n\tr := '}'\n\tq := '\\''\n\traw := `}\n}\n`\n\t// }\n\t/* }\n} */\n}\nfunc after() {}")
        #expect(GoFunctionRange.lines(in: source, from: 1) == 1 ... 11)
    }

    @Test func braceTypesInTheSignatureAreNotTheBody() {
        let source = lines("func alpha(x struct{ n int }) interface{} {\n\treturn nil\n}\nfunc beta(f func() {}) {\n}")
        #expect(GoFunctionRange.lines(in: source, from: 1) == 1 ... 3)
    }

    @Test func multiLineSignatureAndUnterminatedFunction() {
        let source = lines("func alpha(\n\tx int,\n) (\n\tint, error,\n) {\n\treturn 1, nil\n}")
        #expect(GoFunctionRange.lines(in: source, from: 1) == 1 ... 7)
        #expect(GoFunctionRange.lines(in: lines("func alpha() {\n\tx()\n"), from: 1) == nil)
        #expect(GoFunctionRange.lines(in: source, from: 99) == nil)
    }

    @Test func declarationAboveALineIsFound() {
        let source = lines("package p\n\nfunc (s *S) alpha() {\n\tx()\n\ty()\n}\n")
        #expect(GoFunctionRange.declaration(in: source, atOrBefore: 5) == 3)
        #expect(GoFunctionRange.declaration(in: source, atOrBefore: 2) == nil)
    }

    @Test func startLineIsReadFromTheReply() throws {
        var head = WireWriter()
        head.string(1, "/p/main.go"); head.uint(3, 18)
        #expect(try ProfileLines.parse(try WireField.parse(head.bytes)).startLine == 18)
        #expect(try ProfileLines.parse([]).startLine == 0)
    }
}
