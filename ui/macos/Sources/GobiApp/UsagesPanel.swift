import AppKit
import GobiEditor
import GobiModel

/// A row of the usages tree.
final class UsageNode {
    enum Kind {
        case file(UsageFile)
        case function(UsageFunction, UsageFile)
        case line(UsageLine)
        case more(Int)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    var children: [UsageNode] = []
}

/// Outline view that handles Return (open the line) and ⌥↓ / ⌥↑ (next / previous usage) itself.
final class UsagesOutlineView: NSOutlineView {
    var onReturn: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }

    override func keyDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 36, 76: onReturn()
        case 125 where option: onStep(1)
        case 126 where option: onStep(-1)
        default: super.keyDown(with: event)
        }
    }
}

/// The Usages tab (Usages mock): "Usages of X: 12 in 4 files", the tests checkbox, Rerun / Previous / Next, and the tree
/// file > function > line with the match in bold. It only draws what the feed gives it; source lines come from the feed's cache.
final class UsagesPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let header = NSTextField(labelWithString: "")
    private let staleLabel = NSTextField(labelWithString: "Out of date: a file changed since this search")
    private let testsBox = NSButton(checkboxWithTitle: "Tests", target: nil, action: nil)
    private let outline = UsagesOutlineView()
    private var roots: [UsageNode] = []
    private var flatLines: [UsageNode] = []
    private(set) var lineNumbers: [Int] = []

    /// Source text of a usage line from the feed's cache, and the project-relative path of a file uri.
    var lineText: (UsageLine) -> String? = { _ in nil }
    var displayPath: (String) -> String = { $0 }
    var onOpen: (UsageLine) -> Void = { _ in }
    var onRerun: () -> Void = {}
    var onTestsChanged: (Bool) -> Void = { _ in }
    var onShowMore: () -> Void = {}

    var includesTests: Bool { testsBox.state == .on }
    var headerText: String { header.stringValue }
    var isStaleShown: Bool { !staleLabel.isHidden }
    var fileTitles: [String] { roots.compactMap { if case .file(let f) = $0.kind { return displayPath(f.uri) } else { return nil } } }
    var functionTitles: [String] { roots.flatMap(\.children).compactMap { if case .function(let f, _) = $0.kind { return f.name ?? "file scope" } else { return nil } } }
    var usageCount: Int { flatLines.count }
    var showMoreTitle: String? { roots.compactMap { if case .more(let n) = $0.kind { return "Show \(n) more usages" } else { return nil } }.first }
    var selectedUsage: UsageLine? { selectedLineNode() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        staleLabel.textColor = .systemOrange
        staleLabel.font = NSFont.systemFont(ofSize: 12)
        staleLabel.isHidden = true
        testsBox.state = .on
        testsBox.target = self
        testsBox.action = #selector(testsToggled)
        testsBox.toolTip = "Include usages in _test.go files"
        let rerun = NSButton(title: "Rerun", target: self, action: #selector(rerunPressed))
        let previous = NSButton(title: "Previous ⌥↑", target: self, action: #selector(previousPressed))
        let next = NSButton(title: "Next ⌥↓", target: self, action: #selector(nextPressed))
        for button in [rerun, previous, next] { button.bezelStyle = .rounded; button.controlSize = .small }
        let top = NSStackView(views: [header, staleLabel, NSView(), testsBox, rerun, previous, next])
        top.spacing = 10
        top.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("usage"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 18
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Usages")
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.onStep = { [weak self] delta in self?.step(delta) }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let hint = NSTextField(labelWithString: "Return or click opens the line · lists up to \(UsageGroups.pageSize) usages")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        let foot = NSStackView(views: [hint])
        foot.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        let all = NSStackView(views: [top, Hairline(), scroll, Hairline(), foot])
        all.orientation = .vertical
        all.spacing = 0
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: all.widthAnchor), scroll.widthAnchor.constraint(equalTo: all.widthAnchor),
            foot.widthAnchor.constraint(equalTo: all.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: content

    /// A message in place of the list (searching, nothing found).
    func showMessage(_ text: String) {
        header.stringValue = text
        setRoots([])
        staleLabel.isHidden = true
    }

    func show(_ result: UsageResult, symbol: String) {
        let title = NSMutableAttributedString(string: "Usages of ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        title.append(NSAttributedString(string: result.declaration ?? symbol, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)]))
        title.append(NSAttributedString(string: "  —  " + UsageGroups.summary(usages: result.total, files: result.totalFiles), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        header.attributedStringValue = title
        var nodes: [UsageNode] = result.files.map { file in
            let node = UsageNode(.file(file))
            node.children = file.functions.map { function in
                let fnode = UsageNode(.function(function, file))
                fnode.children = function.lines.map { UsageNode(.line($0)) }
                return fnode
            }
            return node
        }
        if result.hidden > 0 { nodes.append(UsageNode(.more(min(result.hidden, UsageGroups.pageSize)))) }
        setRoots(nodes)
    }

    func markStale(_ stale: Bool) { staleLabel.isHidden = !stale }

    private func setRoots(_ nodes: [UsageNode]) {
        roots = nodes
        flatLines = nodes.flatMap(\.children).flatMap(\.children).filter { if case .line = $0.kind { return true } else { return false } }
        lineNumbers = flatLines.compactMap { if case .line(let l) = $0.kind { return l.line } else { return nil } }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    // MARK: selection and keys

    private func selectedLineNode() -> UsageLine? {
        guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? UsageNode, case .line(let line) = node.kind else { return nil }
        return line
    }

    func openSelected() { if let line = selectedLineNode() { onOpen(line) } }

    /// Selects the next (or previous) usage, wrapping around, and opens it in the editor.
    func step(_ delta: Int) {
        let current = flatLines.firstIndex { node in
            if case .line(let a) = node.kind, let b = selectedLineNode() { return a == b }
            return false
        }
        guard let target = UsageGroups.step(from: current, by: delta, count: flatLines.count) else { return }
        let row = outline.row(forItem: flatLines[target])
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        openSelected()
    }

    /// Selects a usage without opening it (self-test).
    func select(usageAt index: Int) {
        guard flatLines.indices.contains(index) else { return }
        let row = outline.row(forItem: flatLines[index])
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Builds the view of every row the way scrolling would, so a self-test sees what the table callbacks read.
    func renderAllRows() { for row in 0 ..< outline.numberOfRows { _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true) } }

    func setIncludesTests(_ on: Bool) { testsBox.state = on ? .on : .off; testsToggled() }
    func pressShowMore() { onShowMore() }

    @objc private func testsToggled() { onTestsChanged(includesTests) }
    @objc private func rerunPressed() { onRerun() }
    @objc private func previousPressed() { step(-1) }
    @objc private func nextPressed() { step(1) }

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? UsageNode else { return }
        switch node.kind {
        case .line(let line): onOpen(line)
        case .more: onShowMore()
        default: if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? UsageNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? UsageNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? UsageNode)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? UsageNode else { return nil }
        switch node.kind {
        case .file(let file):
            let name = NSTextField(labelWithString: displayPath(file.uri))
            name.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            name.lineBreakMode = .byTruncatingHead
            return Self.row([name, Self.count(file.count)])
        case .function(let function, _):
            let name = NSTextField(labelWithString: function.name.map { Self.isFunction(function.kind) ? "func " + $0 : $0 } ?? "file scope")
            name.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            name.textColor = function.name == nil ? .secondaryLabelColor : .labelColor
            return Self.row([name, Self.count(function.lines.count)])
        case .line(let line):
            let number = NSTextField(labelWithString: String(line.line + 1))
            number.textColor = .secondaryLabelColor
            number.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let text = NSTextField(labelWithAttributedString: attributed(line))
            text.lineBreakMode = .byTruncatingTail
            return Self.row([number, text], spacing: 10)
        case .more(let count):
            let label = NSTextField(labelWithString: "Show \(count) more usages")
            label.textColor = ThemeColors.accent
            return Self.row([label])
        }
    }

    private func attributed(_ line: UsageLine) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        guard let source = lineText(line) else { return NSAttributedString(string: "", attributes: [.font: regular]) }
        let excerpt = UsageGroups.excerpt(source, start: line.start, end: line.end)
        let result = NSMutableAttributedString(string: excerpt.text, attributes: [.font: regular, .foregroundColor: NSColor.labelColor])
        if excerpt.matchEnd > excerpt.matchStart, excerpt.matchEnd <= result.length {
            result.addAttribute(.font, value: bold, range: NSRange(location: excerpt.matchStart, length: excerpt.matchEnd - excerpt.matchStart))
        }
        return result
    }

    private static func isFunction(_ kind: OutlineSymbol.Kind?) -> Bool { kind == .function || kind == .method }

    private static func count(_ n: Int) -> NSTextField {
        let label = NSTextField(labelWithString: String(n))
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        return stack
    }
}
