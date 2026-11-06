import AppKit
import GobiModel

/// A variable in the Variables tree. Children are fetched from Delve the first time the row opens.
final class VariableNode {
    let variable: DebugVariable
    var children: [VariableNode]?
    init(_ variable: DebugVariable) { self.variable = variable }
}

/// The Debug tab of the bottom panel (Debug mock): Continue, Over, Into, Out, Restart and Stop, the variables of the selected
/// frame as a tree, and the Watch list.
final class DebugPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let variablesOutline = NSOutlineView()
    private let watchTable = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var buttons: [String: NSButton] = [:]
    private var roots: [VariableNode] = []
    private(set) var watchRows: [(expression: String, value: String)] = []
    var onAction: (String) -> Void = { _ in }
    /// Asked for the parts of a variable (its reference); the answer comes back on the main thread.
    var loadChildren: (Int, @escaping ([DebugVariable]) -> Void) -> Void = { _, done in done([]) }
    var onAddWatch: (String) -> Void = { _ in }
    var onRemoveWatch: (Int) -> Void = { _ in }

    var statusText: String { status.stringValue }
    var enabledActions: Set<String> { Set(buttons.filter { $0.value.isEnabled }.keys) }
    var variableNames: [String] { roots.map(\.variable.name) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let actions: [(id: String, symbol: String, label: String)] = [
            ("continue", "play.fill", "Continue"), ("over", "arrow.turn.down.right", "Step Over"), ("into", "arrow.down.to.line", "Step Into"),
            ("out", "arrow.up.to.line", "Step Out"), ("restart", "arrow.clockwise", "Restart"), ("stop", "stop.fill", "Stop"),
        ]
        let bar = NSStackView()
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        for action in actions {
            let button = FlatToolbarButton(symbol: action.symbol, label: action.label, tint: action.id == "stop" ? .systemRed : (action.id == "continue" ? .systemGreen : nil), action: #selector(pressed(_:)), target: self)
            button.identifier = NSUserInterfaceItemIdentifier(action.id)
            buttons[action.id] = button
            bar.addArrangedSubview(button)
        }
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 12)
        bar.addArrangedSubview(status)

        for (id, title, width) in [("name", "Variables", 150), ("type", "Type", 150), ("value", "Value", 300)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            variablesOutline.addTableColumn(column)
            if id == "name" { variablesOutline.outlineTableColumn = column }
        }
        variablesOutline.dataSource = self
        variablesOutline.delegate = self
        variablesOutline.rowHeight = 22
        variablesOutline.style = .plain
        variablesOutline.backgroundColor = .clear
        variablesOutline.setAccessibilityLabel("Variables")
        let left = NSScrollView()
        left.documentView = variablesOutline
        left.hasVerticalScroller = true
        left.drawsBackground = false

        for (id, title, width) in [("expression", "Watch", 150), ("result", "", 220)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            watchTable.addTableColumn(column)
        }
        watchTable.dataSource = self
        watchTable.delegate = self
        watchTable.rowHeight = 22
        watchTable.style = .plain
        watchTable.backgroundColor = .clear
        watchTable.setAccessibilityLabel("Watch")
        let watchScroll = NSScrollView()
        watchScroll.documentView = watchTable
        watchScroll.hasVerticalScroller = true
        watchScroll.drawsBackground = false
        let add = NSButton(title: "+ Add expression…", target: self, action: #selector(addWatchPressed))
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeWatchPressed))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        let watchButtons = NSStackView(views: [add, NSView(), remove])
        watchButtons.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        let right = NSStackView(views: [watchScroll, watchButtons])
        right.orientation = .vertical
        right.spacing = 0

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        let all = NSStackView(views: [bar, split])
        all.orientation = .vertical
        all.spacing = 0
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.widthAnchor.constraint(equalTo: all.widthAnchor), bar.widthAnchor.constraint(equalTo: all.widthAnchor),
            right.widthAnchor.constraint(equalToConstant: 380),
        ])
        update(state: .idle, project: "", variables: [], watches: [])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(state: DebugState, project: String, variables: [DebugVariable], watches: [(expression: String, value: String)]) {
        roots = variables.map(VariableNode.init)
        variablesOutline.reloadData()
        watchRows = watches
        watchTable.reloadData()
        status.stringValue = state.statusText(project: project)
        buttons["continue"]?.isEnabled = state.canStep
        for id in ["over", "into", "out"] { buttons[id]?.isEnabled = state.canStep }
        buttons["restart"]?.isEnabled = state.isActive
        buttons["stop"]?.isEnabled = state.isActive
    }

    @objc private func pressed(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onAction(id) } }

    @objc func addWatchPressed() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "len(errc) or s.srv.Addr"
        let alert = NSAlert()
        alert.messageText = "Add a watch expression"
        alert.informativeText = "It is evaluated in the selected frame each time the program pauses."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onAddWatch(field.stringValue)
    }

    @objc private func removeWatchPressed() { if watchTable.selectedRow >= 0 { onRemoveWatch(watchTable.selectedRow) } }

    // MARK: variables outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? VariableNode)?.children ?? (item == nil ? roots : [])).count }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? VariableNode)?.children ?? roots)[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? VariableNode).map { $0.variable.reference > 0 } ?? false }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? VariableNode, node.children == nil else { return }
        node.children = []
        loadChildren(node.variable.reference) { [weak self] loaded in
            node.children = loaded.map(VariableNode.init)
            self?.variablesOutline.reloadItem(node, reloadChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? VariableNode else { return nil }
        let text: String
        var colour = NSColor.labelColor
        switch tableColumn?.identifier.rawValue {
        case "name": text = node.variable.name
        case "type": text = node.variable.type; colour = .secondaryLabelColor
        default: text = node.variable.value
        }
        return Self.label(text, colour)
    }

    // MARK: watch table

    func numberOfRows(in tableView: NSTableView) -> Int { watchRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = watchRows[row]
        let isExpression = tableColumn?.identifier.rawValue == "expression"
        return Self.label(isExpression ? item.expression : item.value, isExpression ? .labelColor : (item.value.hasPrefix("error") ? .systemRed : .secondaryLabelColor))
    }

    private static func label(_ text: String, _ colour: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = colour
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return label
    }
}
