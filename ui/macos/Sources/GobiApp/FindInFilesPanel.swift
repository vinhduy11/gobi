import AppKit
import GobiModel

/// A file or a hit in the results tree.
final class SearchNode {
    let path: String
    let hit: SearchHit?
    let hits: [SearchHit]
    init(path: String, hits: [SearchHit]) { self.path = path; self.hit = nil; self.hits = hits }
    init(hit: SearchHit) { self.path = hit.path; self.hit = hit; self.hits = [hit] }
}

/// The Find tab (Find in Files mock): query with its options and file filter, an optional replacement, and the results grouped
/// by file; a click opens the match.
final class FindInFilesPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let query = NSSearchField()
    let replacement = NSTextField()
    let include = NSTextField()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let wordButton = NSButton(title: "W", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private var groups: [SearchNode] = []
    private(set) var results = SearchResults()
    var onSearch: () -> Void = {}
    var onOpen: (SearchHit) -> Void = { _ in }
    var onReplace: ([SearchHit]) -> Void = { _ in }
    var onReplaceHit: (SearchHit) -> Void = { _ in }
    /// Files left out of Replace All (unchecked in the results).
    private(set) var excludedPaths: Set<String> = []

    var isCaseSensitive: Bool { caseButton.state == .on }
    var isWholeWord: Bool { wordButton.state == .on }
    var isRegex: Bool { regexButton.state == .on }
    var summaryText: String { summary.stringValue }
    var groupPaths: [String] { groups.map(\.path) }
    var includeGlobs: [String] { SearchOptionsText.globs(include.stringValue) }
    var includedHits: [SearchHit] { ReplaceSelection.included(results.hits, excludingPaths: excludedPaths) }
    var recentQueries: [String] { query.recentSearches }
    var replacementText: String? { replacement.stringValue.isEmpty ? nil : replacement.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        query.placeholderString = "Find in files"
        query.target = self
        query.action = #selector(searchEntered)
        query.sendsSearchStringImmediately = false
        let recents = NSMenu(title: "Recent Searches")
        for (title, tag) in [("Recent Searches", NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag), ("No recent searches", NSSearchField.noRecentsMenuItemTag)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            recents.addItem(item)
        }
        query.searchMenuTemplate = recents
        replacement.placeholderString = "Replace with"
        include.placeholderString = "*.go"
        include.delegate = self
        include.widthAnchor.constraint(equalToConstant: 130).isActive = true
        for (button, tip) in [(caseButton, "Match case"), (wordButton, "Whole word"), (regexButton, "Regular expression")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toolTip = tip
            button.target = self
            button.action = #selector(searchEntered)
        }
        let replaceAll = NSButton(title: "Replace All", target: self, action: #selector(replaceAllPressed))
        replaceAll.bezelStyle = .rounded
        replaceAll.controlSize = .small
        summary.textColor = .secondaryLabelColor
        summary.font = NSFont.systemFont(ofSize: 12)
        let first = NSStackView(views: [query, caseButton, wordButton, regexButton, include])
        let second = NSStackView(views: [replacement, replaceAll])
        for row in [first, second] { row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Search results")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let all = NSStackView(views: [first, second, summary, scroll])
        all.orientation = .vertical
        all.spacing = 4
        all.alignment = .leading
        all.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
            first.widthAnchor.constraint(equalTo: all.widthAnchor), second.widthAnchor.constraint(equalTo: all.widthAnchor), scroll.widthAnchor.constraint(equalTo: all.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusQuery(_ text: String?) {
        if let text, !text.isEmpty, !text.contains("\n") { query.stringValue = text }
        window?.makeFirstResponder(query)
        query.selectText(nil)
    }

    func show(_ results: SearchResults, scope: String?) {
        self.results = results
        groups = results.groups.map { SearchNode(path: $0.path, hits: $0.hits) }
        excludedPaths.formIntersection(groups.map(\.path))
        summary.stringValue = results.summary + (scope.map { " · in \($0)" } ?? "") + (replacementText.map { " · replacing with “\($0)”" } ?? "")
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func setHistory(_ queries: [String]) { query.recentSearches = queries }

    /// Leaves a file in or out of Replace All.
    func setIncluded(_ path: String, _ included: Bool) {
        if included { excludedPaths.remove(path) } else { excludedPaths.insert(path) }
        if let node = groups.first(where: { $0.path == path }) { outline.reloadItem(node) }
    }

    func setRegex(_ on: Bool) { regexButton.state = on ? .on : .off }

    /// Adds a note (what a replacement did) in front of the results summary.
    func appendSummary(_ note: String) { summary.stringValue = note + " · " + summary.stringValue }

    func showMessage(_ text: String) { summary.stringValue = text; groups = []; outline.reloadData() }

    @objc private func searchEntered() { onSearch() }
    func controlTextDidEndEditing(_ obj: Notification) { if (obj.object as? NSTextField) === include { onSearch() } }

    @objc private func replaceAllPressed() {
        onReplace(includedHits)
    }

    @objc private func toggleIncluded(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        setIncluded(path, sender.state == .on)
    }

    @objc private func replaceOne(_ sender: NSButton) {
        guard results.hits.indices.contains(sender.tag) else { return }
        onReplaceHit(results.hits[sender.tag])
    }

    @objc private func replaceInFile(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onReplace(results.hits.filter { $0.path == path })
    }

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? SearchNode else { return }
        if let hit = node.hit { onOpen(hit) } else if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SearchNode else { return groups.count }
        return node.hit == nil ? node.hits.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SearchNode else { return groups[index] }
        return SearchNode(hit: node.hits[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SearchNode)?.hit == nil }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SearchNode else { return nil }
        if let hit = node.hit {
            let number = NSTextField(labelWithString: String(hit.line + 1))
            number.textColor = .secondaryLabelColor
            number.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let text = NSTextField(labelWithAttributedString: Self.highlighted(hit))
            text.lineBreakMode = .byTruncatingTail
            let one = NSButton(title: "Replace", target: self, action: #selector(replaceOne(_:)))
            one.tag = results.hits.firstIndex(of: hit) ?? -1
            one.bezelStyle = .rounded
            one.controlSize = .mini
            one.toolTip = "Replace this match only"
            one.isHidden = replacement.stringValue.isEmpty
            let stack = NSStackView(views: [number, text, NSView(), one])
            stack.spacing = 10
            return stack
        }
        let name = NSTextField(labelWithString: node.path)
        name.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingHead
        let count = NSTextField(labelWithString: String(node.hits.count))
        count.textColor = .secondaryLabelColor
        let button = NSButton(title: "Replace in File", target: self, action: #selector(replaceInFile(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(node.path)
        button.bezelStyle = .rounded
        button.controlSize = .mini
        button.isHidden = replacement.stringValue.isEmpty
        let include = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleIncluded(_:)))
        include.identifier = NSUserInterfaceItemIdentifier(node.path)
        include.state = excludedPaths.contains(node.path) ? .off : .on
        include.toolTip = "Unchecked files are skipped by Replace All"
        include.setAccessibilityLabel("Include \(node.path) in Replace All")
        if excludedPaths.contains(node.path) { name.textColor = .secondaryLabelColor }
        let stack = NSStackView(views: [include, name, NSView(), count, button])
        stack.spacing = 8
        return stack
    }

    private static func highlighted(_ hit: SearchHit) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString(string: hit.text.trimmingLeadingSpaces(), attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let removed = hit.text.utf16.count - hit.text.trimmingLeadingSpaces().utf16.count
        let from = hit.start - hit.textStart - removed, length = hit.end - hit.start
        if from >= 0, from + length <= result.length {
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: NSRange(location: from, length: length))
        }
        return result
    }
}

private extension String {
    func trimmingLeadingSpaces() -> String { String(drop { $0 == " " || $0 == "\t" }) }
}
