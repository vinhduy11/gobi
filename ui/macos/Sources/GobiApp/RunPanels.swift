import AppKit
import GobiModel

private func pill(_ text: String, color: NSColor = .secondaryLabelColor) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 12)
    label.textColor = color
    let box = NSView()
    box.wantsLayer = true
    box.layer?.cornerRadius = 11
    box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    label.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
        label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
    ])
    return box
}

private func rgb(_ color: RGB) -> NSColor {
    NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
}

/// The Output tab: the command that ran, its exit state and time, and the streamed text in the terminal's colours.
final class OutputPanelView: NSView, NSTextViewDelegate {
    private let command = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let text = NSTextView()
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private var characters = 0
    private let limit = 2_000_000
    var onStop: (() -> Void)?
    /// Called when a `file.go:12:5` mention in the output is clicked.
    var onOpenReference: ((SourceReference) -> Void)?

    var content: String { text.string }
    var stateText: String { state.stringValue }
    var commandText: String { command.stringValue }

    init() {
        super.init(frame: .zero)
        for label in [command, state, elapsed] {
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
        }
        command.textColor = .labelColor
        state.textColor = .secondaryLabelColor
        elapsed.textColor = .secondaryLabelColor
        stop.target = self
        stop.action = #selector(stopPressed)
        stop.isEnabled = false
        clear.target = self
        clear.action = #selector(clearPressed)
        let bar = NSStackView(views: [command, state, elapsed, NSView(), clear, stop])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        text.isEditable = false
        text.isSelectable = true
        text.delegate = self
        text.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.setAccessibilityLabel("Output")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let rule = NSBox()
        rule.boxType = .separator
        let stack = NSStackView(views: [bar, rule, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor), rule.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyColours()
        showIdle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    private var palette: TerminalPalette { TerminalPalette.forAppearance(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }

    private func applyColours() {
        text.backgroundColor = rgb(palette.background)
        text.textColor = rgb(palette.foreground)
    }

    private func showIdle() {
        command.stringValue = ""
        state.stringValue = "Nothing has run yet. Run (⌘R) or Run Tests (⌘U)."
        elapsed.stringValue = ""
    }

    /// Starts a new run's transcript: clears the text and shows the command and that it is running.
    func begin(commandLine: String) {
        text.string = ""
        characters = 0
        command.stringValue = commandLine
        state.stringValue = "running…"
        elapsed.stringValue = ""
        stop.isEnabled = true
    }

    func append(_ bytes: [UInt8], isError: Bool) {
        let piece = String(decoding: bytes, as: UTF8.self)
        let colour = isError ? rgb(palette.ansi[1]) : rgb(palette.foreground)
        let attributed = NSAttributedString(string: piece, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: colour])
        let lineStart = text.textStorage.map { ($0.string as NSString).range(of: "\n", options: .backwards).upperBound } ?? 0
        text.textStorage?.append(attributed)
        linkReferences(from: lineStart)
        characters += piece.count
        if characters > limit, let storage = text.textStorage {
            let drop = characters - limit / 2
            storage.deleteCharacters(in: NSRange(location: 0, length: min(drop, storage.length)))
            characters = storage.length
        }
        text.scrollToEndOfDocument(nil)
    }

    /// Makes each `file.go:12:5` in the text from `start` on a link; `start` is the beginning of the line being written.
    private func linkReferences(from start: Int) {
        guard let storage = text.textStorage, start <= storage.length else { return }
        let region = NSRange(location: start, length: storage.length - start)
        let lines = (storage.string as NSString).substring(with: region)
        var lineOffset = 0
        for line in lines.components(separatedBy: "\n") {
            for reference in SourceReference.find(in: line) {
                storage.addAttribute(.link, value: Self.encode(reference), range: NSRange(location: start + lineOffset + reference.offset, length: reference.length))
            }
            lineOffset += (line as NSString).length + 1
        }
    }

    private static func encode(_ r: SourceReference) -> String { "\(r.line)\t\(r.column ?? 0)\t\(r.path)" }

    private static func decode(_ value: String) -> SourceReference? {
        let parts = value.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let line = Int(parts[0]), let column = Int(parts[1]) else { return nil }
        return SourceReference(path: String(parts[2]), line: line, column: column == 0 ? nil : column, offset: 0, length: 0)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let value = link as? String, let reference = Self.decode(value) else { return false }
        onOpenReference?(reference)
        return true
    }

    /// The linked mentions currently in the text, in order (for tests).
    var linkedReferences: [String] {
        guard let storage = text.textStorage else { return [] }
        var found: [String] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { found.append((storage.string as NSString).substring(with: range)) }
        }
        return found
    }

    func clickLink(at index: Int) {
        guard let storage = text.textStorage, index < storage.length, let value = storage.attribute(.link, at: index, effectiveRange: nil) as? String else { return }
        _ = textView(text, clickedOnLink: value, at: index)
    }

    func finish(code: Int, message: String, seconds: Double) {
        stop.isEnabled = false
        state.stringValue = message.isEmpty ? "exit \(code)" : message
        state.textColor = code == 0 ? NSColor.systemGreen : NSColor.systemRed
        elapsed.stringValue = String(format: "%.2f s", seconds)
    }

    /// A message in place of a run, for example that running code needs trust.
    func notice(_ message: String) {
        text.string = ""
        characters = 0
        command.stringValue = ""
        state.stringValue = message
        state.textColor = .secondaryLabelColor
        elapsed.stringValue = ""
        stop.isEnabled = false
    }

    @objc private func stopPressed() { onStop?() }
    @objc private func clearPressed() { showIdle(); text.string = ""; characters = 0 }
}

/// The Tests tab: counts, the time, Run Failed and Run All, and the package and test tree with each failure's message.
final class TestsPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var isUpdating = false
    private let filter = NSSearchField()
    private var lastResults = TestResults()
    private var lastRunning = false
    private enum Item { case row(TestRow), detail(String, depth: Int) }

    private let table = NSTableView()
    private let summary = NSStackView()
    private let time = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "No test run yet. Run Tests (⌘U) to start.")
    private let runFailed = NSButton(title: "Run Failed", target: nil, action: nil)
    private let runAll = NSButton(title: "Run All", target: nil, action: nil)
    private var items: [Item] = []
    var onRunAll: (() -> Void)?
    var onRunFailed: (() -> Void)?
    /// Called when a failed test or one of its messages is picked, with the first `file.go:12` in its message.
    var onOpenReference: ((SourceReference) -> Void)?

    var titles: [String] { items.compactMap { if case .row(let row) = $0 { return row.title } else { return nil } } }
    var detailLines: [String] { items.compactMap { if case .detail(let text, _) = $0 { return text } else { return nil } } }
    var isRunFailedEnabled: Bool { runFailed.isEnabled }

    init() {
        super.init(frame: .zero)
        runAll.target = self
        runAll.action = #selector(runAllPressed)
        runFailed.target = self
        runFailed.action = #selector(runFailedPressed)
        runFailed.isEnabled = false
        time.font = NSFont.systemFont(ofSize: 12)
        time.textColor = .secondaryLabelColor
        filter.placeholderString = "Filter tests"
        filter.delegate = self
        filter.setAccessibilityLabel("Filter tests")
        // 160 pt when there is room; in a narrow sidebar the filter gives way first.
        let filterWidth = filter.widthAnchor.constraint(equalToConstant: 160)
        filterWidth.priority = NSLayoutConstraint.Priority(499)
        filterWidth.isActive = true
        filter.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        let bar = NSStackView(views: [summary, time, NSView(), filter, runFailed, runAll])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.setAccessibilityLabel("Test results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        let stack = NSStackView(views: [bar, rule, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(empty)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor), rule.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), empty.topAnchor.constraint(equalTo: topAnchor, constant: 54),
        ])
        update(TestResults(), running: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func runAllPressed() { onRunAll?() }
    @objc private func runFailedPressed() { onRunFailed?() }

    var filterText: String {
        get { filter.stringValue }
        set { filter.stringValue = newValue; update(lastResults, running: lastRunning) }
    }

    func controlTextDidChange(_ obj: Notification) { update(lastResults, running: lastRunning) }

    /// Esc in the filter box clears it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), !filter.stringValue.isEmpty else { return false }
        filterText = ""
        return true
    }

    func update(_ results: TestResults, running: Bool) {
        lastResults = results
        lastRunning = running
        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let total = results.passed + results.failed + results.skipped
        if total > 0 || running {
            summary.addArrangedSubview(pill("✓ \(results.passed) passed", color: .systemGreen))
            if results.failed > 0 { summary.addArrangedSubview(pill("✗ \(results.failed) failed", color: .systemRed)) }
            if results.skipped > 0 { summary.addArrangedSubview(pill("↷ \(results.skipped) skipped", color: .systemOrange)) }
            if running { summary.addArrangedSubview(pill("running…")) }
        }
        time.stringValue = results.totalMilliseconds > 0 ? String(format: "in %.2f s", Double(results.totalMilliseconds) / 1000) : ""
        runFailed.isEnabled = results.failedFilter != nil && !running
        runAll.isEnabled = !running
        items = []
        for row in TestFilter.rows(results.rows(), matching: filter.stringValue) {
            items.append(.row(row))
            for line in row.detail.split(separator: "\n") { items.append(.detail(String(line), depth: row.depth + 1)) }
        }
        empty.stringValue = filter.stringValue.isEmpty ? "No test run yet. Run Tests (⌘U) to start." : "No tests match “\(filter.stringValue)”."
        empty.isHidden = !items.isEmpty
        isUpdating = true
        table.reloadData()
        isUpdating = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// The mention to open for a row: its own line for a message, else the first one in the messages under a failed test.
    func reference(forRow index: Int) -> SourceReference? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .detail(let line, _): return SourceReference.find(in: line).first
        case .row(let row):
            guard row.status == .failed else { return nil }
            for item in items[(index + 1)...] {
                guard case .detail(let line, _) = item else { break }
                if let found = SourceReference.find(in: line).first { return found }
            }
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, let reference = reference(forRow: table.selectedRow) else { return }
        onOpenReference?(reference)
    }

    func select(title: String) {
        if let index = items.firstIndex(where: { if case .row(let row) = $0 { return row.title == title } else { return false } }) { select(row: index) }
    }

    func select(row index: Int) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        switch items[index] {
        case .detail(let line, let depth):
            let label = NSTextField(labelWithString: line)
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .systemRed
            label.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [label])
            stack.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(14 + depth * 22 + 22), bottom: 0, right: 12)
            return stack
        case .row(let row):
            let (symbol, colour, description): (String, NSColor, String) = {
                switch row.status {
                case .passed: return ("checkmark", .systemGreen, "Passed")
                case .failed: return ("xmark", .systemRed, "Failed")
                case .skipped: return ("arrow.turn.down.right", .systemOrange, "Skipped")
                case .running: return ("circle.dotted", .secondaryLabelColor, "Running")
                }
            }()
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage())
            icon.contentTintColor = colour
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let title = NSTextField(labelWithString: row.title)
            title.font = NSFont.systemFont(ofSize: 13, weight: row.depth == 0 ? .semibold : .regular)
            title.lineBreakMode = .byTruncatingMiddle
            let duration = NSTextField(labelWithString: row.status == .skipped ? "skipped" : (row.elapsedMilliseconds > 0 || row.status != .running ? String(format: "%.2f s", Double(row.elapsedMilliseconds) / 1000) : ""))
            duration.font = NSFont.systemFont(ofSize: 12)
            duration.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [icon, title, NSView(), duration])
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(12 + row.depth * 22), bottom: 0, right: 12)
            stack.setAccessibilityLabel("\(row.title), \(description)")
            return stack
        }
    }
}
