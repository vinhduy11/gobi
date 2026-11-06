import Testing
@testable import GobiModel

@Suite("Save transform")
struct SaveTransformTests {
    @Test func trimsTrailingSpacesAndTabsOnEveryLine() {
        #expect(SaveTransform.apply("a  \nb\t\n  c\n", trimTrailingWhitespace: true, finalNewline: false) == "a\nb\n  c\n")
    }

    @Test func keepsCRLFBreaks() {
        #expect(SaveTransform.apply("a \r\nb\r\n", trimTrailingWhitespace: true, finalNewline: false) == "a\r\nb\r\n")
    }

    @Test func addsOneFinalNewlineAndCollapsesExtraBlankEnds() {
        #expect(SaveTransform.apply("a", trimTrailingWhitespace: false, finalNewline: true) == "a\n")
        #expect(SaveTransform.apply("a\n\n\n", trimTrailingWhitespace: false, finalNewline: true) == "a\n")
        #expect(SaveTransform.apply("", trimTrailingWhitespace: false, finalNewline: true) == "")
    }

    @Test func finalNewlineFollowsTheFilesLineEnding() {
        #expect(SaveTransform.apply("a\r\nb", trimTrailingWhitespace: false, finalNewline: true) == "a\r\nb\r\n")
    }

    @Test func doesNothingWhenBothAreOff() {
        #expect(SaveTransform.apply("a  \nb", trimTrailingWhitespace: false, finalNewline: false) == "a  \nb")
    }
}
