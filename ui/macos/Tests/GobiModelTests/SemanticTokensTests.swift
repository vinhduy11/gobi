import Testing
@testable import GobiModel

/// gopls' legend, as it sends it.
private let goplsLegend = SemanticLegend(
    types: ["namespace", "type", "typeParameter", "parameter", "property", "variable", "function", "method", "macro", "keyword", "comment", "string", "number", "operator", "label"],
    modifiers: ["definition", "readonly", "defaultLibrary", "static", "array", "bool", "chan", "format", "interface", "map", "number", "pointer", "signature", "slice", "string", "struct", "shadowing"])

@Suite("Semantic tokens")
struct SemanticTokensTests {
    /// `func (s *Store) Name() string { return s.name }` as gopls reports it, one token per row (line delta, start delta, length, type, modifiers).
    private let receiverLine: [Int] = [
        0, 6, 1, 3, 1,      // s     parameter, definition
        0, 3, 5, 1, 0,      // Store type
        0, 7, 4, 7, 1,      // Name  method, definition
        0, 7, 6, 1, 4,      // string type, defaultLibrary
        0, 9, 1, 3, 0,      // s     parameter
        0, 2, 4, 4, 0,      // name  property
    ]

    @Test func tokensBecomeKindsPerLine() {
        let lines = SemanticTokens.decode(receiverLine, legend: goplsLegend)
        #expect(lines.keys.sorted() == [0])
        #expect(lines[0]?.map(\.kind) == [.parameter, .typeName, .function, .builtin, .parameter, .property])
        #expect(lines[0]?.map(\.start) == [6, 9, 16, 23, 32, 34])
        #expect(lines[0]?.map(\.length) == [1, 5, 4, 6, 1, 4])
    }

    @Test func aStartRestartsOnANewLine() {
        // namespace at 8 on line 0, then the next row is two lines down and its start is absolute again.
        let data = [0, 8, 4, 0, 0, 2, 3, 3, 6, 0]
        let lines = SemanticTokens.decode(data, legend: goplsLegend)
        #expect(lines[0]?.first == SyntaxToken(start: 8, length: 4, kind: .namespace))
        #expect(lines[2]?.first == SyntaxToken(start: 3, length: 3, kind: .function))
    }

    @Test func readonlyVariablesAreConstantsAndTheOtherVariablesStayPlain() {
        // const Timeout (variable, definition+readonly), then a plain local (variable).
        let data = [0, 6, 7, 5, 0b11, 1, 1, 1, 5, 1]
        let lines = SemanticTokens.decode(data, legend: goplsLegend)
        #expect(lines[0]?.map(\.kind) == [.constant])
        #expect(lines[1] == nil)
    }

    @Test func whatTheLexerAlreadyColoursIsLeftToIt() {
        // keyword, comment, string, number, operator, macro and label rows produce nothing.
        let data = [0, 0, 4, 9, 0, 0, 5, 3, 10, 0, 0, 4, 3, 11, 0, 0, 4, 2, 12, 0, 0, 3, 1, 13, 0, 0, 2, 2, 8, 0, 0, 3, 2, 14, 0]
        #expect(SemanticTokens.decode(data, legend: goplsLegend).isEmpty)
    }

    @Test func aRowWithAnUnknownTypeOrATruncatedTailIsSkipped() {
        #expect(SemanticTokens.decode([0, 0, 3, 99, 0], legend: goplsLegend).isEmpty)
        #expect(SemanticTokens.decode([0, 0, 3, 6, 0, 0, 4], legend: goplsLegend)[0]?.map(\.kind) == [.function])
        #expect(SemanticTokens.decode([], legend: goplsLegend).isEmpty)
    }

    @Test func theLegendComesFromTheInitializeAnswer() {
        let capabilities: [String: Any] = ["semanticTokensProvider": ["legend": ["tokenTypes": ["type", "function"], "tokenModifiers": ["readonly"]], "full": true]]
        #expect(SemanticLegend(capabilities: capabilities) == SemanticLegend(types: ["type", "function"], modifiers: ["readonly"]))
        #expect(SemanticLegend(capabilities: [:]) == nil)
    }
}

@Suite("Semantic overlay while typing")
struct SemanticOverlayTests {
    private func token(_ start: Int32, _ kind: SyntaxKind = .function) -> SyntaxToken { SyntaxToken(start: start, length: 3, kind: kind) }

    private func overlay() -> SemanticOverlay {
        var overlay = SemanticOverlay()
        overlay.replace([0: [token(1)], 1: [token(2)], 2: [token(3)], 3: [token(4)]])
        return overlay
    }

    @Test func tokensAreReadByLine() {
        let overlay = overlay()
        #expect(overlay.tokens(line: 2) == [token(3)])
        #expect(overlay.tokens(line: 9).isEmpty)
    }

    @Test func editingALineDropsItsTokensAndKeepsTheOthers() {
        var overlay = overlay()
        overlay.edited(firstLine: 1, oldLineCount: 1, newLineCount: 1)
        #expect(overlay.tokens(line: 0) == [token(1)] && overlay.tokens(line: 1).isEmpty && overlay.tokens(line: 2) == [token(3)])
    }

    @Test func insertingALineMovesTheLinesBelowDown() {
        var overlay = overlay()
        overlay.edited(firstLine: 1, oldLineCount: 1, newLineCount: 2)   // a Return in line 1
        #expect(overlay.tokens(line: 0) == [token(1)])
        #expect(overlay.tokens(line: 1).isEmpty && overlay.tokens(line: 2).isEmpty)
        #expect(overlay.tokens(line: 3) == [token(3)] && overlay.tokens(line: 4) == [token(4)])
    }

    @Test func deletingLinesMovesTheLinesBelowUp() {
        var overlay = overlay()
        overlay.edited(firstLine: 1, oldLineCount: 2, newLineCount: 1)   // lines 1 and 2 joined
        #expect(overlay.tokens(line: 0) == [token(1)] && overlay.tokens(line: 1).isEmpty)
        #expect(overlay.tokens(line: 2) == [token(4)])
        #expect(overlay.tokens(line: 3).isEmpty)
    }

    @Test func replacingTakesTheNewAnswerWholesale() {
        var overlay = overlay()
        overlay.replace([5: [token(9)]])
        #expect(overlay.tokens(line: 0).isEmpty && overlay.tokens(line: 5) == [token(9)])
    }
}
