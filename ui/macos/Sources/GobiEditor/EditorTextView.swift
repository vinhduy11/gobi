import AppKit
import GobiModel

/// Answers VoiceOver's line questions from the document's LineIndex (a binary search). TextKit's own answers lay out the
/// document to find a line (7.9 s for the insertion-point line in a 100k-line file), and VoiceOver asks on every selection
/// change.
final class EditorTextView: NSTextView {
    /// The document whose line index answers the questions. EditorView sets it once.
    weak var document: EditorDocument?
    /// The right-click menu, built by whoever hosts the editor (it needs the project, the tabs and gopls).
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    /// What Tab inserts (a tab, or spaces for a non-Go file when Settings says Spaces).
    var indentUnit = "\t"

    override func insertTab(_ sender: Any?) {
        if indentUnit == "\t" { super.insertTab(sender) } else { insertText(indentUnit, replacementRange: selectedRange()) }
    }

    /// The line (as a character range) the debugger is paused on; it gets a highlighted background.
    var debugLineRange: NSRange? { didSet { if debugLineRange != oldValue { needsDisplay = true } } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let range = debugLineRange, let layout = textLayoutManager else { return }
        let start = layout.documentRange.location
        guard let from = layout.location(start, offsetBy: range.location), let to = layout.location(from, offsetBy: max(1, range.length)), let textRange = NSTextRange(location: from, end: to) else { return }
        var top = CGFloat.greatestFiniteMagnitude, bottom = CGFloat.leastNormalMagnitude
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            top = min(top, frame.minY); bottom = max(bottom, frame.maxY); return true
        }
        guard top < bottom else { return }
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        NSRect(x: 0, y: top + textContainerOrigin.y, width: bounds.width, height: bottom - top).fill()
    }

    /// Column of the vertical ruler; 0 draws none.
    var rulerColumn = 0 { didSet { if rulerColumn != oldValue { needsDisplay = true } } }

    /// Faint marks for tabs, trailing spaces and line ends, drawn over the visible lines only (they are not part of the text).
    var showInvisibles = false { didSet { if showInvisibles != oldValue { needsDisplay = true } } }

    /// Debugger values drawn after the end of their lines (1-based line numbers); not part of the text.
    var inlineValues: [Int: String] = [:] { didSet { needsDisplay = true } }

    private func drawInlineValues(in dirtyRect: NSRect) {
        guard !inlineValues.isEmpty, let layout = textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange, let document else { return }
        let origin = textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: (font?.pointSize ?? 13) - 1), toHaveTrait: .italicFontMask), .foregroundColor: NSColor.tertiaryLabelColor]
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > dirtyRect.maxY { return false }
            if frame.maxY < dirtyRect.minY { return true }
            let offset = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
            let line = document.lineIndex.position(at: offset).line + 1
            guard let text = inlineValues[line], let last = fragment.textLineFragments.last else { return true }
            let size = (text as NSString).size(withAttributes: attributes)
            let x = frame.minX + last.typographicBounds.maxX + 24
            (text as NSString).draw(at: NSPoint(x: x, y: frame.maxY - size.height - 1), withAttributes: attributes)
            return true
        }
    }

    // MARK: code lens

    /// The lens of each declaration line (1-based), drawn grey after the end of the line; not part of the text, so numbering,
    /// selection and the line index are untouched. Only drawn while `codeLensVersion` is the document's version.
    var codeLenses: [Int: [LensSegment]] = [:] { didSet { needsDisplay = true } }
    var codeLensVersion = 0 { didSet { needsDisplay = true } }
    var codeLensEnabled = true { didSet { if codeLensEnabled != oldValue { needsDisplay = true } } }
    var onLensClick: ((Int, LensAction) -> Void)?
    private static let lensSeparator = " · "

    private var lensAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: max(9, (font?.pointSize ?? 13) - 2)), .foregroundColor: NSColor.tertiaryLabelColor]
    }

    /// Calls `body` for each visible declaration line that has a lens, with the clickable rectangle of each segment (view coordinates).
    private func forEachLens(in rect: NSRect, _ body: (_ line: Int, _ segments: [(segment: LensSegment, rect: NSRect)]) -> Void) {
        guard codeLensEnabled, !codeLenses.isEmpty, let document, codeLensVersion == document.version,
              let layout = textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let origin = textContainerOrigin
        let attributes = lensAttributes
        let separatorWidth = (Self.lensSeparator as NSString).size(withAttributes: attributes).width
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > rect.maxY { return false }
            if frame.maxY < rect.minY { return true }
            let offset = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
            let line = document.lineIndex.position(at: offset).line + 1
            guard let segments = codeLenses[line], !segments.isEmpty, inlineValues[line] == nil, let last = fragment.textLineFragments.last else { return true }
            var left = frame.minX + last.typographicBounds.maxX + 24
            var placed: [(segment: LensSegment, rect: NSRect)] = []
            for segment in segments {
                let size = (segment.text as NSString).size(withAttributes: attributes)
                placed.append((segment, NSRect(x: left, y: frame.maxY - size.height - 1, width: size.width, height: size.height)))
                left += size.width + separatorWidth
            }
            body(line, placed)
            return true
        }
    }

    private func drawCodeLenses(in dirtyRect: NSRect) {
        let attributes = lensAttributes
        let separatorWidth = (Self.lensSeparator as NSString).size(withAttributes: attributes).width
        forEachLens(in: dirtyRect) { _, placed in
            for (index, placement) in placed.enumerated() {
                (placement.segment.text as NSString).draw(at: placement.rect.origin, withAttributes: attributes)
                if index > 0 { (Self.lensSeparator as NSString).draw(at: NSPoint(x: placement.rect.minX - separatorWidth, y: placement.rect.minY), withAttributes: attributes) }
            }
        }
    }

    /// The lens segment under a point of this view, if any.
    func lensSegment(at point: NSPoint) -> (line: Int, action: LensAction)? {
        var hit: (line: Int, action: LensAction)?
        forEachLens(in: NSRect(x: 0, y: point.y, width: 1, height: 1)) { line, placed in
            if let placement = placed.first(where: { $0.rect.insetBy(dx: -2, dy: 0).contains(point) }) { hit = (line, placement.segment.action) }
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = lensSegment(at: convert(event.locationInWindow, from: nil)), let onLensClick {
            onLensClick(hit.line, hit.action)
            return
        }
        super.mouseDown(with: event)
    }

    private func drawInvisibles(in dirtyRect: NSRect) {
        guard let layout = textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange, let font else { return }
        let origin = textContainerOrigin
        let text = string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let documentStart = layout.documentRange.location
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > dirtyRect.maxY { return false }
            if frame.maxY < dirtyRect.minY { return true }
            let start = layout.offset(from: documentStart, to: fragment.rangeInElement.location)
            let length = layout.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
            let paragraph = text.substring(with: NSRange(location: start, length: min(length, text.length - start)))
            for mark in InvisibleMarks.find(in: paragraph) {
                guard let location = layout.location(documentStart, offsetBy: start + mark.offset),
                      let end = layout.location(location, offsetBy: 1), let range = NSTextRange(location: location, end: end) else { continue }
                layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
                    let size = (mark.symbol as NSString).size(withAttributes: attributes)
                    (mark.symbol as NSString).draw(at: NSPoint(x: segment.minX + origin.x, y: segment.maxY + origin.y - size.height + abs(font.descender)), withAttributes: attributes)
                    return false
                }
            }
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showInvisibles { drawInvisibles(in: dirtyRect) }
        drawInlineValues(in: dirtyRect)
        drawCodeLenses(in: dirtyRect)
        guard rulerColumn > 0, let font else { return }
        let advance = font.maximumAdvancement.width
        let x = (textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5) + CGFloat(rulerColumn) * advance).rounded() + 0.5
        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { return }
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    /// Completion for this editor; EditorView creates it.
    var completion: CompletionController?
    var snippets: SnippetTabs?
    var signature: SignatureController?
    var hover: HoverController?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if !codeLenses.isEmpty, lensSegment(at: point) != nil { NSCursor.pointingHand.set(); hover?.hide(); return }
        hover?.pointerMoved(to: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover?.hide()
    }

    override func scrollWheel(with event: NSEvent) {
        hover?.hide()
        super.scrollWheel(with: event)
    }

    /// Text starts a few points inside the view. Revealing a caret near the left edge made AppKit scroll sideways by a small amount
    /// (14 pt seen), which cut the first character off every line; a small sideways offset is taken back to the left edge.
    static let leftSnapDistance: CGFloat = 48

    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let x = clip.bounds.origin.x
        if x > 0, x < Self.leftSnapDistance {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        hover?.hide()
        super.insertText(insertString, replacementRange: replacementRange)
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if let typed {
            completion?.typed(typed)
            signature?.typed(typed)
        }
    }

    override func doCommand(by selector: Selector) {
        if completion?.handle(command: selector) == true { return }
        if signature?.handle(command: selector) == true { return }
        if snippets?.handle(command: selector) == true { return }
        super.doCommand(by: selector)
        if selector == #selector(NSResponder.deleteBackward(_:)) || selector == #selector(NSResponder.deleteForward(_:)) { completion?.deleted() }
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space asks for completions without typing.
        if event.keyCode == 49, event.modifierFlags.intersection([.control, .command, .option]) == .control {
            completion?.trigger()
            return
        }
        // ⇧⌘Space asks for the signature of the call around the caret.
        if event.keyCode == 49, event.modifierFlags.intersection([.control, .command, .option, .shift]) == [.command, .shift] {
            signature?.trigger()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completion?.dismiss()
        signature?.dismiss()
        return super.resignFirstResponder()
    }

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
