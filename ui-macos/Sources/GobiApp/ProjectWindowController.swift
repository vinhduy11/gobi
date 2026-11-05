import AppKit
import GobiClient
import GobiEditor

/// One node of the explorer: a file or folder, with children read from disk when first expanded.
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var children: [FileNode] {
        if let loaded { return loaded }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let entries = names.map { name -> (FileEntry, URL) in
            let child = url.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isFolder)
            return (FileEntry(name: name, isDirectory: isFolder.boolValue), child)
        }
        let urlByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.0.name, $0.1) })
        let nodes = FileTree.ordered(entries.map(\.0)).map { FileNode(url: urlByName[$0.name]!, isDirectory: $0.isDirectory) }
        loaded = nodes
        return nodes
    }
}

/// A project window: explorer on the left, the open file's editor on the right, a status line below.
final class ProjectWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let root: URL
    let kind: ProjectKind
    let isTrusted: Bool
    private let rootNode: FileNode
    private let outline = NSOutlineView()
    private let content = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var panes: [URL: EditorPane] = [:]
    private(set) var currentPane: EditorPane?
    var explorerRowCount: Int { outline.numberOfRows }

    init(root: URL, kind: ProjectKind, isTrusted: Bool) {
        self.root = root
        self.kind = kind
        self.isTrusted = isTrusted
        rootNode = FileNode(url: root, isDirectory: true)
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false))
        window?.title = root.lastPathComponent
        window?.subtitle = Self.describe(kind: kind, trusted: isTrusted)
        window?.setFrameAutosaveName("GobiProject")
        buildLayout()
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func describe(kind: ProjectKind, trusted: Bool) -> String {
        let label = kind == .workspace ? "Go workspace" : kind == .module ? "Go module" : "Folder"
        return trusted ? label : label + " · Restricted Mode"
    }

    private func buildLayout() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Project files")
        let sidebar = NSScrollView()
        sidebar.documentView = outline
        sidebar.hasVerticalScroller = true
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = Self.describe(kind: kind, trusted: isTrusted) + " · " + root.path

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        content.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let stack = NSStackView(views: [split, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 8)
        stack.alignment = .leading
        split.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        window?.contentView = stack
    }

    // MARK: opening files

    /// Shows `url` in the editor area, reading it once and keeping its pane so switching back keeps edits and position.
    @discardableResult
    func openFile(_ url: URL) -> Bool {
        if let pane = panes[url] { show(pane); return true }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusLabel.stringValue = "\(url.lastPathComponent) is not readable as UTF-8 text"
            return false
        }
        let pane = EditorPane(fileURL: url, text: text)
        pane.trusted = isTrusted
        panes[url] = pane
        show(pane)
        pane.connect()
        return true
    }

    private func show(_ pane: EditorPane) {
        currentPane?.view.removeFromSuperview()
        currentPane = pane
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: content.topAnchor), pane.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pane.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), pane.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window?.title = pane.editor.document.fileURL.lastPathComponent
        window?.makeFirstResponder(pane.textView)
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? rootNode).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? rootNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let made = NSTableCellView()
            made.identifier = identifier
            let image = NSImageView()
            let label = NSTextField(labelWithString: "")
            made.imageView = image
            made.textField = label
            for part in [image, label] { part.translatesAutoresizingMaskIntoConstraints = false; made.addSubview(part) }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: made.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: made.trailingAnchor, constant: -2),
            ])
            label.lineBreakMode = .byTruncatingTail
            return made
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc.text", accessibilityDescription: node.isDirectory ? "Folder" : "File")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory else { return }
        openFile(node.url)
    }
}
