import AppKit
import GobiClient

/// Colours text lazily: TextKit 2 asks for rendering attributes only for the paragraphs it lays out, which are the
/// ones on screen, so the cost depends on the viewport and not on the file size. Rendering attributes never touch the
/// text storage, so highlighting does not count as an edit.
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private(set) var paragraphsColoured = 0

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
    }

    func install() {
        guard let layout = textView?.textLayoutManager else { return }
        layout.renderingAttributesValidator = { [weak self] layoutManager, fragment in
            self?.colour(fragment, in: layoutManager)
        }
        document.onSyntaxChanged = { [weak self] edited, changed in
            self?.refresh(edited: edited, changed: changed)
        }
    }

    private func colour(_ fragment: NSTextLayoutFragment, in layout: NSTextLayoutManager) {
        let fragmentRange = fragment.rangeInElement
        let startOffset = layout.offset(from: layout.documentRange.location, to: fragmentRange.location)
        let line = document.lineIndex.position(at: startOffset).line
        layout.removeRenderingAttribute(.foregroundColor, for: fragmentRange)
        paragraphsColoured += 1
        for token in document.syntaxIndex.tokens(line: line) {
            guard let from = layout.location(fragmentRange.location, offsetBy: Int(token.start)),
                  let to = layout.location(from, offsetBy: Int(token.length)),
                  let range = NSTextRange(location: from, end: to) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: SyntaxTheme.color(for: token.kind), for: range)
        }
    }

    /// Lines the edit did not touch but whose colours changed (below an opened comment, for example) are not laid
    /// out again by TextKit, so ask for their attributes to be recomputed.
    private func refresh(edited: Range<Int>, changed: Range<Int>) {
        guard changed.upperBound > edited.upperBound else { return }
        let below = edited.upperBound ..< changed.upperBound
        DispatchQueue.main.async { [weak self] in
            guard let self, let layout = self.textView?.textLayoutManager else { return }
            let startOffset = self.document.lineIndex.lineRange(below.lowerBound).lowerBound
            let endOffset = self.document.lineIndex.lineRange(below.upperBound - 1).upperBound
            guard let from = layout.location(layout.documentRange.location, offsetBy: startOffset),
                  let to = layout.location(layout.documentRange.location, offsetBy: endOffset),
                  let range = NSTextRange(location: from, end: to) else { return }
            layout.invalidateRenderingAttributes(for: range)
        }
    }
}
