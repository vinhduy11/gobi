import AppKit
import Testing
@testable import SwiftTerm

private final class Sink: TerminalViewDelegate {
    var sent = ""
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += String(decoding: data, as: UTF8.self) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Copy and paste as the Edit menu drives them: `copy:` / `paste:` sent to the terminal that has the keyboard.
@MainActor @Suite("Terminal clipboard", .serialized)
struct ClipboardTests {
    private func setup() -> (TerminalView, Sink, NSWindow) {
        _ = NSApplication.shared
        let sink = Sink()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.terminalDelegate = sink
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(view))
        return (view, sink, window)
    }

    @Test func pasteActionSendsPasteboardText() {
        let (view, sink, window) = setup()
        _ = window
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo hi", forType: .string)
        let handled = NSApp.sendAction(#selector(NSText.paste(_:)), to: view, from: nil)
        #expect(handled)
        #expect(sink.sent == "echo hi")
    }

    @Test func copyActionPutsSelectionOnPasteboard() {
        let (view, _, window) = setup()
        _ = window
        view.feed(text: "hello world\r\n")
        view.selection.select(row: 0)
        NSPasteboard.general.clearContents()
        let handled = NSApp.sendAction(#selector(NSText.copy(_:)), to: view, from: nil)
        let got = NSPasteboard.general.string(forType: .string)
        #expect(handled)
        #expect(got?.contains("hello world") == true)
    }

    @Test func menuItemsValidateAgainstTheTerminal() {
        let (view, _, window) = setup()
        _ = window
        view.feed(text: "hello\r\n")
        view.selectAll()
        let menu = NSMenu(title: "Edit")
        let copy = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        copy.isEnabled = view.validateUserInterfaceItem(copy); paste.isEnabled = view.validateUserInterfaceItem(paste)
        #expect(copy.isEnabled)
        #expect(paste.isEnabled)
    }
}
