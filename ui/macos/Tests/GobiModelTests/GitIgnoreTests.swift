import Testing
@testable import GobiModel

@Suite("Adding to .gitignore")
struct GitIgnoreTests {
    @Test func anUntrackedPathIsAnchoredAtTheRepositoryRoot() {
        #expect(GitIgnore.appending(["docs/"], to: "") == "/docs/\n")
        #expect(GitIgnore.appending(["notes.txt"], to: "bin/\n") == "bin/\n/notes.txt\n")
    }

    @Test func aMissingFinalNewlineIsAddedBeforeTheNewLine() {
        #expect(GitIgnore.appending(["a.log"], to: "bin/") == "bin/\n/a.log\n")
    }

    @Test func severalPathsAreAddedInOrderOnceEach() {
        #expect(GitIgnore.appending(["a", "b/", "a"], to: "") == "/a\n/b/\n")
    }

    @Test func whatIsAlreadyListedIsNotAddedAgain() {
        #expect(GitIgnore.appending(["docs/"], to: "/docs/\n") == nil)
        #expect(GitIgnore.appending(["docs/"], to: "docs/\n") == nil)
        #expect(GitIgnore.appending(["docs/"], to: "/docs\n") == nil)
        #expect(GitIgnore.appending(["a", "docs/"], to: "/docs/\n") == "/docs/\n/a\n")
    }

    @Test func nothingToAddGivesNil() {
        #expect(GitIgnore.appending([], to: "x\n") == nil)
        #expect(GitIgnore.appending([""], to: "x\n") == nil)
    }

    @Test func spacesAndPatternCharactersAreEscaped() {
        #expect(GitIgnore.appending(["my notes.txt"], to: "") == "/my\\ notes.txt\n")
        #expect(GitIgnore.appending(["#draft", "!keep", "a[1].txt"], to: "") == "/\\#draft\n/\\!keep\n/a\\[1\\].txt\n")
    }
}
