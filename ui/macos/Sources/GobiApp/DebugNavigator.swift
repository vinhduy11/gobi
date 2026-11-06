import AppKit
import GobiModel

/// The left navigator while debugging (Debug mock): the call stack, the goroutines and the list of breakpoints.
final class DebugNavigatorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct BreakpointRow: Equatable { let path: String; let line: Int; let condition: String? }

    private let stackTable = NSTableView()
    private let threadsTable = NSTableView()
    private let breakpointsTable = NSTableView()
    private let threadsHeader = NSTextField(labelWithString: "GOROUTINES")
    private(set) var frames: [DebugFrame] = []
    private(set) var threads: [DebugThread] = []
    private(set) var breakpointRows: [BreakpointRow] = []
    private var selectedFrame = 0
    private var selectedThread = 0
    private var isUpdating = false
    var onSelectFrame: (Int) -> Void = { _ in }
    var onSelectThread: (Int) -> Void = { _ in }
    var onOpenBreakpoint: (String, Int) -> Void = { _, _ in }
    var onRemoveBreakpoint: (String, Int) -> Void = { _, _ in }

    var frameTitles: [String] { frames.map { $0.title + " " + $0.location } }
    var threadTitles: [String] { threads.map(\.title) }
    var threadsHeaderText: String { threadsHeader.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        func section(_ title: String, _ table: NSTableView, height: CGFloat?) -> [NSView] {
            let header = NSTextField(labelWithString: title)
            header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 22
            table.style = .plain
            table.backgroundColor = .clear
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel(title.capitalized)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            if let height { scroll.heightAnchor.constraint(equalToConstant: height).isActive = true }
            return [header, scroll]
        }
        var views = section("CALL STACK", stackTable, height: 150)
        threadsHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        threadsHeader.textColor = .secondaryLabelColor
        let threadsParts = section("GOROUTINES", threadsTable, height: 130)
        views += [threadsHeader, threadsParts[1]]
        views += section("BREAKPOINTS", breakpointsTable, height: nil)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in stack.arrangedSubviews where view is NSScrollView { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        breakpointsTable.doubleAction = #selector(breakpointOpened)
        breakpointsTable.target = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(frames: [DebugFrame], selectedFrame: Int, threads: [DebugThread], selectedThread: Int, breakpoints: [BreakpointRow]) {
        isUpdating = true
        defer { isUpdating = false }
        self.frames = frames
        self.threads = threads
        self.breakpointRows = breakpoints
        self.selectedFrame = selectedFrame
        self.selectedThread = selectedThread
        threadsHeader.stringValue = "GOROUTINES (\(threads.count))"
        for table in [stackTable, threadsTable, breakpointsTable] { table.reloadData() }
        if frames.indices.contains(selectedFrame) { stackTable.selectRowIndexes([selectedFrame], byExtendingSelection: false) }
        if let row = threads.firstIndex(where: { $0.id == selectedThread }) { threadsTable.selectRowIndexes([row], byExtendingSelection: false) }
    }

    @objc private func breakpointOpened() {
        guard breakpointsTable.clickedRow >= 0, breakpointRows.indices.contains(breakpointsTable.clickedRow) else { return }
        let row = breakpointRows[breakpointsTable.clickedRow]
        onOpenBreakpoint(row.path, row.line)
    }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === stackTable ? frames.count : (tableView === threadsTable ? threads.count : breakpointRows.count)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let left: String
        var right = ""
        var marker: NSColor?
        if tableView === stackTable { left = frames[row].title; right = frames[row].location }
        else if tableView === threadsTable { left = threads[row].title; right = "#\(threads[row].id)" }
        else {
            let item = breakpointRows[row]
            left = (item.path as NSString).lastPathComponent + ":" + String(item.line)
            right = item.condition ?? ""
            marker = item.condition == nil ? .systemRed : .systemOrange
        }
        let name = NSTextField(labelWithString: left)
        name.lineBreakMode = .byTruncatingTail
        name.font = NSFont.systemFont(ofSize: 12)
        let detail = NSTextField(labelWithString: right)
        detail.textColor = .secondaryLabelColor
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = []
        if let marker {
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = marker
            views.append(dot)
        }
        views += [name, NSView(), detail]
        let stack = NSStackView(views: views)
        stack.spacing = 6
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, let table = notification.object as? NSTableView, table.selectedRow >= 0 else { return }
        if table === stackTable { onSelectFrame(table.selectedRow) }
        else if table === threadsTable, threads.indices.contains(table.selectedRow) { onSelectThread(threads[table.selectedRow].id) }
    }
}
