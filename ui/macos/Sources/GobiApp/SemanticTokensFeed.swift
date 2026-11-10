import AppKit
import GobiClient
import GobiEditor
import GobiModel

/// Asks gopls for the semantic tokens of a Go file and gives them to the editor: after the file connects, when gopls restarts, and
/// once typing pauses. Until an answer arrives the editor shows the lexer's colours; the lines being edited fall back to them
/// (see `SemanticOverlay`).
final class SemanticTokensFeed {
    private weak var pane: EditorPane?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// How many times an empty answer was asked again: gopls may still be loading the workspace.
    private var empties = 0
    static let typingDelay: TimeInterval = 0.4
    static let maxEmptyRetries = 6

    init(pane: EditorPane) {
        self.pane = pane
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: pane.textView, queue: .main) { [weak self] _ in
            self?.schedule(after: Self.typingDelay)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }

    func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let pane, pane.editorFile.language == "go", !pane.editorFile.isReadOnlyByLineLength, !pane.editorFile.hasOverlongLine,
              let client = pane.editorFile.client, let legend = client.semanticLegend else { return }
        let version = pane.editorFile.version
        client.semanticTokens(uri: pane.editorFile.uri) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, let pane = self.pane else { return }
                // The text moved on while gopls was working: ask again for the text as it is now.
                guard pane.editorFile.version == version else { self.schedule(after: 0.1); return }
                if data.isEmpty, self.empties < Self.maxEmptyRetries {
                    self.empties += 1
                    self.schedule(after: 1.5 * Double(self.empties))
                    return
                }
                self.empties = 0
                pane.editor.setSemanticTokens(SemanticTokens.decode(data, legend: legend), version: version)
            }
        }
    }
}
