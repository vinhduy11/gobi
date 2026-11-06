import Testing
@testable import GobiModel

@Suite("Terminal shell choice and find")
struct TerminalExtrasTests {
    @Test func theMenuMarksTheLoginShellAndTheChoice() {
        let items = ShellChoice.menuItems(shells: ["/bin/zsh", "/bin/bash", "/bin/sh"], login: "/bin/zsh", selected: "")
        #expect(items.map(\.title) == ["zsh (login shell)", "bash", "sh"])
        #expect(items.map(\.isChecked) == [true, false, false])
        let bash = ShellChoice.menuItems(shells: ["/bin/zsh", "/bin/bash"], login: "/bin/zsh", selected: "/bin/bash")
        #expect(bash.map(\.isChecked) == [false, true])
        #expect(bash.map(\.path) == ["/bin/zsh", "/bin/bash"])
    }

    @Test func aChoiceThatIsNoLongerListedFallsBackToTheLoginShell() {
        #expect(ShellChoice.effective(selected: "/usr/local/bin/fish", shells: ["/bin/zsh"], login: "/bin/zsh") == "")
        #expect(ShellChoice.effective(selected: "/bin/bash", shells: ["/bin/zsh", "/bin/bash"], login: "/bin/zsh") == "/bin/bash")
        #expect(ShellChoice.effective(selected: "", shells: ["/bin/zsh"], login: "/bin/zsh") == "")
    }

    @Test func findCountsMatchesIgnoringCaseAndReportsTheirLines() {
        let text = "server listening\nrequest GET /\nLISTEN again\nlast line"
        let found = TerminalFind.matches(in: text, query: "listen")
        #expect(found.map(\.line) == [0, 2])
        #expect(TerminalFind.matches(in: text, query: "").isEmpty)
        #expect(TerminalFind.matches(in: text, query: "zzz").isEmpty)
        #expect(TerminalFind.label(index: 1, count: 2) == "2 of 2")
        #expect(TerminalFind.label(index: 0, count: 0) == "No matches")
    }

    @Test func findStepsAroundTheEnds() {
        #expect(TerminalFind.next(from: 1, count: 3, forward: true) == 2)
        #expect(TerminalFind.next(from: 2, count: 3, forward: true) == 0)
        #expect(TerminalFind.next(from: 0, count: 3, forward: false) == 2)
        #expect(TerminalFind.next(from: 0, count: 0, forward: true) == 0)
    }

    @Test func aScrollPositionPutsALineInView() {
        // 100 lines in the buffer, 20 visible: line 50 sits at 50/80 of the scroll range; the ends clamp.
        #expect(TerminalFind.scrollPosition(line: 50, totalLines: 100, visibleLines: 20) == 50.0 / 80.0)
        #expect(TerminalFind.scrollPosition(line: 99, totalLines: 100, visibleLines: 20) == 1.0)
        #expect(TerminalFind.scrollPosition(line: 0, totalLines: 100, visibleLines: 20) == 0.0)
        #expect(TerminalFind.scrollPosition(line: 5, totalLines: 10, visibleLines: 20) == 0.0)
    }
}
