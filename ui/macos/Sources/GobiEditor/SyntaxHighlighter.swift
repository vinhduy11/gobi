import AppKit
import GobiClient
import GobiModel

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

    /// The theme changed: paragraphs off screen are coloured when TextKit lays them out next; the ones already laid out in the viewport
    /// are coloured here, because invalidation alone does not make TextKit run the validator again for them.
    func recolourAll() {
        guard let layout = textView?.textLayoutManager else { return }
        layout.invalidateRenderingAttributes(for: layout.documentRange)
        if let viewport = layout.textViewportLayoutController.viewportRange {
            layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { [weak self] fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
                self?.colour(fragment, in: layout)
                return true
            }
        }
        textView?.needsDisplay = true
    }

    private func colour(_ fragment: NSTextLayoutFragment, in layout: NSTextLayoutManager) {
        let fragmentRange = fragment.rangeInElement
        let startOffset = layout.offset(from: layout.documentRange.location, to: fragmentRange.location)
        let line = document.lineIndex.position(at: startOffset).line
        layout.removeRenderingAttribute(.foregroundColor, for: fragmentRange)
        layout.addRenderingAttribute(.foregroundColor, value: ThemeColors.editorText, for: fragmentRange)
        guard document.lineIndex.lineRange(line).count <= EditorDocument.overlongLineLimit else { return }
        paragraphsColoured += 1
        for token in document.syntaxIndex.tokens(line: line) {
            guard let from = layout.location(fragmentRange.location, offsetBy: Int(token.start)),
                  let to = layout.location(from, offsetBy: Int(token.length)),
                  let range = NSTextRange(location: from, end: to) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: SyntaxTheme.color(for: token.kind), for: range)
        }
        // What gopls knows (types, functions, parameters...) goes over the lexer's colours.
        for token in document.semantic.tokens(line: line) {
            guard let from = layout.location(fragmentRange.location, offsetBy: Int(token.start)),
                  let to = layout.location(from, offsetBy: Int(token.length)),
                  let range = NSTextRange(location: from, end: to) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: SyntaxTheme.color(for: token.kind), for: range)
        }
    }

    /// Lines whose colours the last edit may have changed, recoloured once TextKit has finished processing that edit.
    private var pendingLines: Range<Int>?

    /// TextKit calls the validator for the caret's paragraph while it is still synchronising an edit (fixing the
    /// selection), and only afterwards shifts the stored rendering attributes by the edit's length, so the colours just
    /// written land `changeInLength` units too far (or vanish, for a replaced range) and the paragraph counts as validated.
    /// Remember the lines here; `recolourAfterEdit` repaints them once the edit is fully processed.
    private func refresh(edited: Range<Int>, changed: Range<Int>) {
        let lower = min(edited.lowerBound, changed.lowerBound, pendingLines?.lowerBound ?? .max)
        let upper = max(edited.upperBound, changed.upperBound, pendingLines?.upperBound ?? 0)
        pendingLines = lower ..< upper
    }

    /// Called by EditorContentStorage after an edit has been synchronised with the layout manager. Invalidates the
    /// changed lines (so paragraphs laid out later are validated again) and colours the ones already laid out in the
    /// viewport directly: invalidation alone does not make TextKit re-run the validator for a paragraph that stays laid out.
    func recolourAfterEdit() {
        guard let lines = pendingLines, let layout = textView?.textLayoutManager else { return }
        pendingLines = nil
        let lastLine = min(lines.upperBound, document.lineIndex.lineCount) - 1
        guard lastLine >= lines.lowerBound else { return }
        let documentStart = layout.documentRange.location
        let startOffset = document.lineIndex.lineRange(lines.lowerBound).lowerBound
        var endOffset = document.lineIndex.lineRange(lastLine).upperBound
        guard let from = layout.location(documentStart, offsetBy: startOffset),
              let to = layout.location(documentStart, offsetBy: endOffset),
              let range = NSTextRange(location: from, end: to) else { return }
        layout.invalidateRenderingAttributes(for: range)
        var line = lines.lowerBound
        if let viewport = layout.textViewportLayoutController.viewportRange {
            endOffset = min(endOffset, layout.offset(from: documentStart, to: viewport.endLocation))
            line = max(line, document.lineIndex.position(at: layout.offset(from: documentStart, to: viewport.location)).line)
        }
        // One lookup per line rather than enumerateTextLayoutFragments: enumerating here made TextKit log "enumerate
        // while editing" in the self-test. (A beginEditing/endEditing batch on the text
        // storage, which only the harness does, still logs it.)
        while line <= lastLine, document.lineIndex.lineRange(line).lowerBound <= endOffset {
            if let location = layout.location(documentStart, offsetBy: document.lineIndex.lineRange(line).lowerBound),
               let fragment = layout.textLayoutFragment(for: location) {
                colour(fragment, in: layout)
            }
            line += 1
        }
    }
}
