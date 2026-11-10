import Testing
@testable import SwiftTerm

/// Collects what the terminal sends back to the program (key presses and mouse reports).
final class Recorder: TerminalDelegate {
    var sent: [String] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(String(decoding: data, as: UTF8.self)) }
}

private func terminal(mode: String = "\u{1b}[?1003h\u{1b}[?1006h") -> (Terminal, Recorder) {
    let recorder = Recorder()
    let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 80, rows: 24))
    terminal.feed(text: mode)
    return (terminal, recorder)
}

@Suite("Mouse reports (SGR)")
struct MouseReportTests {
    /// What the view sends for a move with no button held: the "release" button number plus the motion flag.
    private func hover(_ terminal: Terminal) {
        let flags = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
        terminal.sendMotion(buttonFlags: flags, x: 9, y: 4, pixelX: 0, pixelY: 0)
    }

    @Test func aMoveWithNoButtonIsReportedAsAMoveNotAsAReleaseOfTheLeftButton() {
        let (terminal, recorder) = terminal()
        hover(terminal)
        #expect(recorder.sent == ["\u{1b}[<35;10;5M"])   // xterm: button 3 (none) + 32 (motion), a press-type report
    }

    @Test func aDragStillReportsTheHeldButtonWithTheMotionFlag() {
        let (terminal, recorder) = terminal()
        let flags = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
        terminal.sendMotion(buttonFlags: flags, x: 9, y: 4, pixelX: 0, pixelY: 0)
        #expect(recorder.sent == ["\u{1b}[<32;10;5M"])
    }

    @Test func aRealReleaseIsStillAReleaseAndAPressAndTheWheelAreUnchanged() {
        let (terminal, recorder) = terminal()
        terminal.sendEvent(buttonFlags: terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false), x: 9, y: 4)
        terminal.sendEvent(buttonFlags: terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false), x: 9, y: 4)
        terminal.sendEvent(buttonFlags: terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false), x: 9, y: 4)
        #expect(recorder.sent == ["\u{1b}[<0;10;5M", "\u{1b}[<0;10;5m", "\u{1b}[<64;10;5M"])
    }

    @Test func aModifiedHoverKeepsItsModifiers() {
        let (terminal, recorder) = terminal()
        let flags = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: true)
        terminal.sendMotion(buttonFlags: flags, x: 0, y: 0, pixelX: 0, pixelY: 0)
        #expect(recorder.sent == ["\u{1b}[<51;1;1M"])   // 3 + 32 + 16 (control)
    }
}

@Suite("The wheel reaches full-screen programs")
struct WheelTests {
    @Test func aProgramThatAskedForTheMouseGetsWheelReports() {
        let (terminal, recorder) = terminal()
        #expect(terminal.sendWheel(up: true, steps: 2, x: 9, y: 4))
        #expect(terminal.sendWheel(up: false, steps: 1, x: 9, y: 4))
        #expect(recorder.sent == ["\u{1b}[<64;10;5M", "\u{1b}[<64;10;5M", "\u{1b}[<65;10;5M"])
    }

    @Test func theAlternateScreenWithoutTheMouseGetsArrowKeys() {
        let (terminal, recorder) = terminal(mode: "\u{1b}[?1049h")
        #expect(terminal.sendWheel(up: true, steps: 2, x: 0, y: 0))
        #expect(terminal.sendWheel(up: false, steps: 1, x: 0, y: 0))
        #expect(recorder.sent == ["\u{1b}[A", "\u{1b}[A", "\u{1b}[B"])
    }

    @Test func applicationCursorModeSendsTheApplicationArrowKeys() {
        let (terminal, recorder) = terminal(mode: "\u{1b}[?1049h\u{1b}[?1h")
        terminal.sendWheel(up: true, steps: 1, x: 0, y: 0)
        #expect(recorder.sent == ["\u{1b}OA"])
    }

    @Test func theNormalScreenWithoutTheMouseIsLeftToTheScrollback() {
        let (terminal, recorder) = terminal(mode: "")
        #expect(!terminal.sendWheel(up: true, steps: 3, x: 0, y: 0))
        #expect(recorder.sent.isEmpty)
    }
}
