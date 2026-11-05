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
    /// While the thumb is being dragged, big jumps are applied at most once per `liveJumpInterval` and the newest one is
    /// always applied when the drag ends. Every place the text stops keeps its layout, so applying a jump on every drag tick
    /// (about 60 a second) left later edits slower (see the spike doc); a few jumps a second keep the text following the thumb.
    var isLiveScrolling = false
    static let liveJumpInterval: TimeInterval = 0.12
    private var pendingFraction: Double?
    private var lastAppliedJump = Date.distantPast
    private var flushTimer: Timer?
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
            if isLiveScrolling {
                requestLiveJump(fraction)
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

    private func requestLiveJump(_ fraction: Double) {
        pendingFraction = fraction
        let wait = Self.liveJumpInterval - Date().timeIntervalSince(lastAppliedJump)
        if wait <= 0 {
            applyPendingJump()
        } else if flushTimer == nil {
            // The thumb may stop moving before the interval is over; still show where it was left.
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.applyPendingJump() }
            RunLoop.main.add(timer, forMode: .common)
            flushTimer = timer
        }
    }

    /// Applies the newest requested jump, if any.
    func applyPendingJump() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard let fraction = pendingFraction, let jump = jumpToFraction else { return }
        pendingFraction = nil
        lastAppliedJump = Date()
        remapping = true
        defer { remapping = false }
        if jump(fraction) { remappedJumps += 1 }
    }
}

/// Text content storage that reports when an edit has been fully processed, including the synchronisation with the
/// layout manager that shifts rendering attributes; see SyntaxHighlighter.recolourAfterEdit. Inside an editing
/// transaction (typing goes through one) the report waits for the transaction to end, when the text is consistent again.
final class EditorContentStorage: NSTextContentStorage {
    var afterEditing: (() -> Void)?
    private var editWaitsForTransaction = false

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        if hasEditingTransaction { editWaitsForTransaction = true } else { afterEditing?() }
    }

    override func performEditingTransaction(_ transaction: () -> Void) {
        super.performEditingTransaction(transaction)
        guard !hasEditingTransaction, editWaitsForTransaction else { return }
        editWaitsForTransaction = false
        afterEditing?()
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
    private var findBar: FindBar?

    /// How scrolling reached the clip view: calls to scroll(to:), jumps remapped to text positions, direct origin changes.
    public var scrollStatistics: (scrollCalls: Int, remappedJumps: Int, boundsOriginSets: Int) {
        let clipView = scrollView.contentView as? EditorClipView
        return (clipView?.scrollCalls ?? 0, clipView?.remappedJumps ?? 0, clipView?.boundsOriginSets ?? 0)
    }
    public var paragraphsColoured: Int { highlighter?.paragraphsColoured ?? 0 }
    public var gutterDrawCount: Int { gutter?.drawCount ?? 0 }
    public var gutterLastDrawMilliseconds: Double { gutter?.lastDrawMilliseconds ?? 0 }
    public var gutterFrame: NSRect? { gutter?.frame }

    public init(fileURL: URL, text: String, highlight: Bool = true, lineNumbers: Bool = true, wrapWidth: CGFloat = EditorView.editorWidth) {
        document = EditorDocument(fileURL: fileURL, text: text)
        let contentStorage = EditorContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: wrapWidth, height: 0))
        layoutManager.textContainer = container
        let editorTextView = EditorTextView(frame: NSRect(x: 0, y: 0, width: wrapWidth, height: 0), textContainer: container)
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
            clipView?.isLiveScrolling = true
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) { [weak clipView] _ in
            clipView?.isLiveScrolling = false
            clipView?.applyPendingJump()
        }

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = !document.isReadOnlyByLineLength
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = []
        textView.setFrameSize(NSSize(width: wrapWidth, height: textView.frame.height))
        scrollView.hasHorizontalScroller = true

        clipView.jumpToFraction = { [weak self] fraction in
            guard let self, self.mapsLargeJumpsToLines else { return false }
            let line = Int(Double(self.document.lineIndex.lineCount - 1) * fraction)
            self.textView.scrollRangeToVisible(NSRange(location: self.document.lineIndex.lineRange(line).lowerBound, length: 0))
            return true
        }

        if highlight { highlighter = SyntaxHighlighter(textView: textView, document: document) }
        highlighter?.install()
        contentStorage.afterEditing = { [weak self] in self?.highlighter?.recolourAfterEdit() }

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

        let bar = FindBar(textView: textView)
        let column = NSStackView(views: [bar, view])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.alignment = .leading
        bar.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        findBar = bar
        view = column
    }

    // MARK: find in file

    public func showFindBar() { findBar?.show() }
    public func findNext() { findBar?.find(forward: true) }
    public func findPrevious() { findBar?.find(forward: false) }
    /// Sets the search text without showing the bar (the "Use Selection for Find" command and the harness).
    public func setSearchString(_ text: String) { findBar?.setSearchString(text) }
    public var isFindBarVisible: Bool { !(findBar?.isHidden ?? true) }
    @discardableResult
    public func find(forward: Bool) -> NSRange? { findBar?.find(forward: forward) }

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
