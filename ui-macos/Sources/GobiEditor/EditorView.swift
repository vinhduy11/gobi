import AppKit
import GobiClient

/// Turns a big jump (dragging the scroller thumb far, for example) into a jump by text position.
/// Scrolling to a pixel offset in a huge document makes TextKit 2 lay out every paragraph above the target and keep
/// them, which costs seconds once and then slows every later edit; scrolling to a text position does not.
final class EditorClipView: NSClipView {
    /// Called with the target as a fraction of the document (0 to 1) when a jump is large enough to remap.
    var jumpToFraction: ((Double) -> Bool)?
    /// scrollRangeToVisible scrolls through this view too; without the flag the remapped jump would remap itself forever.
    private var remapping = false
    /// While the user drags the scroller, big jumps are only remembered (as a fraction of the document) and applied once
    /// when the drag ends. Every place a drag stops keeps its layout, which made later edits slower (see the spike doc).
    public var defersLargeJumps = false
    private var deferredFraction: Double?
    private(set) var scrollCalls = 0
    private(set) var remappedJumps = 0
    private(set) var boundsOriginSets = 0

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        boundsOriginSets += 1
        super.setBoundsOrigin(newOrigin)
    }

    override func scroll(to newOrigin: NSPoint) {
        scrollCalls += 1
        let travel = abs(newOrigin.y - bounds.origin.y)
        if !remapping, travel > bounds.height * 6, let jump = jumpToFraction, let documentHeight = documentView?.frame.height, documentHeight > bounds.height {
            let fraction = Double(max(0, min(1, newOrigin.y / (documentHeight - bounds.height))))
            if defersLargeJumps {
                deferredFraction = fraction
                return
            }
            remapping = true
            defer { remapping = false }
            if jump(fraction) {
                remappedJumps += 1
                return
            }
        }
        super.scroll(to: newOrigin)
    }

    /// Applies the jump that was deferred during the drag, if any.
    func applyDeferredJump() {
        guard let fraction = deferredFraction, let jump = jumpToFraction else { return }
        deferredFraction = nil
        remapping = true
        defer { remapping = false }
        if jump(fraction) { remappedJumps += 1 }
    }
}

/// The editor itself: a TextKit 2 text view in a scroll view with a line-number gutter and syntax colours.
/// Shared by the app and the benchmarks so both measure the same setup.
public final class EditorView {
    /// A wide fixed-width view whose container tracks that width. An unbounded or non-tracking container makes TextKit 2
    /// lay out the whole document (100k lines: 2 s to open, 350 ms per keystroke, +700 MB); this takes 15 ms and 1.7 ms.
    public static let editorWidth: CGFloat = 3000

    public let document: EditorDocument
    public let scrollView: NSScrollView
    public let textView: NSTextView
    /// The view to put in a window: the gutter next to the scroll view, or just the scroll view.
    public private(set) var view: NSView
    public private(set) var loadMilliseconds = 0.0
    /// When true (the default) big scroll jumps are remapped to text positions; see EditorClipView.
    public var mapsLargeJumpsToLines = true
    private var highlighter: SyntaxHighlighter?
    private var gutter: LineNumberGutter?

    /// How scrolling reached the clip view: calls to scroll(to:), jumps remapped to text positions, direct origin changes.
    public var scrollStatistics: (scrollCalls: Int, remappedJumps: Int, boundsOriginSets: Int) {
        let clipView = scrollView.contentView as? EditorClipView
        return (clipView?.scrollCalls ?? 0, clipView?.remappedJumps ?? 0, clipView?.boundsOriginSets ?? 0)
    }
    public var paragraphsColoured: Int { highlighter?.paragraphsColoured ?? 0 }
    public var gutterDrawCount: Int { gutter?.drawCount ?? 0 }
    public var gutterLastDrawMilliseconds: Double { gutter?.lastDrawMilliseconds ?? 0 }
    public var gutterFrame: NSRect? { gutter?.frame }

    public init(fileURL: URL, text: String, highlight: Bool = true, lineNumbers: Bool = true) {
        document = EditorDocument(fileURL: fileURL, text: text)
        let editorTextView = EditorTextView(frame: NSRect(x: 0, y: 0, width: Self.editorWidth, height: 0))
        editorTextView.document = document
        editorTextView.minSize = NSSize(width: 0, height: 0)
        editorTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editorTextView.isVerticallyResizable = true
        editorTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView = editorTextView
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        view = scrollView
        let clipView = EditorClipView()
        clipView.drawsBackground = true
        scrollView.contentView = clipView
        clipView.documentView = textView
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) { [weak clipView] _ in
            clipView?.defersLargeJumps = true
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) { [weak clipView] _ in
            clipView?.defersLargeJumps = false
            clipView?.applyDeferredJump()
        }

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = []
        textView.setFrameSize(NSSize(width: Self.editorWidth, height: textView.frame.height))
        scrollView.hasHorizontalScroller = true

        clipView.jumpToFraction = { [weak self] fraction in
            guard let self, self.mapsLargeJumpsToLines else { return false }
            let line = Int(Double(self.document.lineIndex.lineCount - 1) * fraction)
            self.textView.scrollRangeToVisible(NSRange(location: self.document.lineIndex.lineRange(line).lowerBound, length: 0))
            return true
        }

        if highlight { highlighter = SyntaxHighlighter(textView: textView, document: document) }
        highlighter?.install()

        let loadStarted = Date()
        textView.string = text
        loadMilliseconds = Date().timeIntervalSince(loadStarted) * 1000
        textView.textStorage?.delegate = document

        if lineNumbers {
            let numbers = LineNumberGutter(scrollView: scrollView, textView: textView, document: document)
            let stack = NSStackView(views: [numbers, scrollView])
            stack.orientation = .horizontal
            stack.spacing = 0
            stack.distribution = .fill
            stack.alignment = .top
            scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gutter = numbers
            view = stack
            // The stack stretches the gutter and scroll view to its own height.
            numbers.topAnchor.constraint(equalTo: stack.topAnchor).isActive = true
            numbers.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
            scrollView.topAnchor.constraint(equalTo: stack.topAnchor).isActive = true
            scrollView.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }
    }

    /// Writes what the editor looks like to a PNG, painted on the CPU into a bitmap. Returns the painting time in ms.
    @discardableResult
    public func snapshot(to url: URL?) -> Double {
        let target = view
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return 0 }
        let started = Date()
        target.cacheDisplay(in: target.bounds, to: bitmap)
        let elapsed = Date().timeIntervalSince(started) * 1000
        if let url, let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        return elapsed
    }
}
