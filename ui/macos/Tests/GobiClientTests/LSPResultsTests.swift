import Testing
import GobiModel
@testable import GobiClient

@Suite("Reading gopls answers")
struct LSPResultsTests {
    private func range(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [String: Any] {
        ["start": ["line": a, "character": b], "end": ["line": c, "character": d]]
    }

    @Test func aSingleLocation() {
        let found = LSPResults.locations(["uri": "file:///p/a.go", "range": range(3, 4, 3, 9)])
        #expect(found == [SourceLocation(uri: "file:///p/a.go", start: LSPPosition(line: 3, character: 4), end: LSPPosition(line: 3, character: 9))])
    }

    @Test func aListOfLocations() {
        let found = LSPResults.locations([["uri": "file:///a.go", "range": range(0, 0, 0, 1)], ["uri": "file:///b.go", "range": range(1, 0, 1, 2)]])
        #expect(found.map(\.uri) == ["file:///a.go", "file:///b.go"])
    }

    @Test func locationLinksUseTheTargetSelectionRange() {
        let link: [String: Any] = ["targetUri": "file:///c.go", "targetRange": range(10, 0, 20, 1), "targetSelectionRange": range(10, 5, 10, 9)]
        let found = LSPResults.locations([link])
        #expect(found == [SourceLocation(uri: "file:///c.go", start: LSPPosition(line: 10, character: 5), end: LSPPosition(line: 10, character: 9))])
    }

    @Test func nothingOrNullGivesNoLocations() {
        #expect(LSPResults.locations(nil).isEmpty)
        #expect(LSPResults.locations(NSNullLike.value).isEmpty)
        #expect(LSPResults.locations([] as [Any]).isEmpty)
    }

    @Test func formattingEdits() {
        let edits = LSPResults.textEdits([["range": range(0, 0, 0, 3), "newText": "foo"], ["range": range(2, 1, 2, 1), "newText": "\n"]])
        #expect(edits.count == 2)
        #expect(edits[0] == TextEdit(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3), newText: "foo"))
    }

    @Test func completionAsAListOrAsAnObject() {
        let item: [String: Any] = ["label": "Println", "kind": 3, "detail": "func(a ...any)", "insertText": "Println", "sortText": "00001"]
        let fromList = LSPResults.completions([item])
        let fromObject = LSPResults.completions(["isIncomplete": false, "items": [item]])
        #expect(fromList == fromObject)
        #expect(fromList.first?.label == "Println")
        #expect(fromList.first?.kind == .function)
        #expect(fromList.first?.insertText == "Println")
    }

    @Test func aCompletionTextEditReplacesARangeAndFallsBackToTheLabel() {
        let withEdit: [String: Any] = ["label": "fmt", "kind": 9, "textEdit": ["range": range(4, 2, 4, 5), "newText": "fmt"]]
        let plain: [String: Any] = ["label": "x"]
        let items = LSPResults.completions([withEdit, plain])
        #expect(items[0].replaces == TextEdit(start: LSPPosition(line: 4, character: 2), end: LSPPosition(line: 4, character: 5), newText: "fmt"))
        #expect(items[1].insertText == "x")
        #expect(items[1].replaces == nil)
    }

    @Test func insertTextFormatTwoMarksASnippet() {
        let items = LSPResults.completions([["label": "helper", "insertTextFormat": 2, "insertText": "helper(${1:a int})"], ["label": "x", "insertTextFormat": 1]])
        #expect(items.map(\.isSnippet) == [true, false])
    }

    @Test func completionsAreOrderedBySortTextThenLabel() {
        let items = LSPResults.completions([["label": "b", "sortText": "2"], ["label": "a", "sortText": "3"], ["label": "c", "sortText": "1"]])
        #expect(items.map(\.label) == ["c", "b", "a"])
    }

    @Test func hoverAsMarkupOrAsPlainStrings() {
        #expect(LSPResults.hoverText(["contents": ["kind": "markdown", "value": "```go\nfunc F()\n```"]]) == "```go\nfunc F()\n```")
        #expect(LSPResults.hoverText(["contents": "plain"]) == "plain")
        #expect(LSPResults.hoverText(["contents": ["one", ["language": "go", "value": "two"]]]) == "one\n\ntwo")
        #expect(LSPResults.hoverText(nil) == nil)
    }
}

/// `NSNull` without importing Foundation: any non-collection value stands for JSON null here.
private enum NSNullLike { static let value: Any = 0 }

@Suite("Reading edits and code actions")
struct LSPEditResultsTests {
    private func range(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [String: Any] {
        ["start": ["line": a, "character": b], "end": ["line": c, "character": d]]
    }

    @Test func workspaceEditWithChangesByFile() {
        let edit: [String: Any] = ["changes": ["file:///a.go": [["range": range(0, 0, 0, 3), "newText": "foo"]], "file:///b.go": [["range": range(1, 0, 1, 3), "newText": "foo"]]]]
        let changes = LSPResults.workspaceEdit(edit)
        #expect(changes.count == 2)
        #expect(changes["file:///a.go"]?.first?.newText == "foo")
    }

    @Test func workspaceEditWithDocumentChanges() {
        let edit: [String: Any] = ["documentChanges": [["textDocument": ["uri": "file:///a.go", "version": 3], "edits": [["range": range(0, 0, 0, 1), "newText": "x"]]]]]
        #expect(LSPResults.workspaceEdit(edit)["file:///a.go"]?.count == 1)
    }

    @Test func fileOperationsInADocumentChangesListAreIgnored() {
        let edit: [String: Any] = ["documentChanges": [["kind": "rename", "oldUri": "file:///a", "newUri": "file:///b"]]]
        #expect(LSPResults.workspaceEdit(edit).isEmpty)
    }

    @Test func noEditGivesNothing() {
        #expect(LSPResults.workspaceEdit(nil).isEmpty)
        #expect(LSPResults.workspaceEdit([] as [Any]).isEmpty)
    }

    @Test func codeActionsCarryTheirTitleKindAndEdit() {
        let action: [String: Any] = ["title": "Organize Imports", "kind": "source.organizeImports", "edit": ["changes": ["file:///a.go": [["range": range(2, 0, 4, 0), "newText": "import \"fmt\"\n"]]]]]
        let found = LSPResults.codeActions([action])
        #expect(found.count == 1)
        #expect(found[0].title == "Organize Imports" && found[0].kind == "source.organizeImports")
        #expect(found[0].edits["file:///a.go"]?.count == 1)
    }

    @Test func actionsThatOnlyRunACommandAreLeftOut() {
        let commandOnly: [String: Any] = ["title": "Run go mod tidy", "command": ["command": "gopls.tidy", "title": "Tidy"]]
        #expect(LSPResults.codeActions([commandOnly]).isEmpty)
    }

    @Test func anActionWithOnlyDataKeepsItsJSONSoItCanBeResolvedLater() throws {
        let action: [String: Any] = ["title": "Fill Server", "kind": "refactor.rewrite.fillStruct", "data": ["uri": "file:///a.go", "fixType": "fillstruct"]]
        let found = LSPResults.codeActions([action])
        #expect(found.count == 1 && found[0].edits.isEmpty)
        let json = try #require(found[0].resolveData)
        #expect(json.contains("\"Fill Server\"") && json.contains("\"fixType\"") && json.contains("fillstruct"))
    }

    @Test func aResolvedActionGivesItsEdit() {
        let resolved: [String: Any] = ["title": "Fill Server", "kind": "refactor.rewrite.fillStruct", "edit": ["documentChanges": [["textDocument": ["uri": "file:///a.go", "version": 1], "edits": [["range": range(5, 0, 5, 0), "newText": "x"]]]]]]
        let action = LSPResults.resolvedCodeAction(resolved, fallback: CodeAction(title: "Fill Server", kind: "k", edits: [:]))
        #expect(action.edits["file:///a.go"]?.count == 1 && action.resolveData == nil)
    }

    @Test func referencesAreLocations() {
        let found = LSPResults.locations([["uri": "file:///a.go", "range": range(3, 1, 3, 4)], ["uri": "file:///b.go", "range": range(9, 2, 9, 5)]])
        #expect(found.map(\.start.line) == [3, 9])
    }
}

@Suite("Reading symbols")
struct LSPSymbolResultsTests {
    private func range(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [String: Any] {
        ["start": ["line": a, "character": b], "end": ["line": c, "character": d]]
    }

    @Test func aDocumentSymbolTreeKeepsItsChildren() {
        let result: [Any] = [["name": "Server", "kind": 23, "range": range(3, 0, 20, 1), "selectionRange": range(3, 5, 3, 11), "children": [["name": "Run", "kind": 6, "range": range(10, 0, 15, 1), "selectionRange": range(10, 17, 10, 20)]]]]
        let symbols = LSPResults.documentSymbols(result)
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "Server" && symbols[0].line == 3 && symbols[0].kind == .type)
        #expect(symbols[0].children.first?.name == "Run" && symbols[0].children.first?.line == 10)
    }

    @Test func symbolInformationIsFlat() {
        let result: [Any] = [["name": "main", "kind": 12, "location": ["uri": "file:///a.go", "range": range(7, 0, 9, 1)]]]
        let symbols = LSPResults.documentSymbols(result)
        #expect(symbols.map(\.name) == ["main"] && symbols[0].line == 7)
    }

    @Test func workspaceSymbolsCarryTheirLocation() {
        let result: [Any] = [["name": "NewServer", "kind": 12, "containerName": "server", "location": ["uri": "file:///x/server.go", "range": range(4, 5, 4, 14)]]]
        let found = LSPResults.workspaceSymbols(result)
        #expect(found.count == 1)
        #expect(found[0].name == "NewServer" && found[0].container == "server" && found[0].location.start.line == 4)
    }

    @Test func nothingGivesNothing() {
        #expect(LSPResults.documentSymbols(nil).isEmpty)
        #expect(LSPResults.workspaceSymbols(nil).isEmpty)
    }
}

@Suite("Reading document symbols in full")
struct LSPDocumentSymbolTreeTests {
    private func range(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [String: Any] {
        ["start": ["line": a, "character": b], "end": ["line": c, "character": d]]
    }
    private func parse(_ result: Any?) -> [DocumentSymbolInfo] { LSPResults.documentSymbolInfos(result, uri: "file:///a.go", version: 7) }

    @Test func nestedDeclarationsKeepRangesDetailAndVersion() {
        let result: [Any] = [["name": "Server", "kind": 23, "detail": "struct{...}", "range": range(3, 0, 20, 1), "selectionRange": range(3, 5, 3, 11),
                              "children": [["name": "Addr", "kind": 8, "detail": "string", "range": range(4, 1, 4, 12), "selectionRange": range(4, 1, 4, 5)]]]]
        let symbols = parse(result)
        #expect(symbols.count == 1 && symbols[0].uri == "file:///a.go" && symbols[0].version == 7)
        #expect(symbols[0].range.1.line == 20 && symbols[0].selection.0.character == 5 && symbols[0].detail == "struct{...}")
        #expect(symbols[0].children.first?.name == "Addr" && symbols[0].children.first?.detail == "string" && symbols[0].children.first?.kind == .field)
        #expect(symbols[0].children.first?.version == 7)
    }

    @Test func methodsWithReceiversAndEmbeddedFieldsAndGenericsKeepTheirNames() {
        let result: [Any] = [
            ["name": "(*Server).Run", "kind": 6, "range": range(10, 0, 12, 1), "selectionRange": range(10, 16, 10, 19)],
            ["name": "Stack[T]", "kind": 23, "range": range(14, 0, 18, 1), "selectionRange": range(14, 5, 14, 10),
             "children": [["name": "Base", "kind": 8, "range": range(15, 1, 15, 5), "selectionRange": range(15, 1, 15, 5)]]],
        ]
        let symbols = parse(result)
        #expect(symbols.map(\.name) == ["(*Server).Run", "Stack[T]"] && symbols[0].kind == .method)
        #expect(symbols[1].children.map(\.name) == ["Base"])
    }

    @Test func severalDeclarationsOnOneLineStayApart() {
        let result: [Any] = [["name": "a", "kind": 13, "range": range(2, 4, 2, 9), "selectionRange": range(2, 4, 2, 5)], ["name": "b", "kind": 13, "range": range(2, 11, 2, 16), "selectionRange": range(2, 11, 2, 12)]]
        let symbols = parse(result)
        #expect(symbols.map(\.selection.0.character) == [4, 11])
    }

    @Test func theFlatFallbackHasNoChildrenOrDetail() {
        let result: [Any] = [["name": "main", "kind": 12, "location": ["uri": "file:///a.go", "range": range(7, 0, 9, 1)]]]
        let symbols = parse(result)
        #expect(symbols.count == 1 && symbols[0].children.isEmpty && symbols[0].detail.isEmpty && symbols[0].range.1.line == 9 && symbols[0].selection.0.line == 7)
    }

    @Test func nothingGivesNothing() { #expect(parse(nil).isEmpty) }

    @Test func theOutlineStillComesOutTheSame() {
        let result: [Any] = [["name": "Server", "kind": 23, "range": range(3, 0, 20, 1), "selectionRange": range(3, 5, 3, 11), "children": [["name": "Run", "kind": 6, "range": range(10, 0, 15, 1), "selectionRange": range(10, 17, 10, 20)]]]]
        #expect(parse(result).map(\.outline) == LSPResults.documentSymbols(result))
    }
}

@Suite("What the client advertises")
struct LSPCapabilitiesTests {
    @Test func hierarchicalDocumentSymbolsAreAdvertised() {
        let textDocument = LSPClient.clientCapabilities["textDocument"] as? [String: Any]
        let symbol = textDocument?["documentSymbol"] as? [String: Any]
        #expect(symbol?["hierarchicalDocumentSymbolSupport"] as? Bool == true)
    }

    @Test func editResolutionIsAdvertisedForCodeActions() {
        let textDocument = LSPClient.clientCapabilities["textDocument"] as? [String: Any]
        let resolve = (textDocument?["codeAction"] as? [String: Any])?["resolveSupport"] as? [String: Any]
        #expect(resolve?["properties"] as? [String] == ["edit"])
    }
}

@Suite("Semantic tokens over LSP")
struct LSPSemanticTokensTests {
    @Test func theClientAdvertisesTheTokenTypesGoplsUses() {
        let textDocument = LSPClient.clientCapabilities["textDocument"] as? [String: Any]
        let tokens = textDocument?["semanticTokens"] as? [String: Any]
        #expect((tokens?["requests"] as? [String: Any])?["full"] as? Bool == true)
        #expect(tokens?["formats"] as? [String] == ["relative"])
        // gopls only sends the types and modifiers the client lists, so every one it can use must be there.
        let types = Set(tokens?["tokenTypes"] as? [String] ?? [])
        #expect(types.isSuperset(of: ["namespace", "type", "typeParameter", "parameter", "property", "variable", "function", "method", "macro", "keyword", "comment", "string", "number", "operator", "label"]))
        let modifiers = Set(tokens?["tokenModifiers"] as? [String] ?? [])
        #expect(modifiers.isSuperset(of: ["definition", "readonly", "defaultLibrary", "static", "array", "bool", "chan", "format", "interface", "map", "number", "pointer", "signature", "slice", "string", "struct", "shadowing"]))
    }

    @Test func theDataArrayIsReadFromTheAnswer() {
        #expect(LSPResults.semanticTokenData(["resultId": "1", "data": [0, 6, 1, 3, 1, 0, 3, 5, 1, 0]] as [String: Any]) == [0, 6, 1, 3, 1, 0, 3, 5, 1, 0])
        #expect(LSPResults.semanticTokenData(["data": [Int]()] as [String: Any]) == [])
        #expect(LSPResults.semanticTokenData(nil).isEmpty)
        #expect(LSPResults.semanticTokenData("nonsense").isEmpty)
        #expect(LSPResults.semanticTokenData(["data": ["a", "b"]] as [String: Any]).isEmpty)
    }
}
