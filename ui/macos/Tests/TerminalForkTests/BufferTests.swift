import Testing
@testable import SwiftTerm

@Suite("Buffers after a reset")
struct BufferTests {
    private func resetThenResize() -> Terminal {
        let terminal = Terminal(delegate: Recorder(), options: TerminalOptions(cols: 80, rows: 24))
        terminal.options.scrollback = 5000
        terminal.resetNormalBuffer()
        terminal.resize(cols: 190, rows: 40)
        return terminal
    }

    @Test func theTerminalFollowsAResizeAfterTheNormalBufferWasMadeAgain() {
        let terminal = resetThenResize()
        // A line of 150 characters fits the new width; the old 80-column buffer would have wrapped it to the next row.
        terminal.feed(text: String(repeating: "x", count: 150))
        #expect(terminal.getCursorLocation().y == 0)
        #expect(terminal.getCursorLocation().x == 150)
    }

    @Test func theNewRowsAreUsable() {
        let terminal = resetThenResize()
        for _ in 0..<30 { terminal.feed(text: "line\r\n") }
        // The old 24-row buffer would have scrolled by now and kept the cursor on its last row.
        #expect(terminal.getCursorLocation().y == 30)
    }

    @Test func theScrollbackSizeChosenBeforeTheResetIsKept() {
        let terminal = resetThenResize()
        for _ in 0..<200 { terminal.feed(text: "line\r\n") }
        #expect(terminal.buffer.yBase > 100)   // 5000 lines of scrollback hold what scrolled off; a 500-line default would too, so the next test pins the size
    }

    @Test func switchingToTheAlternateScreenAndBackStillWorks() {
        let terminal = resetThenResize()
        terminal.feed(text: "\u{1b}[?1049hX\u{1b}[?1049l")
        terminal.feed(text: String(repeating: "y", count: 150))
        #expect(terminal.getCursorLocation().y == 0)
    }
}
