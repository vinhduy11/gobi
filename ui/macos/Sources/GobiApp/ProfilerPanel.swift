import AppKit
import GobiEditor
import GobiModel

/// The icicle flame graph: the root on top, each function's children side by side below it, widths by cumulative cost.
final class FlameView: NSView {
    static let rowHeight: CGFloat = 20
    private(set) var rects: [FlameRect] = []
    private var nodes: [Int: ProfileNode] = [:]
    var selectedID: Int? { didSet { needsDisplay = true } }
    var onSelect: (Int) -> Void = { _ in }
    var unit = ""
    private var total = 1

    override var isFlipped: Bool { true }

    func show(_ data: ProfileData) {
        rects = FlameLayout.rects(data.nodes)
        nodes = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0) })
        total = max(1, data.total)
        unit = data.unit
        selectedID = nil
        let depth = (rects.map(\.depth).max() ?? 0) + 1
        frame.size.height = CGFloat(depth) * Self.rowHeight + 4
        needsDisplay = true
    }

    private func colour(for name: String) -> NSColor {
        var hash = 5381
        for scalar in name.unicodeScalars { hash = (hash &* 33 &+ Int(scalar.value)) & 0xFFFFFF }
        return NSColor(hue: 0.02 + CGFloat(hash % 100) / 100 * 0.12, saturation: 0.62, brightness: effectiveAppearance.name == .darkAqua ? 0.62 : 0.95, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        for rect in rects {
            let frame = NSRect(x: CGFloat(rect.x) * width, y: CGFloat(rect.depth) * Self.rowHeight + 2, width: CGFloat(rect.width) * width - 1, height: Self.rowHeight - 1)
            guard frame.width >= 1, frame.intersects(dirtyRect), let node = nodes[rect.id] else { continue }
            (rect.id == selectedID ? ThemeColors.accent : colour(for: node.name)).setFill()
            frame.fill()
            if frame.width > 40 {
                let label = rect.depth == 0 ? "all · \(ProfileFormat.value(node.cum, unit: unit)) · 100%" : node.name
                (label as NSString).draw(in: frame.insetBy(dx: 4, dy: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black.withAlphaComponent(0.85), .paragraphStyle: truncating])
            }
        }
    }

    private let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let depth = Int((point.y - 2) / Self.rowHeight)
        let fraction = Double(point.x / max(1, bounds.width))
        if let hit = rects.first(where: { $0.depth == depth && fraction >= $0.x && fraction < $0.x + $0.width }) {
            selectedID = hit.id
            onSelect(hit.id)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let depth = Int((point.y - 2) / Self.rowHeight)
        let fraction = Double(point.x / max(1, bounds.width))
        toolTip = rects.first(where: { $0.depth == depth && fraction >= $0.x && fraction < $0.x + $0.width }).flatMap { nodes[$0.id] }.map { "\($0.name)\n\(ProfileFormat.value($0.cum, unit: unit)) · \(ProfileFormat.percent($0.cum, of: total))" }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// The Profiler tab (Profiler mock): the profiles of the project, a flame graph or the Top table, and the selected frame.
final class ProfilerPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let list = NSTableView()
    private let flame = FlameView()
    private let flameScroll = NSScrollView()
    private let topTable = NSTableView()
    private let topScroll = NSScrollView()
    private let mode = NSSegmentedControl(labels: ["Flame", "Top", "Source"], trackingMode: .selectOne, target: nil, action: nil)
    private let sampleType = NSPopUpButton(frame: .zero, pullsDown: false)
    private let address = NSTextField(string: "localhost:6060")
    private let status = NSTextField(labelWithString: "")
    private let inspector = NSTextField(wrappingLabelWithString: "")
    private let openSource = NSButton(title: "", target: nil, action: nil)
    private(set) var data: ProfileData?
    private(set) var files: [URL] = []
    private let filterField = NSSearchField()
    private let compareButton = NSButton(title: "Compare…", target: nil, action: nil)
    private let sourceTable = NSTableView()
    private let sourceScroll = NSScrollView()
    private(set) var diff: ProfileDiff?
    private(set) var sourceRows: [(line: Int, text: String, cost: ProfileLineCost?)] = []
    private var sourceFile = ""
    private var sourceLines: ProfileLines?
    private let wholeFile = NSButton(checkboxWithTitle: "Show whole file", target: nil, action: nil)
    private var selectedNode: ProfileNode?
    /// Asks for the per-line cost of a function; answer with `show(lines:)`.
    var onRequestLines: (_ function: String) -> Void = { _ in }
    /// Asks the user for a second profile to compare with; answer with `show(diff:)`.
    var onCompare: () -> Void = {}
    var onOpenFile: (URL) -> Void = { _ in }
    var onSelectSample: (Int) -> Void = { _ in }
    var onCapture: (_ address: String, _ kind: String, _ seconds: Int) -> Void = { _, _, _ in }
    var onChooseFile: () -> Void = {}
    var onOpenSource: (_ file: String, _ line: Int) -> Void = { _, _ in }

    var statusText: String { status.stringValue }
    var inspectorText: String { inspector.stringValue }
    var filterText: String { filterField.stringValue }
    var visibleTop: [ProfileTopRow] { ProfileFilter.top(data?.top ?? [], query: filterField.stringValue) }
    var visibleDiff: [ProfileDiffRow] {
        guard let diff else { return [] }
        let names = Set(ProfileFilter.top(diff.rows.map { ProfileTopRow(name: $0.name, flat: 0, cum: 0) }, query: filterField.stringValue).map(\.name))
        return diff.rows.filter { names.contains($0.name) }
    }
    var topNames: [String] { diff == nil ? visibleTop.map(\.name) : visibleDiff.map(\.name) }
    var sourceCostLines: [Int] { sourceRows.filter { $0.cost != nil }.map(\.line) }
    var flameRectCount: Int { flame.rects.count }
    var isShowingFlame: Bool { !flameScroll.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setEnabled(false, forSegment: 2)
        sampleType.target = self
        sampleType.action = #selector(sampleChanged)
        address.placeholderString = "localhost:6060"
        address.controlSize = .small
        address.widthAnchor.constraint(equalToConstant: 130).isActive = true
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 12)
        let capture = NSPopUpButton(frame: .zero, pullsDown: true)
        capture.addItem(withTitle: "Capture")
        for (title, kind) in Self.presets {
            capture.menu?.addItem(withTitle: title, action: #selector(capturePreset(_:)), keyEquivalent: "").target = self
            capture.lastItem?.representedObject = kind
        }
        capture.controlSize = .small
        capture.setAccessibilityLabel("Capture a profile")
        let open = NSButton(title: "Open…", target: self, action: #selector(chooseFile))
        compareButton.target = self
        compareButton.action = #selector(comparePressed)
        for b in [open, compareButton] { b.controlSize = .small; b.bezelStyle = .rounded }
        filterField.placeholderString = "Filter frames"
        filterField.controlSize = .small
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.setAccessibilityLabel("Filter frames")
        filterField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        wholeFile.controlSize = .small
        wholeFile.target = self
        wholeFile.action = #selector(wholeFileToggled)
        wholeFile.isHidden = true
        let bar = NSStackView(views: [mode, wholeFile, sampleType, status, NSView(), filterField, NSTextField(labelWithString: "Live:"), address, capture, compareButton, open])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 22
        list.style = .plain
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.setAccessibilityLabel("Profiles")
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.widthAnchor.constraint(equalToConstant: 190).isActive = true

        flameScroll.documentView = flame
        flameScroll.hasVerticalScroller = true
        flameScroll.drawsBackground = false
        flame.autoresizingMask = [.width]
        flame.onSelect = { [weak self] id in self?.select(id: id) }

        for (id, title, width) in [("flat", "Flat", 80), ("flatp", "Flat %", 70), ("cum", "Cum", 80), ("cump", "Cum %", 70), ("name", "Function", 420)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            topTable.addTableColumn(c)
        }
        topTable.dataSource = self
        topTable.delegate = self
        topTable.rowHeight = 22
        topTable.style = .plain
        topTable.backgroundColor = .clear
        topTable.setAccessibilityLabel("Top functions")
        topScroll.documentView = topTable
        topScroll.hasVerticalScroller = true
        topScroll.drawsBackground = false
        topScroll.isHidden = true

        inspector.font = NSFont.systemFont(ofSize: 12)
        inspector.textColor = .secondaryLabelColor
        inspector.stringValue = "Open a profile, or capture one from a running program."
        openSource.isBordered = false
        openSource.contentTintColor = ThemeColors.accent
        openSource.target = self
        openSource.action = #selector(openSourcePressed)
        openSource.isHidden = true
        let side = NSStackView(views: [inspector, openSource])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        side.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        side.widthAnchor.constraint(equalToConstant: 250).isActive = true

        for (id, title, width) in [("sflat", "Flat", 80), ("scum", "Cum", 80), ("sline", "Line", 50), ("stext", "Source", 600)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            sourceTable.addTableColumn(column)
        }
        sourceTable.dataSource = self
        sourceTable.delegate = self
        sourceTable.rowHeight = 18
        sourceTable.style = .plain
        sourceTable.backgroundColor = .clear
        sourceTable.target = self
        sourceTable.doubleAction = #selector(sourceDoubleClicked)
        sourceTable.setAccessibilityLabel("Source with cost per line")
        sourceScroll.documentView = sourceTable
        sourceScroll.hasVerticalScroller = true
        sourceScroll.drawsBackground = false
        sourceScroll.isHidden = true

        let middle = NSStackView(views: [flameScroll, topScroll, sourceScroll])
        middle.orientation = .vertical
        middle.spacing = 0
        let body = NSStackView(views: [listScroll, middle, side])
        body.spacing = 0
        body.distribution = .fill
        body.alignment = .top
        for part in [listScroll, middle, side] { part.topAnchor.constraint(equalTo: body.topAnchor).isActive = true; part.bottomAnchor.constraint(equalTo: body.bottomAnchor).isActive = true }
        let all = NSStackView(views: [bar, body])
        all.orientation = .vertical
        all.spacing = 0
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: all.widthAnchor), body.widthAnchor.constraint(equalTo: all.widthAnchor), body.bottomAnchor.constraint(equalTo: all.bottomAnchor),
            flameScroll.widthAnchor.constraint(equalTo: middle.widthAnchor), topScroll.widthAnchor.constraint(equalTo: middle.widthAnchor), sourceScroll.widthAnchor.constraint(equalTo: middle.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(files: [URL], selected: URL?) {
        self.files = files
        list.reloadData()
        if let selected, let row = files.firstIndex(of: selected) { list.selectRowIndexes([row], byExtendingSelection: false) }
    }

    func show(profile: ProfileData, name: String) {
        data = profile
        clearDiff()
        sourceRows = []
        sourceLines = nil
        sourceTable.reloadData()
        applyFilter()
        sampleType.removeAllItems()
        sampleType.addItems(withTitles: profile.sampleTypes.map { $0.type + " (" + $0.unit + ")" })
        sampleType.selectItem(at: min(profile.index, max(0, profile.sampleTypes.count - 1)))
        let duration = profile.durationNanoseconds > 0 ? " · " + ProfileFormat.value(profile.durationNanoseconds, unit: "nanoseconds") : ""
        status.stringValue = "\(name)\(duration) · \(ProfileFormat.value(profile.total, unit: profile.unit))"
        inspector.stringValue = "Click a frame in the flame graph, or a row in Top."
        openSource.isHidden = true
        selectedNode = nil
    }

    func showMessage(_ text: String) { status.stringValue = text }

    /// Selects a frame by id: the inspector shows its cost, who called it and what it calls.
    func select(id: Int) {
        guard let data, let node = data.nodes.first(where: { $0.id == id }) else { return }
        selectedNode = node
        flame.selectedID = id
        mode.setEnabled(true, forSegment: 2)
        if mode.selectedSegment == 2 { onRequestLines(node.name) }
        let unit = data.unit
        var lines = [node.name,
                     "Flat: \(ProfileFormat.value(node.flat, unit: unit)) · \(ProfileFormat.percent(node.flat, of: data.total))",
                     "Cumulative: \(ProfileFormat.value(node.cum, unit: unit)) · \(ProfileFormat.percent(node.cum, of: data.total))"]
        if let caller = ProfileTree.caller(of: id, in: data.nodes) { lines += ["", "Called by", "\(caller.name)  \(ProfileFormat.percent(node.cum, of: caller.cum))"] }
        let callees = ProfileTree.callees(of: id, in: data.nodes)
        if !callees.isEmpty { lines += ["", "Calls"] + callees.prefix(5).map { "\($0.name)  \(ProfileFormat.percent($0.cum, of: node.cum))" } }
        inspector.stringValue = lines.joined(separator: "\n")
        openSource.isHidden = node.file.isEmpty
        openSource.title = node.file.isEmpty ? "" : "Open \((node.file as NSString).lastPathComponent):\(node.line)…"
    }

    @objc private func openSourcePressed() { if let node = selectedNode, !node.file.isEmpty { onOpenSource(node.file, node.line) } }
    @objc private func modeChanged() {
        flameScroll.isHidden = mode.selectedSegment != 0
        topScroll.isHidden = mode.selectedSegment != 1
        sourceScroll.isHidden = mode.selectedSegment != 2
        wholeFile.isHidden = mode.selectedSegment != 2
        if mode.selectedSegment == 2, let node = selectedNode { onRequestLines(node.name) }
    }

    @objc private func sourceDoubleClicked() {
        let row = sourceTable.clickedRow
        if sourceRows.indices.contains(row), !sourceFile.isEmpty { onOpenSource(sourceFile, sourceRows[row].line) }
    }

    /// Re-applies the filter box to the Top table and the flame graph.
    func applyFilter() {
        topTable.reloadData()
        if let profile = data {
            var shown = profile
            shown.nodes = ProfileFilter.nodes(profile.nodes, query: filterField.stringValue)
            flame.show(shown)
        }
    }

    func setFilter(_ query: String) { filterField.stringValue = query; applyFilter() }

    /// The source of the selected function (its declaration to its closing brace) with the cost of each line; the lines
    /// that cost something are marked. "Show whole file" lists the first 20000 lines of the file instead.
    func show(lines: ProfileLines) {
        sourceLines = lines
        sourceFile = lines.file
        rebuildSource()
    }

    var showsWholeFile: Bool { wholeFile.state == .on }
    func setWholeFile(_ on: Bool) { wholeFile.state = on ? .on : .off; rebuildSource() }
    @objc private func wholeFileToggled() { rebuildSource() }

    private func rebuildSource() {
        guard let lines = sourceLines else { return }
        let text = (try? String(contentsOfFile: lines.file, encoding: .utf8)) ?? ""
        let source = text.isEmpty ? [] : Array(text.components(separatedBy: "\n").prefix(20000))
        if source.isEmpty {
            sourceRows = lines.rows.map { (line: $0.line, text: "", cost: Optional($0)) }
        } else {
            var range = 1 ... source.count
            if !showsWholeFile, let first = lines.firstLine {
                let start = lines.startLine > 0 ? lines.startLine : GoFunctionRange.declaration(in: source, atOrBefore: first)
                if let start, let found = GoFunctionRange.lines(in: source, from: start) { range = found }
            }
            sourceRows = range.map { (line: $0, text: source[$0 - 1], cost: lines.cost(atLine: $0)) }
        }
        sourceTable.reloadData()
        if let first = lines.firstLine, let row = sourceRows.firstIndex(where: { $0.line == first }) { sourceTable.scrollRowToVisible(row) }
    }

    /// Switches the Top table to a comparison with another profile; Compare turns into Exit compare.
    func show(diff result: ProfileDiff, name: String) {
        diff = result
        compareButton.title = "Exit compare"
        for (id, title) in [("flat", "Δ Flat"), ("flatp", "Base"), ("cum", "New"), ("cump", "Δ Cum")] { topTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = title }
        mode.selectedSegment = 1
        modeChanged()
        topTable.reloadData()
        let unit = result.unit
        status.stringValue = "\(name): \(ProfileFormat.delta(result.newTotal - result.baseTotal, unit: unit)) \(result.type) vs the open profile"
    }

    func clearDiff() {
        diff = nil
        compareButton.title = "Compare…"
        for (id, title) in [("flat", "Flat"), ("flatp", "Flat %"), ("cum", "Cum"), ("cump", "Cum %")] { topTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = title }
        topTable.reloadData()
    }
    @objc private func sampleChanged() { onSelectSample(sampleType.indexOfSelectedItem) }
    /// The capture menu (Profiler mock): kind is the net/http/pprof endpoint name, as profile/capture takes it.
    static let presets: [(title: String, kind: String)] = [
        ("CPU 30 s", "cpu"), ("Heap", "heap"), ("Allocations", "allocs"), ("Goroutines", "goroutine"), ("Mutex contention", "mutex"), ("Blocking", "block"),
    ]
    @objc private func capturePreset(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        onCapture(address.stringValue, kind, kind == "cpu" ? 30 : 0)
    }
    @objc private func filterChanged() { applyFilter() }
    @objc private func comparePressed() {
        if diff != nil { clearDiff() } else { onCompare() }
    }
    @objc private func chooseFile() { onChooseFile() }

    func showSource() { mode.selectedSegment = 2; modeChanged() }

    /// What a double click on a source row does: opens the file at that line.
    func openSourceLine(_ line: Int) { if !sourceFile.isEmpty { onOpenSource(sourceFile, line) } }

    func showTop() { mode.selectedSegment = 1; modeChanged() }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === list { return files.count }
        if tableView === sourceTable { return sourceRows.count }
        return diff == nil ? visibleTop.count : visibleDiff.count
    }

    private func sourceCell(_ column: String, row: Int) -> NSView {
        let source = sourceRows[row]
        let unit = data?.unit ?? ""
        let flat = source.cost?.flat ?? 0, cum = source.cost?.cum ?? 0
        let text: String
        switch column {
        case "sflat": text = flat > 0 ? ProfileFormat.value(flat, unit: unit) : ""
        case "scum": text = cum > 0 ? ProfileFormat.value(cum, unit: unit) : ""
        case "sline": text = String(source.line)
        default: text = source.text
        }
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: source.cost == nil ? .regular : .semibold)
        label.lineBreakMode = .byTruncatingTail
        if source.cost != nil { label.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18); label.drawsBackground = true }
        return label
    }

    private func diffCell(_ column: String, _ row: ProfileDiffRow, unit: String) -> String {
        switch column {
        case "flat": return ProfileFormat.delta(row.flatDelta, unit: unit)
        case "flatp": return ProfileFormat.value(row.baseFlat, unit: unit)
        case "cum": return ProfileFormat.value(row.newFlat, unit: unit)
        case "cump": return ProfileFormat.delta(row.cumDelta, unit: unit)
        default: return row.name
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === list {
            let label = NSTextField(labelWithString: files[row].lastPathComponent)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
        if tableView === sourceTable { return sourceRows.indices.contains(row) ? sourceCell(tableColumn?.identifier.rawValue ?? "", row: row) : nil }
        if let diff {
            let rows = visibleDiff
            guard rows.indices.contains(row) else { return nil }
            let label = NSTextField(labelWithString: diffCell(tableColumn?.identifier.rawValue ?? "", rows[row], unit: diff.unit))
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        guard let profile = data, visibleTop.indices.contains(row) else { return nil }
        let top = visibleTop[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "flat": text = ProfileFormat.value(top.flat, unit: profile.unit)
        case "flatp": text = ProfileFormat.percent(top.flat, of: profile.total)
        case "cum": text = ProfileFormat.value(top.cum, unit: profile.unit)
        case "cump": text = ProfileFormat.percent(top.cum, of: profile.total)
        default: text = top.name
        }
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === list, list.selectedRow >= 0, files.indices.contains(list.selectedRow) { onOpenFile(files[list.selectedRow]) }
        let name = diff == nil ? visibleTop.indices.contains(topTable.selectedRow) ? visibleTop[topTable.selectedRow].name : nil
            : visibleDiff.indices.contains(topTable.selectedRow) ? visibleDiff[topTable.selectedRow].name : nil
        if table === topTable, let name, let node = data?.nodes.first(where: { $0.name == name }) { select(id: node.id) }
    }
}
