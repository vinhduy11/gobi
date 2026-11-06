import Testing
@testable import GobiModel

@Suite("Auto close") struct AutoCloseTests {
    @Test func anOpeningBracketGetsItsPartnerAtTheEndOfALineOrBeforeWhitespaceOrAClosingBracket() {
        #expect(AutoClose.typed("{", before: " ", after: nil, hasSelection: false) == .insert("{}", caretBack: 1))
        #expect(AutoClose.typed("(", before: "f", after: " ", hasSelection: false) == .insert("()", caretBack: 1))
        #expect(AutoClose.typed("[", before: nil, after: ")", hasSelection: false) == .insert("[]", caretBack: 1))
        #expect(AutoClose.typed("{", before: " ", after: ",", hasSelection: false) == .insert("{}", caretBack: 1))
    }

    @Test func noPartnerWhenTheNextCharacterIsWordText() {
        #expect(AutoClose.typed("(", before: "f", after: "x", hasSelection: false) == .none)
        #expect(AutoClose.typed("{", before: " ", after: "\"", hasSelection: false) == .none)
    }

    @Test func aClosingBracketTypedBeforeItselfIsSkippedOver() {
        #expect(AutoClose.typed("}", before: "{", after: "}", hasSelection: false) == .skip)
        #expect(AutoClose.typed(")", before: "x", after: ")", hasSelection: false) == .skip)
        #expect(AutoClose.typed("]", before: "x", after: " ", hasSelection: false) == .none)
    }

    @Test func quotesPairOnlyAwayFromWords() {
        #expect(AutoClose.typed("\"", before: " ", after: nil, hasSelection: false) == .insert("\"\"", caretBack: 1))
        #expect(AutoClose.typed("`", before: "=", after: nil, hasSelection: false) == .insert("``", caretBack: 1))
        #expect(AutoClose.typed("'", before: "n", after: "t", hasSelection: false) == .none)
        #expect(AutoClose.typed("'", before: "n", after: nil, hasSelection: false) == .none)   // don'
        #expect(AutoClose.typed("\"", before: "\"", after: nil, hasSelection: false) == .none)  // the second of two
    }

    @Test func aQuoteTypedBeforeItsPartnerIsSkippedOver() {
        #expect(AutoClose.typed("\"", before: "a", after: "\"", hasSelection: false) == .skip)
        #expect(AutoClose.typed("`", before: nil, after: "`", hasSelection: false) == .skip)
    }

    @Test func anOpenerOverASelectionWrapsIt() {
        #expect(AutoClose.typed("(", before: " ", after: " ", hasSelection: true) == .wrap(open: "(", close: ")"))
        #expect(AutoClose.typed("\"", before: "x", after: "y", hasSelection: true) == .wrap(open: "\"", close: "\""))
        #expect(AutoClose.typed("a", before: " ", after: " ", hasSelection: true) == .none)
    }

    @Test func otherCharactersAreLeftAlone() {
        #expect(AutoClose.typed("a", before: " ", after: nil, hasSelection: false) == .none)
        #expect(AutoClose.typed(" ", before: "{", after: "}", hasSelection: false) == .none)
    }

    @Test func backspaceBetweenAPairRemovesBoth() {
        #expect(AutoClose.removesPair(before: "{", after: "}"))
        #expect(AutoClose.removesPair(before: "\"", after: "\""))
        #expect(AutoClose.removesPair(before: "(", after: ")"))
        #expect(!AutoClose.removesPair(before: "{", after: ")"))
        #expect(!AutoClose.removesPair(before: nil, after: "}"))
        #expect(!AutoClose.removesPair(before: "a", after: "a"))
    }

    @Test func newlineKeepsTheIndentationOfTheLine() {
        #expect(AutoClose.newline(lineBeforeCaret: "\tfoo()", after: nil, indentUnit: "\t") == .insert("\n\t", caretBack: 0))
        #expect(AutoClose.newline(lineBeforeCaret: "    x := 1", after: nil, indentUnit: "    ") == .insert("\n    ", caretBack: 0))
        #expect(AutoClose.newline(lineBeforeCaret: "x := 1", after: nil, indentUnit: "\t") == .insert("\n", caretBack: 0))
    }

    @Test func newlineAfterAnOpenerIndentsOneMore() {
        #expect(AutoClose.newline(lineBeforeCaret: "func main() {", after: nil, indentUnit: "\t") == .insert("\n\t", caretBack: 0))
        #expect(AutoClose.newline(lineBeforeCaret: "\tif x {  ", after: nil, indentUnit: "\t") == .insert("\n\t\t", caretBack: 0))
    }

    @Test func newlineBetweenABracketPairOpensABlock() {
        #expect(AutoClose.newline(lineBeforeCaret: "func main() {", after: "}", indentUnit: "\t") == .insert("\n\t\n", caretBack: 1))
        #expect(AutoClose.newline(lineBeforeCaret: "\tif x {", after: "}", indentUnit: "\t") == .insert("\n\t\t\n\t", caretBack: 2))
        #expect(AutoClose.newline(lineBeforeCaret: "f(", after: ")", indentUnit: "\t") == .insert("\n\t\n", caretBack: 1))
    }
}
