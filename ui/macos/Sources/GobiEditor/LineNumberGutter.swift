import AppKit
import GobiClient
import GobiModel

/// A line-number gutter that sits beside the scroll view. It draws only the paragraphs in the viewport, numbering them
/// from the document's line index, so wrapped lines get one number and the cost does not depend on the file size.
/// (An NSRulerView was tried first: on this macOS the scroll view did not move its clip view aside, so the ruler
/// covered the first characters of every line.)
final class LineNumberGutter: NSView {
    static let width: CGFloat = 52

    private let document: EditorDocument
    private weak var textView: NSTextView?
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ThemeColors.editorSecondaryText]
    }
    /// Lines (1-based) that carry a breakpoint, drawn as red dots; a click on the gutter asks to toggle one.
    var breakpoints: Set<Int> = [] { didSet { needsDisplay = true } }
    var conditional: Set<Int> = [] { didSet { needsDisplay = true } }
    var onToggleBreakpoint: ((Int) -> Void)?
    /// Lines with a Run button (a green triangle right of the breakpoint dot) and what a click on it does.
    var runnable: Set<Int> = [] { didSet { needsDisplay = true } }
    var onRunLine: ((Int) -> Void)?
    private static let runButtonRange: ClosedRange<CGFloat> = 18 ... 32
    /// What changed since the last commit, by 1-based line (added: green bar, modified: blue bar, deleted: red mark).
    var gitAdded: Set<Int> = [] { didSet { needsDisplay = true } }
    var gitModified: Set<Int> = [] { didSet { needsDisplay = true } }
    var gitDeletedAfter: Set<Int> = [] { didSet { needsDisplay = true } }
    private(set) var drawCount = 0
    private(set) var lastDrawMilliseconds = 0.0

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: NSTextView, document: EditorDocument) {
        self.document = document
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)

        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(contentChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(contentChanged), name: NSText.didChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layout = textView.textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textView.textContainerOrigin
        var hit: Int?
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            let top = convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y
            if point.y < top { return false }
            if point.y < top + frame.height {
                let offset = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
                hit = document.lineIndex.position(at: offset).line + 1
                return false
            }
            return true
        }
        guard let hit else { return }
        if runnable.contains(hit), Self.runButtonRange.contains(point.x) { onRunLine?(hit) } else { onToggleBreakpoint?(hit) }
    }

    private func drawGitMark(for line: Int, top: CGFloat, height: CGFloat) {
        if gitAdded.contains(line) || gitModified.contains(line) {
            (gitAdded.contains(line) ? NSColor.systemGreen : NSColor.systemBlue).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 6, y: top + 1, width: 3, height: height - 2), xRadius: 1.5, yRadius: 1.5).fill()
        }
        // Removed lines: a small red wedge at the top of the line that follows them (the first line when they were at the top).
        if gitDeletedAfter.contains(line - 1) {
            NSColor.systemRed.setFill()
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: bounds.maxX - 8, y: top - 3))
            wedge.line(to: NSPoint(x: bounds.maxX - 1, y: top))
            wedge.line(to: NSPoint(x: bounds.maxX - 8, y: top + 3))
            wedge.close()
            wedge.fill()
        }
    }

    @objc private func contentChanged(_ notification: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            drawCount += 1
            lastDrawMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        }
        ThemeColors.gutterBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView, let layout = textView.textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let origin = textView.textContainerOrigin
        let visibleBottom = textView.visibleRect.maxY
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visibleBottom { return false }
            let offset = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
            let lineNumber = document.lineIndex.position(at: offset).line + 1
            drawGitMark(for: lineNumber, top: convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y, height: frame.height)
            let number = "\(lineNumber)" as NSString
            let size = number.size(withAttributes: attributes)
            let top = convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y
            // Put the number's baseline on the baseline of the paragraph's first text line.
            if let line = fragment.textLineFragments.first {
                let baseline = top + line.typographicBounds.minY + line.glyphOrigin.y
                number.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: baseline - (attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 11)).ascender), withAttributes: attributes)
                if runnable.contains(lineNumber) {
                    let middle = top + line.typographicBounds.minY + line.typographicBounds.height / 2
                    NSColor.systemGreen.setFill()
                    let triangle = NSBezierPath()
                    triangle.move(to: NSPoint(x: 20, y: middle - 5))
                    triangle.line(to: NSPoint(x: 30, y: middle))
                    triangle.line(to: NSPoint(x: 20, y: middle + 5))
                    triangle.close()
                    triangle.fill()
                }
                if breakpoints.contains(lineNumber) {
                    (conditional.contains(lineNumber) ? NSColor.systemOrange : NSColor.systemRed).setFill()
                    let middle = top + line.typographicBounds.minY + line.typographicBounds.height / 2
                    NSBezierPath(ovalIn: NSRect(x: 6, y: middle - 5, width: 10, height: 10)).fill()
                }
            }
            return true
        }
    }
}
