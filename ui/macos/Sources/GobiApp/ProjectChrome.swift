import AppKit
import GobiModel

/// A thin line across a bar, the way the mock separates regions.
private final class Hairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// "hello › internal › server › server.go" under the editor tabs.
final class BreadcrumbView: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path of the open file")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(segments: [String]) {
        label.stringValue = segments.joined(separator: "  ›  ")
        setAccessibilityValue(label.stringValue)
    }
}

/// The status bar across the bottom of the project window: branch, gopls state on the left; caret, encoding, line ending
/// and Go version on the right.
final class StatusBarView: NSView {
    private let branch = NSTextField(labelWithString: "")
    private let gopls = NSTextField(labelWithString: "")
    private let caret = NSTextField(labelWithString: "")
    private let encoding = NSTextField(labelWithString: "UTF-8")
    private let lineEnding = NSTextField(labelWithString: "LF")
    private let goVersion = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    var texts: [String] { [branch, gopls, note, caret, encoding, lineEnding, goVersion].map(\.stringValue) }

    init() {
        super.init(frame: .zero)
        let all = [branch, gopls, note, caret, encoding, lineEnding, goVersion]
        for label in all {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [branch, gopls, note, NSView(), caret, encoding, lineEnding, goVersion])
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        let rule = Hairline()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor), rule.topAnchor.constraint(equalTo: topAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(branch text: String?, gopls: String, go: String?) {
        branch.stringValue = text.map { "⎇ " + $0 } ?? ""
        branch.isHidden = text == nil
        self.gopls.stringValue = gopls
        goVersion.stringValue = go.map { "Go " + $0 } ?? ""
    }

    func set(note text: String) { note.stringValue = text }

    func set(caret text: String?, lineEnding ending: String?) {
        caret.stringValue = text ?? ""
        lineEnding.stringValue = ending ?? ""
        encoding.isHidden = text == nil
        lineEnding.isHidden = ending == nil
    }
}

/// One problem in the Problems list.
struct ProblemItem {
    let severity: Int          // 1 error, 2 warning, 3 info, 4 hint
    let message: String
    let detail: String         // "internal/server/server.go:28 · gopls"
    let path: String
    let line: Int
    let character: Int
}

/// A tab of the bottom panel: roomy, with an accent underline when selected and a soft highlight under the pointer.
final class PanelTabButton: NSButton {
    var isCurrent = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: 30)   // 12 points of room on each side, as in the mock
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && !isCurrent {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular),
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let box = text.size()
        text.draw(at: NSPoint(x: bounds.midX - box.width / 2, y: bounds.midY - box.height / 2 + 1))
        if isCurrent {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 8, y: isFlipped ? bounds.maxY - 2 : 0, width: bounds.width - 16, height: 2).fill()   // along the bottom edge
        }
    }
}

/// The bottom panel of the mock: tab row (Problems, Tests, Terminal, Debug, Profiler, Git, Output) over the active tab's
/// content. Problems is a list; the tabs whose features are not built yet say so.
final class BottomPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let tabNames = ["Problems", "Tests", "Terminal", "Debug", "Profiler", "Git", "Output"]
    private static let notBuilt = [
        "Tests": "The test runner arrives with Run and Test.",
        "Terminal": "The terminal arrives next.",
        "Debug": "Debugging with dlv comes in a later slice.",
        "Profiler": "Profiling with pprof comes in a later slice.",
        "Git": "Git status, diff and commit come in a later slice.",
        "Output": "Command output appears here once Run exists.",
    ]

    private var buttons: [NSButton] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var problems: [ProblemItem] = []
    private(set) var selectedTab = 0
    var onOpenProblem: ((ProblemItem) -> Void)?
    /// Called each time the Terminal tab is shown, so the first shell can start then.
    var onTerminalShown: (() -> Void)?
    private let terminalHost = NSView()
    var isTerminalVisible: Bool { selectedTab == 2 && !terminalHost.isHidden }

    var problemCount: Int { problems.count }
    var tabTitles: [String] { buttons.map(\.title) }
    /// Frames of the tab buttons in the panel's coordinates and which one is current, for the self-test.
    var tabLayout: [(frame: NSRect, isCurrent: Bool)] {
        layoutSubtreeIfNeeded()
        return buttons.map { (convert($0.bounds, from: $0), ($0 as? PanelTabButton)?.isCurrent ?? false) }
    }

    init() {
        super.init(frame: .zero)
        let tabs = NSStackView()
        tabs.spacing = 2
        tabs.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for (index, name) in Self.tabNames.enumerated() {
            let button = PanelTabButton(title: name, target: self, action: #selector(tabPressed(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityRole(.radioButton)
            tabs.addArrangedSubview(button)
            buttons.append(button)
        }
        tabs.addArrangedSubview(NSView())

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("problem"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowOpened)
        table.setAccessibilityLabel("Problems")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true

        let rule = Hairline()
        terminalHost.isHidden = true
        let stack = NSStackView(views: [rule, tabs, Hairline(), scroll, terminalHost])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 54),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
        for part in [rule, tabs, scroll, terminalHost] { part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for part in [scroll, terminalHost] { part.setContentHuggingPriority(.defaultLow, for: .vertical) }
        select(tab: 0)
        setProblems([])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts the terminal view in the panel; it shows when the Terminal tab is selected.
    func install(terminal: NSView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor), terminal.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: terminalHost.topAnchor), terminal.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
    }

    func setProblems(_ items: [ProblemItem]) {
        problems = items
        buttons[0].title = StatusBar.problemsTitle(count: items.count)
        table.reloadData()
        if selectedTab == 0 { showContent() }
    }

    func select(tab index: Int) {
        selectedTab = index
        for (position, button) in buttons.enumerated() {
            (button as? PanelTabButton)?.isCurrent = position == index
            button.setAccessibilityValue(position == index ? 1 : 0)
        }
        showContent()
    }

    private func showContent() {
        let name = Self.tabNames[selectedTab]
        let showsTerminal = selectedTab == 2 && !terminalHost.subviews.isEmpty
        terminalHost.isHidden = !showsTerminal
        if showsTerminal {
            scroll.isHidden = true
            placeholder.isHidden = true
            onTerminalShown?()
        } else if selectedTab == 0 {
            scroll.isHidden = false
            placeholder.isHidden = problems.isEmpty ? false : true
            placeholder.stringValue = "No problems"
            scroll.isHidden = problems.isEmpty
        } else {
            scroll.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = Self.notBuilt[name] ?? ""
        }
    }

    @objc private func tabPressed(_ sender: NSButton) { select(tab: sender.tag) }

    @objc private func rowOpened() {
        guard table.clickedRow >= 0, table.clickedRow < problems.count else { return }
        onOpenProblem?(problems[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { problems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = problems[row]
        let symbol = item.severity == 1 ? "xmark.octagon.fill" : item.severity == 2 ? "exclamationmark.triangle.fill" : "info.circle.fill"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: item.severity == 1 ? "Error" : item.severity == 2 ? "Warning" : "Info") ?? NSImage())
        icon.contentTintColor = item.severity == 1 ? .systemRed : item.severity == 2 ? .systemOrange : .systemBlue
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let message = NSTextField(labelWithString: item.message)
        message.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [message, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let row = NSStackView(views: [icon, texts])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        return row
    }
}
