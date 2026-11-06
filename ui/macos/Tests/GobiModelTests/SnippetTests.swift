import Testing
@testable import GobiModel

@Suite("Snippets")
struct SnippetTests {
    @Test func plainTextHasNoStopsButTheEnd() {
        let snippet = Snippet.parse("Println")
        #expect(snippet.text == "Println")
        #expect(snippet.stops == [SnippetStop(location: 7, length: 0)])
    }

    @Test func placeholdersBecomeTheirDefaultTextAndStopsInOrder() {
        let snippet = Snippet.parse("helper(${1:a int}, ${2:b string})$0")
        #expect(snippet.text == "helper(a int, b string)")
        #expect(snippet.stops == [SnippetStop(location: 7, length: 5), SnippetStop(location: 14, length: 8), SnippetStop(location: 23, length: 0)])
    }

    @Test func stopsAreVisitedByNumberAndZeroIsLast() {
        let snippet = Snippet.parse("$2-$0-${1:x}")
        #expect(snippet.text == "--x")
        #expect(snippet.stops == [SnippetStop(location: 2, length: 1), SnippetStop(location: 0, length: 0), SnippetStop(location: 1, length: 0)])
    }

    @Test func aBareDollarNumberAndBracedNumberAreEmptyStops() {
        let snippet = Snippet.parse("f($1, ${2})")
        #expect(snippet.text == "f(, )")
        #expect(snippet.stops.map(\.location) == [2, 4, 5])
    }

    @Test func aMissingZeroStopIsAddedAtTheEnd() {
        let snippet = Snippet.parse("f(${1:x})")
        #expect(snippet.stops.last == SnippetStop(location: 4, length: 0))
        #expect(snippet.stops.count == 2)
    }

    @Test func choicesTakeTheFirstOption() {
        let snippet = Snippet.parse("${1|int,string|}")
        #expect(snippet.text == "int")
        #expect(snippet.stops.first == SnippetStop(location: 0, length: 3))
    }

    @Test func escapesGiveTheLiteralCharacter() {
        let snippet = Snippet.parse("a\\$b \\} \\\\ ${1:c\\}d}")
        #expect(snippet.text == "a$b } \\ c}d")
    }

    @Test func nestedPlaceholdersKeepTheInnerText() {
        let snippet = Snippet.parse("${1:a ${2:b}}")
        #expect(snippet.text == "a b")
        #expect(snippet.stops.first == SnippetStop(location: 0, length: 3))
        #expect(snippet.stops.count == 3)
    }

    @Test func aVariableUsesItsDefaultOrNothing() {
        #expect(Snippet.parse("$TM_FILENAME|${TM_X:def}").text == "|def")
    }

    @Test func lengthsCountUTF16Units() {
        let snippet = Snippet.parse("é${1:ü}")
        #expect(snippet.stops.first == SnippetStop(location: 1, length: 1))
    }

    @Test func aStrayDollarOrUnclosedBraceStaysText() {
        #expect(Snippet.parse("a$ b").text == "a$ b")
        #expect(Snippet.parse("${1:abc").text == "${1:abc")
    }
}

@Suite("Snippet session")
struct SnippetSessionTests {
    @Test func tabWalksTheStopsAndEndsAfterTheLast() {
        var session = SnippetSession(stops: [SnippetStop(location: 5, length: 2), SnippetStop(location: 9, length: 0), SnippetStop(location: 12, length: 0)], base: 100)
        #expect(session.current == SnippetStop(location: 105, length: 2))
        #expect(session.advance() == SnippetStop(location: 109, length: 0))
        #expect(session.advance() == SnippetStop(location: 112, length: 0))
        #expect(session.isFinished)
        #expect(session.advance() == nil)
    }

    @Test func typingInsideTheActivePlaceholderGrowsItAndMovesLaterStops() {
        var session = SnippetSession(stops: [SnippetStop(location: 2, length: 3), SnippetStop(location: 7, length: 1), SnippetStop(location: 10, length: 0)], base: 0)
        session.edited(at: 2, oldLength: 3, newLength: 1)
        #expect(session.current == SnippetStop(location: 2, length: 1))
        #expect(session.advance() == SnippetStop(location: 5, length: 1))
        session.edited(at: 5, oldLength: 1, newLength: 4)
        session.edited(at: 11, oldLength: 0, newLength: 1)
        #expect(session.current == SnippetStop(location: 5, length: 4))
        #expect(session.advance() == SnippetStop(location: 12, length: 0))
    }

    @Test func typingAtTheEndOfTheActiveStopGrowsItNotTheNextOne() {
        var session = SnippetSession(stops: [SnippetStop(location: 2, length: 1), SnippetStop(location: 3, length: 1)], base: 0)
        session.edited(at: 3, oldLength: 0, newLength: 2)
        #expect(session.current == SnippetStop(location: 2, length: 3))
        #expect(session.advance() == SnippetStop(location: 5, length: 1))
    }

    @Test func anEditBeforeEverythingShiftsAllStops() {
        var session = SnippetSession(stops: [SnippetStop(location: 4, length: 1), SnippetStop(location: 8, length: 0)], base: 0)
        session.edited(at: 0, oldLength: 0, newLength: 3)
        #expect(session.current == SnippetStop(location: 7, length: 1))
        #expect(session.advance() == SnippetStop(location: 11, length: 0))
    }

    @Test func theSpanCoversFirstToLastStop() {
        let session = SnippetSession(stops: [SnippetStop(location: 2, length: 1), SnippetStop(location: 6, length: 0)], base: 10)
        #expect(session.span == 12 ... 16)
    }
}
