import AppKit
import GobiEditor

/// A window holding one editor pane: used for a single file opened on its own and by the self-test.
final class EditorWindowController: NSWindowController {
    let pane: EditorPane
    var editor: EditorView { pane.editor }

    init(fileURL: URL, text: String) {
        pane = EditorPane(fileURL: fileURL, text: text)
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false))
        window?.contentView = pane.view
        window?.title = fileURL.lastPathComponent
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func connect() { pane.connect() }

    func runSelfTest(timeout: TimeInterval, snapshotPath: String?, finish: @escaping (Bool) -> Void) {
        pane.runSelfTest(timeout: timeout, snapshotPath: snapshotPath, finish: finish)
    }
}
