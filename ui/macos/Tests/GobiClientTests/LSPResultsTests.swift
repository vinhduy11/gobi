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
