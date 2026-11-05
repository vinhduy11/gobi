import AppKit

/// Answers VoiceOver's line questions from the document's LineIndex (a binary search). TextKit's own answers lay out the
/// document to find a line (7.9 s for the insertion-point line in a 100k-line file), and VoiceOver asks on every selection
/// change.
final class EditorTextView: NSTextView {
    /// The document whose line index answers the questions. EditorView sets it once.
    weak var document: EditorDocument?
    /// The right-click menu, built by whoever hosts the editor (it needs the project, the tabs and gopls).
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) ?? super.menu(for: event) }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: selectedRange().location)
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard let document else { return super.accessibilityLine(for: index) }
        return document.lineIndex.position(at: index).line
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let document else { return super.accessibilityRange(forLine: line) }
        let clamped = min(max(line, 0), document.lineIndex.lineCount - 1)
        return NSRange(document.lineIndex.lineRange(clamped))
    }
}
