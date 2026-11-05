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
    private let outline = ExplorerOutlineView()
    private let content = NSView()
    private let statusBar = StatusBarView()
    private let breadcrumb = BreadcrumbView()
    private let bottomPanel = BottomPanelView()
    private var diagnosticsByPath: [String: [LSPDiagnostic]] = [:]
    private var goVersion: String?
    private var branchName: String?
    private var connectedPaths: Set<String> = []
    private var panes: [String: EditorPane] = [:]
    private(set) var currentPane: EditorPane?
    private(set) var tabs = TabStrip()
    var tabTitles: [String] { tabBar.titles }
    /// Where the tabs are drawn, in the tab bar's coordinates, and the bar's own size.
    var tabFrames: [NSRect] { tabBar.itemFrames }
    var tabBarSize: NSSize { tabBar.bounds.size }

    /// Paints the window into a PNG (used by `--snapshot` in the project self-test).
    func snapshotWindow(to path: String) { WindowSnapshot.write(window, to: path) }
    private let tabBar = TabBarView()
    var explorerRowCount: Int { outline.numberOfRows }
    func explorerRowTitle(_ row: Int) -> String? { (outline.item(atRow: row) as? FileNode)?.url.lastPathComponent }
    /// What the status bar, breadcrumb and bottom panel show, for the self-test.
    var statusBarTexts: [String] { statusBar.texts }
    var breadcrumbText: String { breadcrumb.text }
    var problemCount: Int { bottomPanel.problemCount }
    var panelTabTitles: [String] { bottomPanel.tabTitles }
    var panelTabLayout: [(frame: NSRect, isCurrent: Bool)] { bottomPanel.tabLayout }
    var isBottomPanelVisible: Bool { !bottomPanel.isHidden }

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
        window?.delegate = self
        buildLayout()
        window?.center()
        // Restore the last size only after the layout and its minimum size exist, and refuse one that is too small to use
        // (an earlier layout could be saved collapsed).
        window?.setFrameAutosaveName("GobiProject")
        if let size = window?.contentLayoutRect.size, size.width < 760 || size.height < 480 {
            window?.setContentSize(NSSize(width: 1200, height: 780))
            window?.center()
        }
        loadToolFacts()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Auto Layout may pull a new window down to the layout's fitting size when it is first shown; the project window
    /// keeps the size it was given.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        if let size = window?.contentLayoutRect.size, size.width < 760 || size.height < 480 {
            window?.setContentSize(NSSize(width: 1200, height: 780))
            window?.center()
        }
    }

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
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Project files")
        outline.menuProvider = { [weak self] row in self?.explorerMenu(row: row) }
        outline.onJumpToSource = { [weak self] in self?.jumpToSourceOfSelection() }
        let sidebar = NSScrollView()
        sidebar.documentView = outline
        sidebar.hasVerticalScroller = true
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        content.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] path in self?.activate(path) }
        tabBar.onClose = { [weak self] path in self?.closeTab(path) }
        tabBar.menuProvider = { [weak self] path in self?.tabMenu(path: path) }
        let editorColumn = NSStackView(views: [tabBar, breadcrumb, content])
        editorColumn.orientation = .vertical
        editorColumn.spacing = 0
        editorColumn.alignment = .leading
        editorColumn.distribution = .fill
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for part in [tabBar, breadcrumb, content] { part.widthAnchor.constraint(equalTo: editorColumn.widthAnchor).isActive = true }

        bottomPanel.onOpenProblem = { [weak self] item in self?.open(problem: item) }
        let terminal = TerminalPane(root: root, trusted: isTrusted)
        terminal.onTrustRequested = { [weak self] in self?.onTrustRequested?() }
        terminalPane = terminal
        bottomPanel.install(terminal: terminal)
        bottomPanel.onTerminalShown = { [weak terminal] in terminal?.startIfNeeded() }
        bottomPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let centre = NSSplitView()
        centre.isVertical = false
        centre.dividerStyle = .thin
        centre.addArrangedSubview(editorColumn)
        centre.addArrangedSubview(bottomPanel)
        // The bottom panel keeps its height and the editor takes the spare. A holding priority above 500 on the editor
        // would make Auto Layout shrink the window instead of stretching the editor.
        centre.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        centre.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        bottomPanel.heightAnchor.constraint(equalToConstant: 210).isActive = true

        sidebarView = sidebar
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(centre)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let stack = NSStackView(views: [split, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        split.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // The split takes all spare height; the status bar and the bottom panel keep theirs.
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusBar.setContentHuggingPriority(.required, for: .vertical)
        editorColumn.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The window's content view follows the window by autoresizing, not constraints: pinned with constraints, the window
        // shrinks itself to the layout's fitting size when it is first shown.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))
        stack.translatesAutoresizingMaskIntoConstraints = true   // NSStackView turns this off by default
        stack.frame = container.bounds
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        window?.contentView = container
        window?.contentMinSize = NSSize(width: 760, height: 480)
        window?.setContentSize(NSSize(width: 1200, height: 780))   // the layout would otherwise shrink the window to its fitting size
        refreshChrome()
    }

    private var sidebarView: NSView?
    private var terminalPane: TerminalPane?
    /// Called when the user asks to trust this project from the Terminal tab.
    var onTrustRequested: (() -> Void)?
    var terminalSessionCount: Int { terminalPane?.sessionCount ?? 0 }
    var isTerminalNoticeShowing: Bool { terminalPane?.isShowingNotice ?? false }
    var terminalBackground: [Int]? { terminalPane?.background }
    func showTerminalTab() { bottomPanel.select(tab: 2) }
    var terminalText: String { terminalPane?.screenText ?? "" }
    func typeInTerminal(_ text: String) { terminalPane?.type(text) }
    func newTerminal() { terminalPane?.newTerminal() }
    func killTerminal() { terminalPane?.killSelected() }
    var terminalTitles: [String] { terminalPane?.titles ?? [] }

    func toggleSidebar() { sidebarView?.isHidden.toggle() }

    /// Saves every tab with unsaved edits.
    func saveAll() {
        for path in tabs.dirtyPaths { panes[path]?.save() }
    }

    /// Toggles the bottom panel (View > Toggle Bottom Panel, ⌘J).
    func toggleBottomPanel() { bottomPanel.isHidden.toggle() }

    // MARK: status bar, breadcrumb, problems

    private func loadToolFacts() {
        branchName = (try? String(contentsOf: root.appendingPathComponent(".git/HEAD"), encoding: .utf8)).flatMap { GitHead.branch($0) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let version = GoTool.version()
            DispatchQueue.main.async {
                self?.goVersion = version
                self?.refreshChrome()
            }
        }
    }

    /// Brings the status bar, breadcrumb and window title in line with the active file.
    private func refreshChrome() {
        let path = currentPane?.editorFile.fileURL.path
        let connected = path.map(connectedPaths.contains) ?? false
        statusBar.set(branch: branchName, gopls: StatusBar.goplsText(connected: connected, restricted: !isTrusted), go: goVersion)
        if let pane = currentPane {
            let position = pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location)
            let head = Array(pane.textView.string.utf16.prefix(65_536))
            statusBar.set(caret: StatusBar.caretText(line: position.line, column: position.character), lineEnding: LineEnding.detect(head))
            breadcrumb.show(segments: Breadcrumb.segments(projectRoot: root.path, file: pane.editorFile.fileURL.path))
        } else {
            statusBar.set(caret: nil, lineEnding: nil)
            breadcrumb.show(segments: [root.lastPathComponent])
        }
    }

    private func rebuildProblems() {
        var items: [ProblemItem] = []
        for path in tabs.paths {
            for diagnostic in diagnosticsByPath[path] ?? [] {
                items.append(ProblemItem(
                    severity: diagnostic.severity, message: diagnostic.message,
                    detail: StatusBar.problemDetail(path: StatusBar.relativePath(projectRoot: root.path, file: path), line: diagnostic.start.line, source: diagnostic.source),
                    path: path, line: diagnostic.start.line, character: diagnostic.start.character))
            }
        }
        items.sort { $0.severity < $1.severity }
        bottomPanel.setProblems(items)
    }

    private func open(problem: ProblemItem) {
        openFile(URL(fileURLWithPath: problem.path))
        currentPane?.reveal(line: problem.line, character: problem.character)
    }

    // MARK: opening files

    /// Opens `url` in a tab (or switches to its tab), reading it once and keeping its pane so switching back keeps
    /// edits and position.
    @discardableResult
    func openFile(_ url: URL) -> Bool {
        let path = url.path
        if panes[path] == nil {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                statusBar.set(note: "\(url.lastPathComponent) is not readable as UTF-8 text")
                return false
            }
            let pane = EditorPane(fileURL: url, text: text, embedsPanels: false)
            pane.trusted = isTrusted
            pane.editor.contextMenuProvider = { [weak self, weak pane] _ in pane.flatMap { self?.editorMenu(for: $0) } }
            pane.onDiagnostics = { [weak self] diagnostics in
                self?.diagnosticsByPath[path] = diagnostics
                self?.rebuildProblems()
            }
            pane.onStatus = { [weak self] text in if self?.currentPane?.editorFile.fileURL.path == path { self?.statusBar.set(note: text) } }
            pane.onConnected = { [weak self] in
                self?.connectedPaths.insert(path)
                self?.refreshChrome()
            }
            pane.onCaret = { [weak self] _, _ in if self?.currentPane?.editorFile.fileURL.path == path { self?.refreshChrome() } }
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
        statusBar.set(note: "")
        refreshChrome()
    }

    // MARK: right-click menus

    private func relativePath(_ url: URL) -> String { StatusBar.relativePath(projectRoot: root.path, file: url.path) }

    /// The editor's menu: definition and format run through gopls; reveal and copy path act on the file.
    func editorMenu(for pane: EditorPane) -> NSMenu {
        let url = pane.editorFile.fileURL
        var handlers: [String: () -> Void] = [
            "revealInFinder": { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            "copyPath": { ContextMenus.copyToPasteboard(url.path) },
        ]
        if pane.isConnected {
            handlers["goToDefinition"] = { [weak self] in self?.goToDefinition() }
            if !pane.editorFile.isReadOnlyByLineLength { handlers["formatDocument"] = { [weak pane] in pane?.formatDocument() } }
        }
        return ContextMenus.build(ContextMenuSpec.editor, handlers: handlers)
    }

    func explorerMenu(row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? FileNode else { return nil }
        let url = node.url
        var handlers: [String: () -> Void] = [
            "revealInFinder": { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            "copyPath": { ContextMenus.copyToPasteboard(url.path) },
            "copyRelativePath": { [weak self] in ContextMenus.copyToPasteboard(self?.relativePath(url) ?? url.path) },
            "copyFileName": { ContextMenus.copyToPasteboard(url.lastPathComponent) },
        ]
        if !node.isDirectory { handlers["open"] = { [weak self] in self?.openFile(url) } }
        else { handlers["open"] = { [weak self] in self?.outline.expandItem(node) } }
        // Go Mod Tidy and Download Go Modules run in a terminal, in the folder of the go.mod: the one selected, or the folder
        // selected when it holds one. Only a trusted project has a terminal.
        let moduleFolder = node.isDirectory ? url : (url.lastPathComponent == "go.mod" ? url.deletingLastPathComponent() : nil)
        if isTrusted, let folder = moduleFolder, FileManager.default.fileExists(atPath: folder.appendingPathComponent("go.mod").path) {
            handlers["goModTidy"] = { [weak self] in self?.runInTerminal("go mod tidy", inFolder: folder) }
            handlers["goModDownload"] = { [weak self] in self?.runInTerminal("go mod download", inFolder: folder) }
        }
        return ContextMenus.build(ContextMenuSpec.explorer, handlers: handlers)
    }

    func tabMenu(path: String) -> NSMenu {
        let url = URL(fileURLWithPath: path)
        let handlers: [String: () -> Void] = [
            "close": { [weak self] in self?.closeTab(path) },
            "closeOthers": { [weak self] in self?.closeTabs(except: path) },
            "closeToTheRight": { [weak self] in self?.closeTabs(after: path) },
            "copyPath": { ContextMenus.copyToPasteboard(path) },
            "revealInFinder": { NSWorkspace.shared.activateFileViewerSelecting([url]) },
        ]
        return ContextMenus.build(ContextMenuSpec.tab, handlers: handlers)
    }

    /// Shows the Terminal tab and runs `command` there, after changing to `folder`.
    func runInTerminal(_ command: String, inFolder folder: URL) {
        guard let line = ShellQuote.command(command, inFolder: folder.path) else { NSSound.beep(); return }
        bottomPanel.isHidden = false
        showTerminalTab()
        terminalPane?.run(line)
    }

    /// F4 in the explorer: open every selected file.
    func jumpToSourceOfSelection() {
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        openFiles(nodes.filter { !$0.isDirectory }.map(\.url))
    }

    /// Closes every other tab; a tab with unsaved edits asks first, and Cancel stops the rest.
    func closeTabs(except path: String) {
        for other in tabs.paths where other != path { if !closeTab(other) { return } }
    }

    func closeTabs(after path: String) {
        guard let index = tabs.paths.firstIndex(of: path) else { return }
        for other in Array(tabs.paths[(index + 1)...]) { if !closeTab(other) { return } }
    }

    // MARK: code help

    /// Go to Definition (F12): asks gopls and opens the answer in a tab, with the caret on the name.
    func goToDefinition() {
        currentPane?.goToDefinition { [weak self] location in
            guard let self, let location, let url = URL(string: location.uri), url.isFileURL else { NSSound.beep(); return }
            self.openFile(url)
            self.currentPane?.reveal(line: location.start.line, character: location.start.character)
        }
    }

    func formatDocument() { currentPane?.formatDocument() }

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
        diagnosticsByPath[path] = nil
        connectedPaths.remove(path)
        tabs.close(path)
        pane.view.removeFromSuperview()
        if let next = tabs.active, let nextPane = panes[next] {
            show(nextPane)
        } else {
            currentPane = nil
            window?.title = root.lastPathComponent
        }
        tabBar.reload(tabs)
        rebuildProblems()
        refreshChrome()
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
                image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: made.trailingAnchor, constant: -2),
            ])
            label.lineBreakMode = .byTruncatingTail
            return made
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        let kind = FileKind.classify(name: node.url.lastPathComponent, isDirectory: node.isDirectory)
        cell.imageView?.image = FileIcons.image(for: kind)
        cell.imageView?.setAccessibilityLabel(node.isDirectory ? "Folder" : "File")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Every selected file gets a tab, so shift- or command-clicking several files opens them all.
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }.filter { !$0.isDirectory }
        openFiles(selected.map(\.url))
    }
}
