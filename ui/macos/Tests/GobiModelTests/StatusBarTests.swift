import Testing
@testable import GobiModel

@Suite("Status bar and breadcrumb text")
struct StatusBarTests {
    @Test func caretIsShownOneBased() {
        #expect(StatusBar.caretText(line: 0, column: 0) == "Ln 1, Col 1")
        #expect(StatusBar.caretText(line: 27, column: 23) == "Ln 28, Col 24")
    }

    @Test func lineEndingIsTheFirstBreakInTheText() {
        #expect(LineEnding.detect(Array("a\nb".utf16)) == "LF")
        #expect(LineEnding.detect(Array("a\r\nb\n".utf16)) == "CRLF")
        #expect(LineEnding.detect(Array("a\rb".utf16)) == "CR")
    }

    @Test func aFileWithoutABreakDefaultsToLF() {
        #expect(LineEnding.detect(Array("abc".utf16)) == "LF")
        #expect(LineEnding.detect([]) == "LF")
    }

    @Test func breadcrumbStartsAtTheProjectFolderAndEndsAtTheFile() {
        #expect(Breadcrumb.segments(projectRoot: "/work/hello", file: "/work/hello/internal/server/server.go") == ["hello", "internal", "server", "server.go"])
        #expect(Breadcrumb.segments(projectRoot: "/work/hello", file: "/work/hello/main.go") == ["hello", "main.go"])
    }

    @Test func aFileOutsideTheProjectShowsItsOwnFolderAndName() {
        #expect(Breadcrumb.segments(projectRoot: "/work/hello", file: "/tmp/other/x.go") == ["other", "x.go"])
    }

    @Test func problemsTitleCarriesTheCountOnlyWhenThereAreProblems() {
        #expect(StatusBar.problemsTitle(count: 0) == "Problems")
        #expect(StatusBar.problemsTitle(count: 2) == "Problems 2")
    }

    @Test func goplsStateReadsAsAWord() {
        #expect(StatusBar.goplsText(connected: true, restricted: false) == "gopls ready")
        #expect(StatusBar.goplsText(connected: true, restricted: true) == "gopls ready · Restricted")
        #expect(StatusBar.goplsText(connected: false, restricted: false) == "gopls starting…")
    }

    @Test func aProblemShowsFileLineAndSource() {
        #expect(StatusBar.problemDetail(path: "internal/server/server.go", line: 27, source: "gopls") == "internal/server/server.go:28 · gopls")
        #expect(StatusBar.problemDetail(path: "main.go", line: 0, source: nil) == "main.go:1")
        #expect(StatusBar.problemDetail(path: "main.go", line: 4, source: "") == "main.go:5")
    }

    @Test func relativePathsDropTheProjectFolder() {
        #expect(StatusBar.relativePath(projectRoot: "/work/hello", file: "/work/hello/cmd/main.go") == "cmd/main.go")
        #expect(StatusBar.relativePath(projectRoot: "/work/hello", file: "/elsewhere/x.go") == "/elsewhere/x.go")
    }
}

@Suite("Terminal tab titles")
struct TerminalTitleTests {
    @Test func theTitleNamesTheShellAndTheFolder() {
        #expect(TerminalTitle.make(shellPath: "/bin/zsh", folder: "hello") == "zsh · hello")
        #expect(TerminalTitle.make(shellPath: "/opt/homebrew/bin/fish", folder: "scripts") == "fish · scripts")
    }

    @Test func aMissingShellFallsBackToTheWordShell() {
        #expect(TerminalTitle.make(shellPath: nil, folder: "hello") == "shell · hello")
        #expect(TerminalTitle.make(shellPath: "", folder: "hello") == "shell · hello")
    }

    @Test func twoTerminalsOfTheSameShellAndFolderAreNumbered() {
        #expect(TerminalTitle.numbered(["zsh · hello", "zsh · hello", "go test"]) == ["zsh · hello", "zsh · hello 2", "go test"])
        #expect(TerminalTitle.numbered(["a", "a", "a"]) == ["a", "a 2", "a 3"])
    }
}

@Suite("Shell quoting")
struct ShellQuoteTests {
    @Test func aPlainPathIsWrappedInSingleQuotes() {
        #expect(ShellQuote.single("/work/hello") == "'/work/hello'")
    }

    @Test func spacesAndShellCharactersStayInsideTheQuotes() {
        #expect(ShellQuote.single("/work/my project; rm -rf $HOME") == "'/work/my project; rm -rf $HOME'")
    }

    @Test func aSingleQuoteInThePathIsEscaped() {
        #expect(ShellQuote.single("/work/it's") == "'/work/it'\\''s'")
    }

    @Test func aNewlineInThePathIsRefusedByReturningNil() {
        #expect(ShellQuote.singleIfSafe("/work/a\nb") == nil)
        #expect(ShellQuote.singleIfSafe("/work/ab") == "'/work/ab'")
    }

    @Test func theGoModCommandsChangeFolderFirst() {
        #expect(ShellQuote.command("go mod tidy", inFolder: "/work/hello") == "cd '/work/hello' && go mod tidy")
        #expect(ShellQuote.command("go mod tidy", inFolder: "/work/a\nb") == nil)
    }
}
