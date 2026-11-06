import Testing
@testable import GobiModel

@Suite("Document symbols")
struct DocumentSymbolTests {
    private func range(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> (LSPPosition, LSPPosition) { (LSPPosition(line: a, character: b), LSPPosition(line: c, character: d)) }

    private func symbol(_ name: String, _ r: (LSPPosition, LSPPosition), kind: OutlineSymbol.Kind = .function, children: [DocumentSymbolInfo] = []) -> DocumentSymbolInfo {
        DocumentSymbolInfo(uri: "file:///a.go", name: name, detail: "", kind: kind, range: r, selection: r, children: children, version: 1)
    }

    @Test func theInnermostSymbolAroundTheCaretWins() {
        let field = symbol("Addr", range(4, 1, 4, 12), kind: .field)
        let server = symbol("Server", range(3, 0, 6, 1), kind: .type, children: [field])
        let found = DocumentSymbolInfo.innermost(containing: LSPPosition(line: 4, character: 3), in: [server])
        #expect(found?.name == "Addr")
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 5, character: 0), in: [server])?.name == "Server")
    }

    @Test func aCaretBetweenDeclarationsIsInNone() {
        let a = symbol("A", range(1, 0, 3, 1)), b = symbol("B", range(5, 0, 7, 1))
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 4, character: 0), in: [a, b]) == nil)
    }

    @Test func severalDeclarationsOnOneLineAreToldApartByColumn() {
        let a = symbol("A", range(2, 0, 2, 10), kind: .variable), b = symbol("B", range(2, 12, 2, 20), kind: .variable)
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 2, character: 14), in: [a, b])?.name == "B")
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 2, character: 11), in: [a, b]) == nil)
    }

    @Test func endOfTheRangeIsExclusive() {
        let a = symbol("A", range(1, 0, 1, 5))
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 1, character: 5), in: [a]) == nil)
        #expect(DocumentSymbolInfo.innermost(containing: LSPPosition(line: 1, character: 4), in: [a])?.name == "A")
    }

    @Test func theOutlineKeepsOnlyNameKindLineAndChildren() {
        let outline = symbol("Server", range(3, 0, 6, 1), kind: .type, children: [symbol("Run", range(4, 0, 5, 1), kind: .method)]).outline
        #expect(outline == OutlineSymbol(name: "Server", kind: .type, line: 3, children: [OutlineSymbol(name: "Run", kind: .method, line: 4, children: [])]))
    }
}
