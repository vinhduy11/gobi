import AppKit
import GobiModel

/// Tab stops of a snippet that was just inserted: the first placeholder is selected, Tab moves to the next one and ends on the
/// last. While a session runs it watches the text storage so typing in one placeholder moves the later ones; with no session
/// there is no observer and no cost per keystroke.
public final class SnippetTabs {
    private weak var textView: NSTextView?
    private var session: SnippetSession?
    private var observer: NSObjectProtocol?

    public var isActive: Bool { session != nil }
    /// The stop the caret is on, in text offsets.
    public var currentStop: (location: Int, length: Int)? { session?.current.map { ($0.location, $0.length) } }

    init(textView: NSTextView) { self.textView = textView }

    deinit { end() }

    /// `snippet` was inserted with its first character at `base`.
    func begin(_ snippet: Snippet, at base: Int) {
        end()
        let fresh = SnippetSession(stops: snippet.stops, base: base)
        guard let first = fresh.current else { return }
        textView?.setSelectedRange(NSRange(location: first.location, length: first.length))
        guard !fresh.isFinished, let storage = textView?.textStorage else { return }
        session = fresh
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let range = storage.editedRange
            self?.session?.edited(at: range.location, oldLength: range.length - storage.changeInLength, newLength: range.length)
        }
    }

    func end() {
        session = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Tab moves to the next stop; Esc ends the session. True when Tab was used here.
    func handle(command selector: Selector) -> Bool {
        guard var current = session else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { end(); return false }
        guard selector == #selector(NSResponder.insertTab(_:)), let textView else { return false }
        let caret = textView.selectedRange()
        guard let span = current.span, span.contains(caret.location), span.contains(caret.location + caret.length), let next = current.advance() else { end(); return false }
        textView.setSelectedRange(NSRange(location: next.location, length: next.length))
        if current.isFinished { end() } else { session = current }
        return true
    }
}
