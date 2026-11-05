import AppKit
import GobiClient

/// Shown when no project is open: open a folder or file, or pick a recent project.
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var recents: [RecentProject] = []
    var onOpenFolder: (() -> Void)?
    var onNewProject: (() -> Void)?
    var onClone: (() -> Void)?
    var onImport: (() -> Void)?
    var onOpenRecent: ((RecentProject) -> Void)?

    init() {
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false))
        window?.title = "Welcome to Gobi"
        build()
        reload()
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        recents = ProjectStore.shared.recents.items
        table.reloadData()
    }

    private func build() {
        let title = NSTextField(labelWithString: "Gobi")
        title.font = NSFont.systemFont(ofSize: 34, weight: .bold)
        let subtitle = NSTextField(labelWithString: "A Go IDE on the official toolchain")
        subtitle.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open…", target: self, action: #selector(openPressed))
        open.keyEquivalent = "\r"
        open.bezelStyle = .rounded
        let create = NSButton(title: "New Project…", target: self, action: #selector(newPressed))
        let clone = NSButton(title: "Clone Repository…", target: self, action: #selector(clonePressed))
        let importCode = NSButton(title: "Import Existing Code…", target: self, action: #selector(importPressed))
        for button in [create, clone, importCode] { button.bezelStyle = .rounded }
        let hint = NSTextField(wrappingLabelWithString: "Choose a folder, a go.mod or a go.work. A folder you have not trusted opens in Restricted Mode.")
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 260
        let left = NSStackView(views: [title, subtitle, create, open, clone, importCode, hint])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12
        left.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 32, right: 24)
        left.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(recentDoubleClicked)
        table.setAccessibilityLabel("Recent projects")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let heading = NSTextField(labelWithString: "Recent projects")
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let right = NSStackView(views: [heading, scroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        scroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .top
        right.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        window?.contentView = row
    }

    @objc private func openPressed() { onOpenFolder?() }
    @objc private func newPressed() { onNewProject?() }
    @objc private func clonePressed() { onClone?() }
    @objc private func importPressed() { onImport?() }

    @objc private func recentDoubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < recents.count else { return }
        onOpenRecent?(recents[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = recents[row]
        let name = NSTextField(labelWithString: (project.path as NSString).lastPathComponent)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let path = NSTextField(labelWithString: (project.path as NSString).abbreviatingWithTildeInPath)
        path.textColor = .secondaryLabelColor
        path.font = NSFont.systemFont(ofSize: 11)
        path.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [name, path])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        return cell
    }
}
