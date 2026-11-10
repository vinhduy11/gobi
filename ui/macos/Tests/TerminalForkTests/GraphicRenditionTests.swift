import Testing
@testable import SwiftTerm

/// The underline flag of the cell at (col, 0) after feeding `text` to a terminal.
private func underlined(_ text: String, col: Int) -> Bool {
    let terminal = Terminal(delegate: Recorder(), options: TerminalOptions(cols: 40, rows: 4))
    terminal.feed(text: text)
    return terminal.getCharData(col: col, row: 0)?.attribute.style.contains(.underline) ?? false
}

@Suite("Select Graphic Rendition")
struct GraphicRenditionTests {
    @Test func aPrivateMarkerSequenceIsNotAnUnderline() {
        // CSI > 4 m is xterm's modifyOtherKeys reset, which Claude Code sends at start and exit. SGR it is not.
        #expect(!underlined("\u{1b}[>4mA", col: 0))
        #expect(!underlined("\u{1b}[>4;2mA", col: 0))
        #expect(!underlined("\u{1b}[?4mA", col: 0))
        #expect(!underlined("\u{1b}[=4mA", col: 0))
    }

    @Test func realUnderlineStillSwitchesOnAndOff() {
        #expect(underlined("\u{1b}[4mA", col: 0))
        #expect(!underlined("\u{1b}[4mA\u{1b}[24mB", col: 1))
        #expect(!underlined("\u{1b}[4mA\u{1b}[mB", col: 1))
    }

    @Test func aPrivateSequenceDoesNotUndoARealUnderline() {
        #expect(underlined("\u{1b}[4m\u{1b}[>4mA", col: 0))
    }
}

@Suite("SGR sub-parameters (colons)")
struct SubParameterTests {
    private func cell(_ text: String, col: Int = 0) -> Attribute {
        let terminal = Terminal(delegate: Recorder(), options: TerminalOptions(cols: 40, rows: 4))
        terminal.feed(text: text)
        return terminal.getCharData(col: col, row: 0)!.attribute
    }

    @Test func anUnderlineStyleIsNotReadAsASeparateAttribute() {
        // 4:3 is a curly underline. It was read as 4;3, which also switched italic on and left it on.
        let curly = cell("\u{1b}[4:3mA")
        #expect(curly.style.contains(.underline) && !curly.style.contains(.italic))
    }

    @Test func underlineStyleZeroSwitchesTheUnderlineOff() {
        #expect(cell("\u{1b}[4:3mA\u{1b}[4:0mB", col: 1).style.isEmpty)
        #expect(cell("\u{1b}[4:3mA\u{1b}[24mB", col: 1).style.isEmpty)
        #expect(cell("\u{1b}[4:1mA\u{1b}[4:2mB", col: 1).style.contains(.underline))
    }

    @Test func colonColoursEqualTheSemicolonOnes() {
        #expect(cell("\u{1b}[38:2::255:0:10mA") == cell("\u{1b}[38;2;255;0;10mA"))   // with the colour space left empty
        #expect(cell("\u{1b}[38:2:255:0:10mA") == cell("\u{1b}[38;2;255;0;10mA"))
        #expect(cell("\u{1b}[48:2::1:2:3mA") == cell("\u{1b}[48;2;1;2;3mA"))
        #expect(cell("\u{1b}[38:5:200mA") == cell("\u{1b}[38;5;200mA"))
    }

    @Test func colonAndSemicolonGroupsMixInOneSequence() {
        #expect(cell("\u{1b}[1;4:3;38:2::9:8:7;48;5;20mA").bg == cell("\u{1b}[48;5;20mA").bg)
        let mixed = cell("\u{1b}[1;4:3;38:2::9:8:7;48;5;20mA")
        #expect(mixed.style.contains(.bold) && mixed.style.contains(.underline) && !mixed.style.contains(.italic))
        #expect(mixed.fg == cell("\u{1b}[38;2;9;8;7mA").fg)
    }

    @Test func theUnderlineColourIsAcceptedAndIgnored() {
        #expect(cell("\u{1b}[58:2::1:2:3m\u{1b}[4mA") == cell("\u{1b}[4mA"))
        #expect(cell("\u{1b}[58;2;1;2;3m\u{1b}[4mA") == cell("\u{1b}[4mA"))
    }
}
