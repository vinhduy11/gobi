import Testing
@testable import GobiModel

@Suite("Terminal output filter")
struct TerminalOutputFilterTests {
    private func run(_ chunks: [String]) -> String {
        var filter = TerminalOutputFilter()
        return chunks.map { String(decoding: filter.filter(Array($0.utf8)), as: UTF8.self) }.joined()
    }

    @Test func dropsTheModifyOtherKeysResetThatSwiftTermReadsAsUnderline() {
        #expect(run(["a\u{1b}[>4mb"]) == "ab")
        #expect(run(["\u{1b}[>4;2mx"]) == "x")
    }

    @Test func keepsRealColourAndUnderlineSequences() {
        let text = "\u{1b}[4munder\u{1b}[24m \u{1b}[38;2;1;2;3mc\u{1b}[0m \u{1b}[?25h"
        #expect(run([text]) == text)
    }

    @Test func dropsASequenceSplitAcrossChunks() {
        #expect(run(["a\u{1b}[", ">4", "mb"]) == "ab")
        #expect(run(["a\u{1b}"]) == "a")   // the lone ESC waits for the next chunk
    }

    @Test func releasesAHeldPrefixThatTurnsOutToBeSomethingElse() {
        #expect(run(["a\u{1b}[", "31mb"]) == "a\u{1b}[31mb")
    }
}
