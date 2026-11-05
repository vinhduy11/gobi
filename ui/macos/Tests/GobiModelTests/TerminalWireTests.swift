import Testing
@testable import GobiModel

@Suite("Terminal channel messages")
struct TerminalWireTests {
    // The same bytes core/internal/daemon/terminal.go reads and writes.
    @Test func inputMatchesTheGoLayout() {
        #expect(TerminalWire.input(Array("ls\n".utf8)) == [0x08, 0x01, 0x12, 0x03, 0x6c, 0x73, 0x0a])
    }

    @Test func resizeMatchesTheGoLayout() {
        #expect(TerminalWire.resize(columns: 100, rows: 30) == [0x08, 0x02, 0x18, 0x64, 0x20, 0x1e])
    }

    @Test func outputIsParsedFromAServerMessage() throws {
        #expect(try TerminalWire.parse([0x08, 0x01, 0x12, 0x02, 0x68, 0x69]) == .output(Array("hi".utf8)))
    }

    @Test func exitCarriesTheCodeAndAnyText() throws {
        #expect(try TerminalWire.parse([0x08, 0x03, 0x28, 0x04]) == .exit(code: 4, message: ""))
        var withText: [UInt8] = [0x08, 0x03, 0x12, 0x02, 0x6e, 0x6f, 0x28, 0x7f]
        #expect(try TerminalWire.parse(withText) == .exit(code: 127, message: "no"))
        withText.removeAll()
    }

    @Test func anUnknownKindIsIgnoredNotAnError() throws {
        #expect(try TerminalWire.parse([0x08, 0x09]) == .ignored)
    }

    @Test func damagedInputThrows() {
        #expect(throws: WireError.self) { try TerminalWire.parse([0x12, 0x09, 0x61]) }
    }
}
