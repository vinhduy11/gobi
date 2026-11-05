import AppKit
import GobiModel

/// Help > Keyboard Shortcuts: every shortcut of the menu bar, from the same data the menus are built from, so the list cannot
/// drift from what the keys do. Items whose feature is not built yet are grey.
final class ShortcutsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let allRows = ShortcutList.rows()
    private var rows: [ShortcutRow]
    private let table = NSTableView()
    private let search = NSSearchField()

    var shownCount: Int { rows.count }

    init() {
        rows = allRows
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false))
        window?.title = "Keyboard Shortcuts"
        build()
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        search.placeholderString = "Search"
        search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        for (identifier, title, width) in [("title", "Command", 240.0), ("menu", "Menu", 190.0), ("shortcut", "Shortcut", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        window?.contentView = stack
    }

    func controlTextDidChange(_ notification: Notification) {
        let needle = search.stringValue.lowercased()
        rows = needle.isEmpty ? allRows : allRows.filter { ($0.title + " " + $0.menu + " " + $0.shortcut).lowercased().contains(needle) }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text = tableColumn?.identifier.rawValue == "title" ? item.title : tableColumn?.identifier.rawValue == "menu" ? item.menu : item.shortcut
        let label = NSTextField(labelWithString: text)
        label.textColor = item.isAvailable ? .labelColor : .tertiaryLabelColor
        if tableColumn?.identifier.rawValue == "shortcut" { label.font = NSFont.systemFont(ofSize: 13, weight: .medium) }
        return label
    }
}
