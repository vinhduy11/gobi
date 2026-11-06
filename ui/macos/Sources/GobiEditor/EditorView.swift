import AppKit
import GobiClient
import GobiModel

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
    /// The completion popup of this editor; the host gives it a provider.
    public private(set) var completion: CompletionController?
    /// Tab stops of the snippet last inserted by a completion.
    public private(set) var snippets: SnippetTabs?
    /// The signature help popup of this editor; the host gives it a provider.
    public private(set) var signature: SignatureController?
    /// The hover panel of this editor; the host gives it a provider.
    public private(set) var hover: HoverController?

    /// The right-click menu for the editor text, built by the host.
    public var contextMenuProvider: ((NSEvent) -> NSMenu?)? {
        get { (textView as? EditorTextView)?.contextMenuProvider }
        set { (textView as? EditorTextView)?.contextMenuProvider = newValue }
    }
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

    public init(fileURL: URL, text: String, highlight: Bool = true, lineNumbers: Bool = true, wrapWidth: CGFloat = EditorView.editorWidth, settings: EditorSettings = EditorSettings(), lineLimit: Int = EditorDocument.editableLineLimit) {
        document = EditorDocument(fileURL: fileURL, text: text, lineLimit: lineLimit)
        let contentStorage = EditorContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: wrapWidth, height: 0))
        layoutManager.textContainer = container
        let editorTextView = EditorTextView(frame: NSRect(x: 0, y: 0, width: wrapWidth, height: 0), textContainer: container)
        editorTextView.document = document
        let snippetTabs = SnippetTabs(textView: editorTextView)
        editorTextView.snippets = snippetTabs
        snippets = snippetTabs
        let completionController = CompletionController(textView: editorTextView, document: document, snippets: snippetTabs)
        editorTextView.completion = completionController
        completion = completionController
        let signatureController = SignatureController(textView: editorTextView, document: document)
        editorTextView.signature = signatureController
        signature = signatureController
        let hoverController = HoverController(textView: editorTextView, document: document)
        editorTextView.hover = hoverController
        hover = hoverController
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

        applyLook(settings, to: nil)
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
        configuredWidth = wrapWidth
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
        textView.setSelectedRange(NSRange(location: 0, length: 0))   // a file opens at its top, not at its end

        if lineNumbers {
            let numbers = LineNumberGutter(scrollView: scrollView, textView: textView, document: document)
            let stack = NSStackView(views: [numbers, scrollView])
            stack.orientation = .horizontal
            stack.spacing = 0
            stack.distribution = .fill
            stack.alignment = .top
            scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gutter = numbers
            numbers.breakpoints = breakpointLines
            numbers.conditional = conditionalBreakpointLines
            numbers.onToggleBreakpoint = onToggleBreakpoint
            numbers.runnable = runnableLines
            numbers.onRunLine = onRunLine
            view = stack
            // The stack stretches the gutter and scroll view to its own height.
            numbers.topAnchor.constraint(equalTo: stack.topAnchor).isActive = true
            numbers.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
            scrollView.topAnchor.constraint(equalTo: stack.topAnchor).isActive = true
            scrollView.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }

        let bar = FindBar(textView: textView)
        let notice = NoticeBar()
        noticeBar = notice
        let column = NSStackView(views: [notice, bar, view])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.alignment = .leading
        bar.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        notice.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        findBar = bar
        view = column
    }

    // MARK: notice

    private var noticeBar: NoticeBar?

    /// A line with buttons above the editor (changed on disk, deleted, read-only).
    public func showNotice(_ text: String, style: NoticeStyle, actions: [NoticeAction] = []) { noticeBar?.show(text, style: style, actions: actions) }
    public func hideNotice() { noticeBar?.hide() }
    public var noticeText: String { noticeBar?.isHidden == false ? noticeBar?.text ?? "" : "" }
    public var noticeActionTitles: [String] { noticeBar?.isHidden == false ? noticeBar?.actionTitles ?? [] : [] }
    public func pressNotice(_ title: String) {
        guard let bar = noticeBar, let index = bar.actionTitles.firstIndex(of: title) else { return }
        bar.pressForTest(index)
    }

    // MARK: git

    /// Marks in the gutter for what changed since the last commit (1-based lines).
    public func setGitMarks(added: Set<Int>, modified: Set<Int>, deletedAfter: Set<Int>) {
        gutter?.gitAdded = added
        gutter?.gitModified = modified
        gutter?.gitDeletedAfter = deletedAfter
    }

    public var gitMarks: (added: Set<Int>, modified: Set<Int>, deletedAfter: Set<Int>) { (gutter?.gitAdded ?? [], gutter?.gitModified ?? [], gutter?.gitDeletedAfter ?? []) }

    // MARK: debugging

    /// Lines (1-based) with a breakpoint.
    public var breakpointLines: Set<Int> = [] { didSet { gutter?.breakpoints = breakpointLines } }
    /// The breakpoints among them that have a condition (drawn orange).
    public var conditionalBreakpointLines: Set<Int> = [] { didSet { gutter?.conditional = conditionalBreakpointLines } }
    /// Text shown after the end of a line while paused ("a = 20, b = 22"), by 1-based line.
    public var inlineValues: [Int: String] = [:] { didSet { (textView as? EditorTextView)?.inlineValues = inlineValues } }
    /// Called with a 1-based line when the user clicks the gutter.
    public var onToggleBreakpoint: ((Int) -> Void)? { didSet { gutter?.onToggleBreakpoint = onToggleBreakpoint } }

    /// Lines (1-based) that get a green Run button in the gutter (tests); a click calls `onRunLine` instead of toggling a breakpoint.
    public var runnableLines: Set<Int> = [] { didSet { gutter?.runnable = runnableLines } }
    public var onRunLine: ((Int) -> Void)? { didSet { gutter?.onRunLine = onRunLine } }
    public func clickRunButton(line: Int) { if runnableLines.contains(line) { onRunLine?(line) } }

    // MARK: code lens

    /// Sets the lens shown after each declaration line (1-based), valid for the document `version`; older text shows none.
    public func setCodeLenses(_ lenses: [Int: [LensSegment]], version: Int) {
        guard let view = textView as? EditorTextView else { return }
        view.codeLensVersion = version
        view.codeLenses = lenses
    }
    public var codeLenses: [Int: [LensSegment]] { (textView as? EditorTextView)?.codeLenses ?? [:] }
    /// Called with a 1-based line and what the clicked part of its lens asks for.
    public var onLensClick: ((Int, LensAction) -> Void)? {
        get { (textView as? EditorTextView)?.onLensClick }
        set { (textView as? EditorTextView)?.onLensClick = newValue }
    }
    public func clickLens(line: Int, action: LensAction) { onLensClick?(line, action) }
    /// Whether a lens is laid out at a point of the text view right now (what a click would hit).
    public func lensAction(at point: NSPoint) -> LensAction? { (textView as? EditorTextView)?.lensSegment(at: point)?.action }

    /// The zero-based lines on screen, widened by `margin` lines each way.
    public func visibleLines(margin: Int) -> Range<Int> {
        guard let layout = textView.textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange else { return 0 ..< 0 }
        let start = layout.offset(from: layout.documentRange.location, to: viewport.location)
        let end = layout.offset(from: layout.documentRange.location, to: viewport.endLocation)
        let lineCount = document.lineIndex.lineCount
        let first = max(0, document.lineIndex.position(at: start).line - margin)
        let last = min(lineCount, document.lineIndex.position(at: end).line + 1 + margin)
        return first ..< max(first, last)
    }

    /// The line (1-based) the debugger is paused on, or nil. It is highlighted and brought into view.
    public var debugLine: Int? {
        didSet {
            guard let line = debugLine, line >= 1, line <= document.lineIndex.lineCount else { (textView as? EditorTextView)?.debugLineRange = nil; return }
            let range = document.lineIndex.lineRange(line - 1)
            (textView as? EditorTextView)?.debugLineRange = NSRange(range)
            if line != oldValue { textView.scrollRangeToVisible(NSRange(location: range.lowerBound, length: 0)) }
        }
    }

    // MARK: settings

    public var isLineNumbersVisible: Bool { gutter.map { !$0.isHidden } ?? false }
    public var fontPointSize: CGFloat { textView.font?.pointSize ?? 0 }
    public var indentUnit: String { (textView as? EditorTextView)?.indentUnit ?? "\t" }
    public var rulerColumn: Int { (textView as? EditorTextView)?.rulerColumn ?? 0 }

    /// Applies Settings > Editor. Called once when the editor is made and again whenever a setting changes.
    /// Re-judges the open file against a new large-file limit: past it the text view stops accepting edits, under it it accepts them again.
    @discardableResult
    public func applyLineLimit(_ limit: Int) -> Bool {
        let changed = document.applyLineLimit(limit)
        textView.isEditable = !document.isReadOnlyByLineLength
        return changed
    }

    public func apply(_ settings: EditorSettings) {
        gutter?.isHidden = !settings.showLineNumbers
        (textView as? EditorTextView)?.rulerColumn = settings.rulerColumn
        (textView as? EditorTextView)?.showInvisibles = settings.showInvisibles
        (textView as? EditorTextView)?.codeLensEnabled = settings.showCodeLens
        (textView as? EditorTextView)?.autoClosePairs = settings.autoClosePairs
        (textView as? EditorTextView)?.autoIndent = settings.autoIndent
        setWrap(settings.wrapLines)
        (textView as? EditorTextView)?.indentUnit = settings.indentUnit(forLanguage: document.language)
        if settings.look != appliedLook { applyLook(settings, to: textView.textStorage) }
    }

    /// Wrap long lines at the window edge, or keep the fixed wide container (long lines scroll sideways). Off by default:
    /// the wide container is what keeps layout cheap in very large files.
    private func setWrap(_ wrap: Bool) {
        guard wrap != wrapsLines else { return }
        wrapsLines = wrap
        scrollView.hasHorizontalScroller = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.setFrameSize(NSSize(width: max(scrollView.contentSize.width, 200), height: textView.frame.height))
        } else {
            textView.autoresizingMask = []
            textView.setFrameSize(NSSize(width: configuredWidth, height: textView.frame.height))
        }
    }

    public private(set) var wrapsLines = false
    private var configuredWidth: CGFloat = EditorView.editorWidth
    public var textViewWidth: CGFloat { textView.frame.width }

    /// The font, line height and tab stops. Before the text is set they go on the view (the text then takes them as it is
    /// assigned); afterwards they are also written over the whole text.
    private func applyLook(_ settings: EditorSettings, to storage: NSTextStorage?) {
        let size = CGFloat(settings.fontSize)
        let font = (settings.fontName == "SF Mono" ? nil : NSFont(name: settings.fontName, size: size)) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let style = NSMutableParagraphStyle()
        // Every line, empty ones too, gets exactly this height; the text sits at the bottom of it.
        let height = ((font.ascender - font.descender + font.leading) * CGFloat(settings.lineHeight)).rounded()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.tabStops = []
        style.defaultTabInterval = font.maximumAdvancement.width * CGFloat(settings.tabWidth)
        textView.font = font
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        if let storage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttributes([.font: font, .paragraphStyle: style], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        (textView as? EditorTextView)?.rulerColumn = settings.rulerColumn
        appliedLook = settings.look
    }

    private var appliedLook = EditorSettings().look

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
