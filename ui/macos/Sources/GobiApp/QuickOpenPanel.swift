import AppKit
import GobiModel

/// One row of the quick-open list: what it says, where it is, and what choosing it does.
struct QuickItem {
    var title: String
    var detail: String
    var symbol: String
    var shortcut: String = ""
    var run: () -> Void
}

/// A search field over a list, shown at the top of the project window: Go to File, the Command Palette and the symbol searches
/// all use it. `source` answers each query (synchronously or later); Return runs the selected row, Esc closes.
final class QuickOpenPanel: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let field = NSSearchField()
    private let table = NSTableView()
    private var items: [QuickItem] = []
    private var generation = 0
    /// Called with the query and a callback for the rows; the callback may run later (a symbol search waits for gopls).
    var source: ((String, @escaping ([QuickItem]) -> Void) -> Void)?

    var rowTitles: [String] { items.map(\.title) }
    var queryText: String { field.stringValue }

    init(placeholder: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        field.placeholderString = placeholder
        field.delegate = self
        field.font = NSFont.systemFont(ofSize: 16)
        field.focusRingType = .none
        field.setAccessibilityLabel(placeholder)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = 620
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(choose)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let stack = NSStackView(views: [field, scroll])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel near the top of `parent` and lists the answer for an empty query.
    func present(over parent: NSWindow) {
        field.stringValue = ""
        setFrameOrigin(NSPoint(x: parent.frame.midX - 310, y: parent.frame.maxY - 150))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        refresh()
    }

    func close(panel: Bool = true) {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func refresh() {
        generation += 1
        let mine = generation
        source?(field.stringValue) { [weak self] rows in
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { return }
                self.items = rows
                self.table.reloadData()
                if !rows.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
                let shown = min(max(rows.count, 1), 10)
                self.setContentSize(NSSize(width: 620, height: CGFloat(shown) * 30 + 62))
            }
        }
    }

    /// Runs the selected row (also how the self-test chooses).
    @objc func choose() {
        let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        close()
        item.run()
    }

    func setQuery(_ text: String) {
        field.stringValue = text
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max((table.selectedRow < 0 ? 0 : table.selectedRow) + delta, 0), items.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { close() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = NSTextField(labelWithString: item.title)
        title.font = NSFont.systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, title, NSView(), detail]
        if !item.shortcut.isEmpty {
            let shortcut = NSTextField(labelWithString: item.shortcut)
            shortcut.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            shortcut.textColor = .secondaryLabelColor
            views.append(shortcut)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.setAccessibilityLabel(item.title + (item.detail.isEmpty ? "" : ", " + item.detail))
        return stack
    }
}
