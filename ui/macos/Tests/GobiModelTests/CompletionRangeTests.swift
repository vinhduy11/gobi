import Testing
@testable import GobiModel

@Suite("Completion range") struct CompletionRangeTests {
    @Test func withoutAServerEditTheTypedPrefixIsReplaced() {
        let range = CompletionRange.resolve(anchor: 10, caret: 13, serverEdit: nil)
        #expect(range.start == 10 && range.end == 13)
    }

    @Test func theServersRangeIsStretchedToWhatWasTypedSinceTheRequest() {
        // gopls answered when only "p" was typed (10..<11); the person has since typed "ac", so the caret is at 13.
        let range = CompletionRange.resolve(anchor: 10, caret: 13, serverEdit: (start: 10, end: 11))
        #expect(range.start == 10 && range.end == 13)
    }

    @Test func aServerRangeThatReachesPastTheCaretKeepsItsEnd() {
        // fmt.Pr|intln: the server replaces the whole identifier.
        let range = CompletionRange.resolve(anchor: 10, caret: 12, serverEdit: (start: 10, end: 17))
        #expect(range.start == 10 && range.end == 17)
    }

    @Test func aServerRangeThatIsAlreadyCurrentIsUnchanged() {
        let range = CompletionRange.resolve(anchor: 10, caret: 13, serverEdit: (start: 10, end: 13))
        #expect(range.start == 10 && range.end == 13)
    }

    @Test func anEmptyOrBackwardsServerRangeNeverGoesBelowItsStart() {
        let range = CompletionRange.resolve(anchor: 10, caret: 9, serverEdit: (start: 10, end: 8))
        #expect(range.start == 10 && range.end == 10)
    }
}
