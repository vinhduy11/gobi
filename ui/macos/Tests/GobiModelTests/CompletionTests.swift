import Testing
@testable import GobiModel

@Suite("Completion list")
struct CompletionListTests {
    private func item(_ label: String, kind: CompletionKind = .function, sort: String? = nil) -> CompletionItem {
        CompletionItem(label: label, kind: kind, detail: "", insertText: label, replaces: nil, sortText: sort ?? label)
    }

    @Test func anEmptyPrefixShowsEverythingInTheServersOrder() {
        let list = CompletionList(items: [item("Println"), item("Printf"), item("Sprint")], anchorOffset: 10)
        #expect(list.visible.map(\.label) == ["Println", "Printf", "Sprint"])
    }

    @Test func labelsThatStartWithThePrefixComeFirstThenTheLooserMatches() {
        var list = CompletionList(items: [item("Sprint"), item("Println"), item("Fprint"), item("Printf"), item("Close")], anchorOffset: 0)
        list.update(prefix: "Pri")
        #expect(Array(list.visible.map(\.label).prefix(2)) == ["Println", "Printf"])
        #expect(Set(list.visible.map(\.label)) == ["Println", "Printf", "Sprint", "Fprint"])
    }

    @Test func matchingIgnoresCase() {
        var list = CompletionList(items: [item("Println"), item("Sprint")], anchorOffset: 0)
        list.update(prefix: "pri")
        #expect(list.visible.map(\.label).first == "Println")
    }

    @Test func prefixMatchesComeBeforeLooserMatches() {
        var list = CompletionList(items: [item("NewPrinter"), item("Print"), item("Fprint")], anchorOffset: 0)
        list.update(prefix: "pr")
        #expect(list.visible.map(\.label).first == "Print")
        #expect(list.visible.map(\.label).contains("NewPrinter"))
    }

    @Test func lettersInOrderMatchLikeAnAbbreviation() {
        var list = CompletionList(items: [item("ReadHeaderTimeout"), item("Reader")], anchorOffset: 0)
        list.update(prefix: "rht")
        #expect(list.visible.map(\.label) == ["ReadHeaderTimeout"])
    }

    @Test func nothingMatchingEmptiesTheList() {
        var list = CompletionList(items: [item("Println")], anchorOffset: 0)
        list.update(prefix: "zzz")
        #expect(list.visible.isEmpty && list.selected == nil)
    }

    @Test func theSelectionMovesAndWraps() {
        var list = CompletionList(items: [item("a"), item("b"), item("c")], anchorOffset: 0)
        #expect(list.selected?.label == "a")
        list.moveDown()
        #expect(list.selected?.label == "b")
        list.moveUp(); list.moveUp()
        #expect(list.selected?.label == "c")
        list.moveDown()
        #expect(list.selected?.label == "a")
    }

    @Test func updatingThePrefixResetsTheSelectionToTheFirst() {
        var list = CompletionList(items: [item("apple"), item("apricot"), item("banana")], anchorOffset: 0)
        list.moveDown()
        list.update(prefix: "ap")
        #expect(list.selectedIndex == 0)
    }

    @Test func atMostTwoHundredItemsAreShown() {
        let many = (0 ..< 500).map { item("Item\($0)") }
        #expect(CompletionList(items: many, anchorOffset: 0).visible.count == 200)
    }
}

@Suite("Completion prefix and trigger")
struct CompletionPrefixTests {
    private func prefix(_ text: String) -> (String, Int) {
        let units = Array(text.utf16)
        let found = CompletionPrefix.current(before: units, caret: units.count)
        return (found.text, found.start)
    }

    @Test func theIdentifierBeforeTheCaretIsThePrefix() {
        #expect(prefix("fmt.Pri") == ("Pri", 4))
        #expect(prefix("x := foo_bar2") == ("foo_bar2", 5))
    }

    @Test func rightAfterADotThePrefixIsEmpty() {
        #expect(prefix("fmt.") == ("", 4))
    }

    @Test func spacesAndPunctuationEndThePrefix() {
        #expect(prefix("a, ") == ("", 3))
        #expect(prefix("f(x") == ("x", 2))
    }

    @Test func aDotAlwaysTriggersAndALetterTriggersOnceThereIsOne() {
        #expect(CompletionTrigger.shouldOpen(typed: ".", prefixLength: 0))
        #expect(CompletionTrigger.shouldOpen(typed: "P", prefixLength: 1))
        #expect(!CompletionTrigger.shouldOpen(typed: " ", prefixLength: 0))
        #expect(!CompletionTrigger.shouldOpen(typed: "(", prefixLength: 0))
    }

    @Test func theListClosesWhenTheTypedTextLeavesTheIdentifier() {
        #expect(CompletionTrigger.shouldClose(typed: " "))
        #expect(CompletionTrigger.shouldClose(typed: "("))
        #expect(CompletionTrigger.shouldClose(typed: ")"))
        #expect(!CompletionTrigger.shouldClose(typed: "a"))
        #expect(!CompletionTrigger.shouldClose(typed: "_"))
    }
}

@Suite("Hover text")
struct HoverTextTests {
    @Test func codeFencesAreDroppedAndTheCodeKept() {
        #expect(HoverText.plain(fromMarkdown: "```go\nfunc F()\n```\n\nDoc text") == "func F()\n\nDoc text")
    }

    @Test func plainTextStaysAsItIs() {
        #expect(HoverText.plain(fromMarkdown: "just words") == "just words")
    }

    @Test func linksKeepTheirLabel() {
        #expect(HoverText.plain(fromMarkdown: "see [the docs](https://pkg.go.dev/fmt) now") == "see the docs now")
    }

    @Test func longTextIsCutToFourteenLinesWithAnEllipsis() {
        let long = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        let cut = HoverText.plain(fromMarkdown: long)
        #expect(cut.split(separator: "\n").count == 15)
        #expect(cut.hasSuffix("…"))
    }

    @Test func blankInputGivesAnEmptyString() {
        #expect(HoverText.plain(fromMarkdown: "  \n\n ") == "")
    }
}
