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
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
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

    @objc private func contentChanged(_ notification: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            drawCount += 1
            lastDrawMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        }
        NSColor.windowBackgroundColor.setFill()
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
            let number = "\(document.lineIndex.position(at: offset).line + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            let top = convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y
            // Align the number with the first text line of the paragraph.
            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? size.height
            number.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: top + (lineHeight - size.height) / 2), withAttributes: attributes)
            return true
        }
    }
}
