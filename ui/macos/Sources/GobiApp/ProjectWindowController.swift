import AppKit
import GobiClient
import GobiModel
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
final class ProjectWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    let root: URL
    let kind: ProjectKind
    let isTrusted: Bool
    private let rootNode: FileNode
    private let outline = NSOutlineView()
    private let content = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var panes: [String: EditorPane] = [:]
    private(set) var currentPane: EditorPane?
    private(set) var tabs = TabStrip()
    var tabTitles: [String] { tabBar.titles }
    /// Where the tabs are drawn, in the tab bar's coordinates, and the bar's own size.
    var tabFrames: [NSRect] { tabBar.itemFrames }
    var tabBarSize: NSSize { tabBar.bounds.size }

    /// Paints the window's content into a PNG (used by `--snapshot` in the project self-test).
    func snapshotWindow(to path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
    private let tabBar = TabBarView()
    var explorerRowCount: Int { outline.numberOfRows }
    /// Distance in points from the window's left edge to the status text.
    var statusTextInset: CGFloat {
        window?.contentView?.layoutSubtreeIfNeeded()
        return statusLabel.convert(NSPoint.zero, to: nil).x
    }

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
        window?.delegate = self
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
        outline.allowsMultipleSelection = true
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
        tabBar.onSelect = { [weak self] path in self?.activate(path) }
        tabBar.onClose = { [weak self] path in self?.closeTab(path) }
        let editorColumn = NSStackView(views: [tabBar, content])
        editorColumn.orientation = .vertical
        editorColumn.spacing = 0
        editorColumn.alignment = .leading
        tabBar.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor).isActive = true
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(editorColumn)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let statusRow = NSStackView(views: [statusLabel])
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let stack = NSStackView(views: [split, statusRow])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        stack.alignment = .leading
        split.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        window?.contentView = stack
    }

    // MARK: opening files

    /// Opens `url` in a tab (or switches to its tab), reading it once and keeping its pane so switching back keeps
    /// edits and position.
    @discardableResult
    func openFile(_ url: URL) -> Bool {
        let path = url.path
        if panes[path] == nil {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                statusLabel.stringValue = "\(url.lastPathComponent) is not readable as UTF-8 text"
                return false
            }
            let pane = EditorPane(fileURL: url, text: text)
            pane.trusted = isTrusted
            pane.editorFile.onEditedChanged = { [weak self] edited in
                self?.tabs.setDirty(path, edited)
                self?.tabBar.reload(self?.tabs ?? TabStrip())
                self?.window?.isDocumentEdited = !(self?.tabs.dirtyPaths.isEmpty ?? true)
            }
            panes[path] = pane
            tabs.open(path)
            show(pane)
            pane.connect()
        } else {
            tabs.open(path)
            show(panes[path]!)
        }
        tabBar.reload(tabs)
        return true
    }

    /// Opens each file in its own tab; the last one ends up active. Files that cannot be read are skipped.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Int {
        urls.filter { openFile($0) }.count
    }

    func contains(_ url: URL) -> Bool { url.path.hasPrefix(root.path + "/") }

    private func activate(_ path: String) {
        guard let pane = panes[path] else { return }
        tabs.select(path)
        show(pane)
        tabBar.reload(tabs)
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

    // MARK: tabs, saving

    func selectNextTab() { tabs.selectNext(); if let path = tabs.active { activate(path) } }
    func selectPreviousTab() { tabs.selectPrevious(); if let path = tabs.active { activate(path) } }
    func closeCurrentTab() { if let path = tabs.active { closeTab(path) } }

    @discardableResult
    func saveCurrent() -> Bool { currentPane?.save() ?? true }

    /// Closes a tab; one with unsaved edits asks first. Returns false when the user cancels or a save fails.
    @discardableResult
    func closeTab(_ path: String) -> Bool {
        guard let pane = panes[path] else { return true }
        if tabs.isDirty(path) {
            switch askToSave(pane.editor.document.fileURL.lastPathComponent) {
            case .save: if !pane.save() { return false }
            case .discard: break
            case .cancel: return false
            }
        }
        pane.editorFile.client?.didClose(uri: pane.editorFile.uri)
        panes[path] = nil
        tabs.close(path)
        pane.view.removeFromSuperview()
        if let next = tabs.active, let nextPane = panes[next] {
            show(nextPane)
        } else {
            currentPane = nil
            window?.title = root.lastPathComponent
        }
        tabBar.reload(tabs)
        window?.isDocumentEdited = !tabs.dirtyPaths.isEmpty
        return true
    }

    private enum SaveAnswer { case save, discard, cancel }

    private func askToSave(_ name: String) -> SaveAnswer {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Closing the window asks about each tab with unsaved edits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for path in tabs.dirtyPaths where !closeTab(path) { return false }
        return true
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
        // Every selected file gets a tab, so shift- or command-clicking several files opens them all.
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }.filter { !$0.isDirectory }
        openFiles(selected.map(\.url))
    }
}
