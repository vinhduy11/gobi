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

    /// Forgets the folder listing (all the way down) so the next read goes to the disk.
    func invalidate() {
        loaded?.forEach { $0.invalidate() }
        loaded = nil
    }

    var children: [FileNode] {
        if let loaded { return loaded }
        let nodes = readChildren(reusing: [:])
        loaded = nodes
        return nodes
    }

    private func readChildren(reusing known: [String: FileNode]) -> [FileNode] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let entries = names.map { name -> (FileEntry, URL) in
            let child = url.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isFolder)
            return (FileEntry(name: name, isDirectory: isFolder.boolValue), child)
        }
        let urlByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.0.name, $0.1) })
        return FileTree.ordered(entries.map(\.0)).map { entry in
            if let node = known[entry.name], node.isDirectory == entry.isDirectory { return node }
            return FileNode(url: urlByName[entry.name]!, isDirectory: entry.isDirectory)
        }
    }

    /// Reads the folders that were already listed again, keeping the nodes of names that are still there (so the explorer keeps
    /// what is expanded). True when any listing changed.
    @discardableResult
    func refresh() -> Bool {
        guard let old = loaded else { return false }
        var changed = false
        let fresh = readChildren(reusing: Dictionary(uniqueKeysWithValues: old.map { ($0.url.lastPathComponent, $0) }))
        if fresh.map(\.url) != old.map(\.url) || zip(fresh, old).contains(where: { $0 !== $1 }) { changed = true }
        loaded = fresh
        for child in fresh where child.isDirectory { if child.refresh() { changed = true } }
        return changed
    }
}

/// A project window: explorer on the left, the open file's editor on the right, a status line below.
final class ProjectWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    let root: URL
    let kind: ProjectKind
    let isTrusted: Bool
    private let rootNode: FileNode
    let outline = ExplorerOutlineView()
    private let content = NSView()
    let statusBar = StatusBarView()
    private let breadcrumb = BreadcrumbView()
    let bottomPanel = BottomPanelView()
    private var diagnosticsByPath: [String: [LSPDiagnostic]] = [:]
    private var goVersion: String?
    private var branchName: String?
    private var gitClient: GitClient?
    /// Which Go this project uses (Auto, or a pinned version), the Go versions found on this machine, and what that resolves to.
    private(set) var toolchainSelection = ToolchainSelection()
    private(set) var goInstalls: [GoInstall] = []
    private(set) var gitStatus: GitStatus?
    private var connectedPaths: Set<String> = []
    var panes: [String: EditorPane] = [:]
    /// The last code lens part clicked, and how many places the last Find References / Go to Implementation listed. The
    /// self-test reads them; it also turns the pop-up list off (a pop-up menu would hold the run loop).
    var lastLensAction: LensAction?
    var lastListedLocations = 0
    var presentsLocationMenus = true
    private(set) var currentPane: EditorPane?
    var tabs = TabStrip()
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
        environments = ProjectEnvironments(root: root)
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false))
        window?.title = root.lastPathComponent
        window?.subtitle = Self.describe(kind: kind, trusted: isTrusted)
        window?.delegate = self
        buildLayout()
        toolbar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        toolbar.onToggleInspector = { [weak self] in self?.toggleInspector() }
        toolbar.onRun = { [weak self] in self?.runProject() }
        toolbar.onDebug = { [weak self] in self?.startDebugging() }
        toolbar.moreMenu = { [weak self] in self?.moreRunMenu() }
        findPanel.onSearch = { [weak self] in self?.runSearch() }
        findPanel.onOpen = { [weak self] hit in self?.open(hit: hit) }
        findPanel.onReplace = { [weak self] hits in self?.replace(hits: hits) }
        findPanel.onReplaceHit = { [weak self] hit in self?.replace(hits: [hit], exact: true) }
        findPanel.setHistory(UserDefaults.standard.stringArray(forKey: Self.findHistoryKey) ?? [])
        NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.outline.reloadData()
            self?.updateGitMarks()
        }
        toolbar.environmentMenu = { [weak self] in self?.environmentMenu() }
        toolbar.branchMenu = { [weak self] in self?.branchMenu() }
        sourceControl.onCommit = { [weak self] in self?.commitChanges() }
        sourceControl.onShowDiff = { [weak self] path in self?.showDiff(path: path) }
        sourceControl.onOpen = { [weak self] path in self?.openFile(self?.root.appendingPathComponent(path) ?? URL(fileURLWithPath: path)) }
        commitPanel.onRefresh = { [weak self] in self?.refreshGit(); self?.loadLog() }
        commitPanel.onRollback = { [weak self] path in self?.discardChanges(path) }
        commitPanel.onPull = { [weak self] in self?.pullChanges() }
        commitPanel.onShowDiff = { [weak self] path in self?.showDiff(path: path) }
        commitPanel.onToggle = { [weak self] toggle in self?.applyToggle(toggle) }
        commitPanel.onCommit = { [weak self] message, amend, push in self?.commit(message: message, stageAll: nil, amend: amend, push: push) }
        commitPanel.onAmend = { [weak self] on in self?.amendChanged(on) }
        commitPanel.onSettings = { NSApp.sendAction(#selector(AppDelegate.showGitSettings(_:)), to: nil, from: nil) }
        commitPanel.onModeChanged = { [weak self] _ in self?.loadLog() }
        commitPanel.onStashNew = { [weak self] in self?.stashChanges() }
        commitPanel.onStashApply = { [weak self] index in self?.gitOperation(.stashApply(index), title: "Stash applied", reloadFiles: true) }
        commitPanel.onStashPop = { [weak self] index in self?.gitOperation(.stashPop(index), title: "Stash applied and dropped", reloadFiles: true) }
        commitPanel.onStashDrop = { [weak self] index in self?.confirmDropStash(index) }
        profilerPanel.onOpenFile = { [weak self] url in self?.loadProfile(url) }
        profilerPanel.onSelectSample = { [weak self] index in if let url = self?.profileURL { self?.profileSample = index; self?.loadProfile(url, sample: index) } }
        profilerPanel.onCapture = { [weak self] address, kind, seconds in self?.captureProfile(address: address, kind: kind, seconds: seconds) }
        profilerPanel.onChooseFile = { [weak self] in self?.chooseProfile() }
        profilerPanel.onRequestLines = { [weak self] function in self?.loadProfileLines(function) }
        profilerPanel.onCompare = { [weak self] in self?.chooseProfileToCompare() }
        profilerPanel.onOpenSource = { [weak self] file, line in
            guard let self, FileManager.default.fileExists(atPath: file) else { return }
            self.openFile(URL(fileURLWithPath: file))
            self.currentPane?.reveal(line: max(0, line - 1), character: 0)
        }
        debugPanel.onAction = { [weak self] id in self?.debugAction(id) }
        debugNavigator.onSelectFrame = { [weak self] index in self?.debugSession?.select(frame: index) }
        debugNavigator.onSelectThread = { [weak self] id in self?.debugSession?.select(thread: id) }
        debugNavigator.onOpenBreakpoint = { [weak self] path, line in self?.openFile(URL(fileURLWithPath: path)); self?.currentPane?.reveal(line: line - 1, character: 0) }
        debugPanel.loadChildren = { [weak self] reference, done in
            if let session = self?.debugSession { session.children(of: reference, completion: done) } else { done([]) }
        }
        debugPanel.onAddWatch = { [weak self] expression in self?.addWatch(expression) }
        debugPanel.onRemoveWatch = { [weak self] index in self?.removeWatch(at: index) }
        toolbar.toolchainMenu = { [weak self] in self?.toolchainMenu() }
        toolbar.projectMenu = { [weak self] in self?.projectMenu() }
        toolbar.onStop = { [weak self] in self?.stopRun() }
        toolbar.onSearch = { [weak self] in self?.commandPalette { action in if let delegate = NSApp.delegate as? AppDelegate { MainMenuBuilder.perform(action: action, delegate: delegate) } } }
        if let window { toolbar.install(in: window) }
        window?.center()
        // Restore the last size only after the layout and its minimum size exist, and refuse one that is too small to use
        // (an earlier layout could be saved collapsed).
        window?.setFrameAutosaveName("GobiProject")
        if let size = window?.contentLayoutRect.size, size.width < 760 || size.height < 480 {
            window?.setContentSize(NSSize(width: 1200, height: 780))
            window?.center()
        }
        toolchainSelection = ToolchainSelection.decode(UserDefaults.standard.string(forKey: toolchainKey) ?? "")
        loadBreakpoints()
        watches = WatchList.decode(UserDefaults.standard.string(forKey: "gobi.watches." + root.path) ?? "")
        loadToolFacts()
        loadGoInstalls()
        loadModuleFacts()
        refreshGit()
        startAutoFetch()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Auto Layout may pull a new window down to the layout's fitting size when it is first shown; the project window
    /// keeps the size it was given.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        placeCentreDivider()
        if let size = window?.contentLayoutRect.size, size.width < 760 || size.height < 480 {
            window?.setContentSize(NSSize(width: 1200, height: 780))
            window?.center()
        }
        window?.layoutIfNeeded()
        placeCentreDivider()
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
        outline.target = self
        outline.doubleAction = #selector(explorerDoubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.onJumpToSource = { [weak self] in self?.jumpToSourceOfSelection() }
        outline.onCut = { [weak self] in if let self { self.copyToClipboard(self.selectedURLs(), cut: true) } }
        outline.onCopy = { [weak self] in if let self { self.copyToClipboard(self.selectedURLs(), cut: false) } }
        outline.onPaste = { [weak self] in self?.pasteIntoSelection() }
        outline.onDelete = { [weak self] in if let self { self.deleteItems(self.selectedURLs()) } }
        outline.onRename = { [weak self] in if let self, let url = self.selectedURLs().first, self.selectedURLs().count == 1 { self.renameItem(url) } }
        outline.onMove = { [weak self] in if let self { self.moveWithSheet(self.selectedURLs()) } }
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
        terminal.onOpenSettings = { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
        terminal.onTrustRequested = { [weak self] in self?.onTrustRequested?() }
        terminalPane = terminal
        bottomPanel.install(terminal: terminal)
        bottomPanel.onTerminalShown = { [weak terminal] in terminal?.startIfNeeded() }
        bottomPanel.install(testsPanel, forTab: 1)
        bottomPanel.install(debugPanel, forTab: 3)
        bottomPanel.install(profilerPanel, forTab: 4)
        bottomPanel.install(diffPanel, forTab: 5)
        bottomPanel.install(findPanel, forTab: 7)
        bottomPanel.install(outputPanel, forTab: 6)
        testsPanel.onRunAll = { [weak self] in self?.runTests() }
        testsPanel.onRunFailed = { [weak self] in self?.rerunFailed() }
        outputPanel.onStop = { [weak self] in self?.stopRun() }
        outputPanel.onOpenReference = { [weak self] in self?.open(reference: $0) }
        testsPanel.onOpenReference = { [weak self] in self?.open(reference: $0) }
        bottomPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let centre = NSSplitView()
        centre.isVertical = false
        centre.dividerStyle = .thin
        centre.addArrangedSubview(editorColumn)
        centre.addArrangedSubview(bottomPanel)
        // The bottom panel keeps its height and the editor takes the spare. A holding priority above 500 on the editor
        // would make Auto Layout shrink the window instead of stretching the editor.
        centre.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        centre.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 1)   // above 250 keeps its height on window resize, below 500 still lets the divider move it
        centre.autosaveName = "gobi.centreSplit"
        bottomPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        editorColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        centreSplit = centre

        // Left: Files, Symbols and Tests tabs; right: the inspector.
        let symbolsList = OutlineListView()
        symbolsList.onSelect = { [weak self] symbol in self?.currentPane?.reveal(line: symbol.line, character: 0) }
        sidebarSymbols = symbolsList
        let sidebarTests = TestsPanelView()
        sidebarTests.onRunAll = { [weak self] in self?.runTests() }
        sidebarTests.onRunFailed = { [weak self] in self?.rerunFailed() }
        sidebarTestsPanel = sidebarTests
        let tabsControl = NSSegmentedControl(labels: ["Files", "Symbols", "Tests", "Debug", ""], trackingMode: .selectOne, target: self, action: #selector(sidebarTabChanged(_:)))
        tabsControl.selectedSegment = 0
        tabsControl.segmentStyle = .texturedRounded
        // Five text labels do not fit 260 pt, so the Commit tab is an icon (Commit mock).
        tabsControl.setImage(NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Commit"), forSegment: 4)
        tabsControl.setToolTip("Commit", forSegment: 4)
        tabsControl.setWidth(30, forSegment: 4)
        tabsControl.controlSize = .small
        tabsControl.setAccessibilityLabel("Sidebar")
        // The explorer above, the Source control block below, with a divider to drag so the block can be made taller.
        let filesColumn = NSSplitView()
        filesColumn.isVertical = false
        filesColumn.dividerStyle = .thin
        filesColumn.autosaveName = "gobi.filesSplit"
        filesColumn.addArrangedSubview(sidebar)
        filesColumn.addArrangedSubview(sourceControl)
        filesColumn.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        filesColumn.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 1)
        sidebar.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sourceControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        sourceControl.isHidden = true
        filesSplit = filesColumn
        sidebarTabs = [filesColumn, symbolsList, sidebarTests, debugNavigator, commitPanel]
        symbolsList.isHidden = true
        sidebarTests.isHidden = true
        debugNavigator.isHidden = true
        commitPanel.isHidden = true
        sidebarTabControl = tabsControl
        let sidebarColumn = NSStackView(views: [tabsControl, filesColumn, symbolsList, sidebarTests, debugNavigator, commitPanel])
        sidebarColumn.orientation = .vertical
        sidebarColumn.spacing = 6
        sidebarColumn.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        sidebarColumn.distribution = .fill
        for part in [filesColumn, symbolsList, sidebarTests, debugNavigator, commitPanel] { part.widthAnchor.constraint(equalTo: sidebarColumn.widthAnchor).isActive = true; part.setContentHuggingPriority(.defaultLow, for: .vertical) }
        tabsControl.widthAnchor.constraint(equalTo: sidebarColumn.widthAnchor, constant: -16).isActive = true
        sidebarView = sidebarColumn
        inspector.outline.onSelect = { [weak self] symbol in self?.currentPane?.reveal(line: symbol.line, character: 0) }
        split.addArrangedSubview(sidebarColumn)
        split.addArrangedSubview(centre)
        split.addArrangedSubview(inspector)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        sidebarColumn.widthAnchor.constraint(equalToConstant: 260).isActive = true
        inspector.widthAnchor.constraint(equalToConstant: 250).isActive = true

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

    var sidebarView: NSView?
    private let inspector = InspectorView()
    private let toolbar = ProjectToolbar()
    private var sidebarTabs: [NSView] = []
    private var sidebarSymbols: OutlineListView?
    private var sidebarTestsPanel: TestsPanelView?
    private var outlineTimer: Timer?
    private var moduleFacts: GoModFacts?
    var quickOpen: QuickOpenPanel?
    let outputPanel = OutputPanelView()
    private let testsPanel = TestsPanelView()
    let debugPanel = DebugPanelView()
    private let debugNavigator = DebugNavigatorView()
    private let profilerPanel = ProfilerPanelView()
    private let sourceControl = SourceControlView()
    private var filesSplit: NSSplitView?
    private var centreSplit: NSSplitView?
    private var placedCentreDivider = false
    private var placedFilesDivider = false

    /// The first time the Source control block shows, and when the person has not moved the divider before, it gets a useful height.
    private func placeFilesDivider() {
        guard !placedFilesDivider, let split = filesSplit, !sourceControl.isHidden, split.bounds.height > 400 else { return }
        placedFilesDivider = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames gobi.filesSplit") != nil { return }
        split.setPosition(split.bounds.height - 240, ofDividerAt: 0)
    }

    /// The bottom panel starts 210 pt tall unless the person has dragged the divider before (the position is remembered).
    private func placeCentreDivider() {
        guard !placedCentreDivider, let split = centreSplit, split.bounds.height > 400 else { return }
        placedCentreDivider = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames gobi.centreSplit") != nil { return }
        split.setPosition(split.bounds.height - 210, ofDividerAt: 0)
    }

    /// For tests: the bottom panel's height, and moving its divider the way a drag would.
    var bottomPanelHeight: CGFloat {
        centreSplit?.layoutSubtreeIfNeeded()
        return bottomPanel.isHidden ? 0 : bottomPanel.frame.height
    }
    func moveCentreDivider(toBottomHeight height: CGFloat) {
        guard let split = centreSplit else { return }
        split.setPosition(split.bounds.height - height, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }

    /// For tests: how tall the Source control block is, and moving the divider the way a drag would.
    var sourceControlHeight: CGFloat {
        filesSplit?.layoutSubtreeIfNeeded()
        return sourceControl.isHidden ? 0 : sourceControl.frame.height
    }
    func moveFilesDivider(toBlockHeight height: CGFloat) {
        guard let split = filesSplit else { return }
        split.setPosition(split.bounds.height - height, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }
    private let findPanel = FindInFilesPanelView()
    /// Files that have an error among their problems; the Explorer marks them with a red !.
    private var errorPaths = Set<String>()
    private var searchToken = 0
    private var searchScope: String?
    let diffPanel = DiffPanelView()
    let commitPanel = CommitPanelView()
    private(set) var gitBranches: [GitBranch] = []
    private var gutterMarks: [String: [GitLineChange]] = [:]
    let environments: ProjectEnvironments
    /// Replaces the question about non-local services (the self-tests answer it).
    var confirmNonLocal: (([EnvTarget]) -> Bool)?
    private var profileURL: URL?
    private var profileSample: Int?
    private var sidebarTabControl: NSSegmentedControl?
    private(set) var watches = WatchList()
    var breakpoints = Breakpoints()
    private var debugSession: DebugSession?
    private var runClient: RunClient?
    private var fetchTimer: Timer?
    var lastFetch = Date()
    private var results = TestResults()
    private var runStarted = Date()
    private var refreshScheduled = false
    private(set) var isRunning = false { didSet { toolbar.set(running: isRunning) } }
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
    func toggleInspector() { inspector.isHidden.toggle() }
    var isInspectorHidden: Bool { inspector.isHidden }
    func setInspector(hidden: Bool) { inspector.isHidden = hidden }
    var isInspectorVisible: Bool { !inspector.isHidden }

    @objc private func sidebarTabChanged(_ sender: NSSegmentedControl) {
        for (index, view) in sidebarTabs.enumerated() { view.isHidden = index != sender.selectedSegment }
    }

    /// Which sidebar tab is showing (0 Files, 1 Symbols, 2 Tests), and a way to switch, for the self-test.
    var sidebarTabIndex: Int { sidebarTabs.firstIndex { !$0.isHidden } ?? 0 }
    func selectSidebarTab(_ index: Int) {
        guard sidebarTabs.indices.contains(index) else { return }
        sidebarTabControl?.selectedSegment = index
        for (position, view) in sidebarTabs.enumerated() { view.isHidden = position != index }
    }
    /// True when the segmented control sits inside the sidebar column (it is not pushed wider than the 260 pt sidebar). Its natural
    /// width (about 258 pt at the small control size) is more than the room, so AppKit squeezes the segments; the snapshot shows
    /// every label whole.
    var sidebarTabsFit: Bool {
        guard let control = sidebarTabControl, let column = sidebarView else { return false }
        window?.contentView?.layoutSubtreeIfNeeded()
        return control.frame.minX >= 0 && control.frame.maxX <= column.bounds.width
    }
    var sidebarTabsWidths: String {
        guard let control = sidebarTabControl, let column = sidebarView else { return "none" }
        return "control \(Int(control.frame.minX))...\(Int(control.frame.maxX)) in a column \(Int(column.bounds.width)) wide"
    }
    var outlineTitles: [String] { inspector.outline.titles }
    var inspectorFileSummary: [String] { inspector.fileSummary }
    var explorerErrorFiles: Set<String> { errorPaths }
    var sidebarSymbolTitles: [String] { sidebarSymbols?.titles ?? [] }
    var inspectorModuleText: [String] { inspector.moduleText }
    var toolbarTargetText: String { toolbar.targetText }
    var toolbarToolchainText: String { toolbar.toolchainText }
    var toolbarStatusText: String { toolbar.statusText }
    var toolbarRunTitle: String { toolbar.runTitle }

    // MARK: outline and module facts

    /// Asks gopls for the open file's symbols (shortly after a change) and shows them in the inspector and the Symbols tab.
    func refreshOutline(after delay: TimeInterval = 0) {
        outlineTimer?.invalidate()
        outlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.loadOutline() }
    }

    private func loadOutline() {
        if let pane = currentPane {
            inspector.showFile(language: pane.editorFile.language, text: String(pane.textView.string.prefix(200_000)), previewMode: pane.previewMode)
        }
        guard let pane = currentPane, let client = pane.editorFile.client else {
            inspector.outline.show([])
            sidebarSymbols?.show([])
            return
        }
        let path = pane.editorFile.fileURL.path
        client.documentSymbols(uri: pane.editorFile.uri) { [weak self] symbols in
            DispatchQueue.main.async {
                guard let self, self.currentPane?.editorFile.fileURL.path == path else { return }
                let flat = OutlineSymbol.flatten(symbols)
                self.inspector.outline.show(flat)
                self.sidebarSymbols?.show(flat)
            }
        }
    }

    private func loadModuleFacts() {
        let text = (try? String(contentsOf: root.appendingPathComponent("go.mod"), encoding: .utf8)) ?? ""
        moduleFacts = text.isEmpty ? nil : GoModFacts.parse(text)
        let work = FileManager.default.fileExists(atPath: root.appendingPathComponent("go.work").path) ? "go.work" : nil
        inspector.show(module: moduleFacts, workspaceName: work)
    }

    /// Saves every tab with unsaved edits.
    func saveAll(automatic: Bool = false) {
        for path in tabs.dirtyPaths { panes[path]?.save(automatic: automatic) }
    }

    /// Toggles the bottom panel (View > Toggle Bottom Panel, ⌘J).
    func toggleBottomPanel() { bottomPanel.isHidden.toggle() }
    var isBottomPanelHidden: Bool { bottomPanel.isHidden }
    func setBottomPanel(hidden: Bool, tab: Int) { bottomPanel.select(tab: tab); bottomPanel.isHidden = hidden }
    var explorerNames: [String] { rootNode.children.map { $0.url.lastPathComponent } }
    func openPane(for path: String) -> EditorPane? { panes[path] }

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

    /// Asks git (through gobid) what changed, then recolours the explorer and updates the branch. Does nothing in Restricted Mode.
    func refreshGit() {
        guard isTrusted else { return }
        let root = self.root.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.gitClient == nil { self.gitClient = try? GitClient(workspaceRoot: root, trusted: true, gitPath: AppPreferences.git.gitPath) }
            guard let status = try? self.gitClient?.status() else { return }
            let branches = (try? self.gitClient?.branches()) ?? []
            DispatchQueue.main.async {
                self.gitStatus = status
                self.gitBranches = branches
                if !status.branch.isEmpty { self.branchName = status.branch }
                self.outline.reloadData()
                self.sourceControl.show(status)
                self.placeFilesDivider()
                self.commitPanel.show(status)
                if let shown = self.diffPanel.path, !status.changedFiles.contains(where: { $0.path == shown }) { self.diffPanel.showEmpty() }
                self.refreshChrome()
                self.updateGitMarks()
            }
        }
    }

    // MARK: git: marks, diff, commit, branches

    /// Runs a git request off the main thread and reports back on the main thread.
    func git<T>(_ work: @escaping (GitClient) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        guard isTrusted, let client = gitClient else { return done(.failure(GitClientError.closed)) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(client) }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Marks changed lines in the gutter of every open file (those not yet asked about are fetched).
    func updateGitMarks() {
        guard AppPreferences.git.showGutterMarks else {
            for pane in panes.values { pane.editor.setGitMarks(added: [], modified: [], deletedAfter: []) }
            return
        }
        for (path, pane) in panes {
            let relative = relativePath(of: URL(fileURLWithPath: path))
            git({ try $0.changedLines(path: relative) }) { [weak pane] result in
                guard let pane, case .success(let changes) = result else { return }
                let marks = GitLineChange.marks(for: changes)
                pane.editor.setGitMarks(added: marks.added, modified: marks.modified, deletedAfter: marks.deletedAfter)
            }
        }
    }

    /// Opens the Diff tab of the bottom panel on one changed file.
    func showDiff(path: String) {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 5)
        let staged = gitStatus?.files.first { $0.path == path }.map { $0.staged && !$0.unstaged } ?? false
        git({ try $0.diff(path: path, staged: staged) }) { [weak self] result in
            switch result {
            case .success(let text): self?.diffPanel.show(diff: text, path: path, staged: staged)
            case .failure(let error): self?.diffPanel.show(error: "git: \(error)", path: path)
            }
        }
    }

    /// Reads the Log and the stash list for the sidebar's Commit tab.
    func loadLog() {
        git({ try $0.log(50) }) { [weak self] result in if case .success(let commits) = result { self?.commitPanel.show(log: commits) } }
        git({ try $0.stashes() }) { [weak self] result in if case .success(let list) = result { self?.commitPanel.show(stashes: list) } }
    }

    /// Ticking a file in the Commit tab stages it, unticking unstages it.
    func applyToggle(_ toggle: ChangesTree.Toggle) {
        if toggle.stage.isEmpty && toggle.unstage.isEmpty { return }
        git({ client in
            if !toggle.stage.isEmpty { try client.perform(.stage(toggle.stage)) }
            if !toggle.unstage.isEmpty { try client.perform(.unstage(toggle.unstage)) }
        }) { [weak self] result in
            if case .failure(let error) = result { self?.statusBar.set(note: "git: \(error)") }
            self?.refreshGit()
        }
    }

    /// Amend ticked with an empty message: fill in the last commit's message to edit.
    private func amendChanged(_ on: Bool) {
        guard on else { return }
        git({ try $0.log(1) }) { [weak self] result in
            guard let self, case .success(let list) = result, let text = CommitButtonState.amendPrefill(message: self.commitPanel.messageText, last: list.first) else { return }
            self.commitPanel.setMessage(text)
        }
    }

    /// Stage, unstage or switch branch, then look at the repository again.
    func gitAction(_ request: GitRequest, then: (() -> Void)? = nil) {
        if request.changesWorkingTree { cancelAutoSaves() }
        git({ try $0.perform(request) }) { [weak self] result in
            if case .failure(let error) = result { AppLog.shared.logWarn("git channel: \(error)"); self?.statusBar.set(note: "git: \(error)") }
            self?.refreshGit()
            if request.changesWorkingTree { self?.resumeAfterWorkingTreeChange() }
            then?()
        }
    }

    /// The ⋮ menu beside Run and Debug: the other things a run can do.
    func moreRunMenu() -> NSMenu {
        let entries: [MenuEntry] = [.item("Profile", "⌘I", "profile"), .separator, .item("Run Tests", "⌘U", "runTests"), .item("Run Test at Cursor", "⌥⌘U", "runTestAtCursor")]
        return ContextMenus.build(entries, handlers: [
            "profile": { [weak self] in self?.showProfiler() },
            "runTests": { [weak self] in self?.runTests() },
            "runTestAtCursor": { [weak self] in self?.runTestAtCursor() },
        ])
    }

    /// Updates the remote-tracking branches, then the status. Quiet unless git reports a problem.
    func fetchChanges() {
        guard isTrusted else { return }
        lastFetch = Date()
        gitAction(.fetch)
    }

    /// Fetches on the interval of Settings > Git, checked every 30 seconds while the window is open.
    func startAutoFetch() {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.fetchIfDue() }
    }

    func fetchIfDue() {
        if AutoFetch.isDue(minutes: AppPreferences.git.fetchMinutes, secondsSinceLast: Int(Date().timeIntervalSince(lastFetch))) { fetchChanges() }
    }

    /// Asks which branch to bring in, then merges it into the current one (a conflict is undone by the core).
    func mergeIntoCurrent() {
        let others = gitBranches.filter { !$0.isCurrent }.map(\.name)
        guard let current = gitBranches.first(where: \.isCurrent)?.name, !others.isEmpty else { statusBar.set(note: "git: there is no other branch to merge"); return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: others)
        let alert = NSAlert()
        alert.messageText = "Merge into \(current)"
        alert.informativeText = "Brings the commits of the branch you pick into the current one. If they conflict, the merge is undone and nothing changes."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let branch = popup.titleOfSelectedItem else { return }
        merge(branch)
    }

    func merge(_ branch: String) {
        gitAction(.merge(branch)) { [weak self] in self?.reloadExplorer(); self?.checkDisk(); self?.loadLog() }
    }

    func pullChanges() { gitAction(.pull) { [weak self] in self?.reloadExplorer(); self?.checkDisk() } }
    func pushChanges() { gitAction(.push) }

    /// Asks, then throws the file's changes away (a tracked file goes back to the last commit, an untracked one is deleted).
    func discardChanges(_ path: String, confirm: Bool = true) {
        if confirm {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Discard changes to \((path as NSString).lastPathComponent)?"
            alert.informativeText = "The edits are thrown away and the file goes back to the last commit. This cannot be undone. Untracked files are deleted."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        gitAction(.discard([path])) { [weak self] in self?.reloadExplorer(); self?.checkDisk() }
    }

    /// Git > Commit… and the Commit… button of Source control: shows the Commit tab with the cursor in the message field.
    func commitChanges() {
        if sidebarView?.isHidden == true { toggleSidebar() }
        selectSidebarTab(Self.commitTabIndex)
        commitPanel.mode = .commit
        commitPanel.focusMessage()
    }

    static let commitTabIndex = 4

    /// Commits the staged files (every change when `stageAll` is true, or when nothing is staged and `stageAll` is nil), then
    /// pushes when asked. A successful commit empties the message field.
    func commit(message: String, stageAll: Bool?, amend: Bool = false, push: Bool = false) {
        let status = gitStatus
        let everything = stageAll ?? (status?.stagedFiles.isEmpty ?? true)
        let paths = (status?.changedFiles ?? []).map(\.path)
        git({ client in
            if everything && !paths.isEmpty { try client.perform(.stage(paths)) }
            try client.perform(.commit(message, amend: amend))
            if push { try client.perform(.push) }
        }) { [weak self] result in
            switch result {
            case .success:
                self?.statusBar.set(note: push ? "Committed and pushed" : "Committed")
                self?.commitPanel.clearMessage()
            case .failure(let error): self?.statusBar.set(note: "git: \(error)")
            }
            self?.refreshGit()
            self?.loadLog()
        }
    }

    /// The branch button's menu: each branch (the current one checked) and New Branch….
    func branchMenu() -> NSMenu? {
        guard !gitBranches.isEmpty else { return nil }
        let menu = NSMenu(title: "Branches")
        menu.autoenablesItems = false
        for branch in gitBranches {
            let item = NSMenuItem(title: branch.name, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            let behaviour = MenuAction { [weak self] in self?.switchBranch(branch.name) }
            item.target = behaviour
            item.representedObject = behaviour
            item.state = branch.isCurrent ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let create = NSMenuItem(title: "New Branch…", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let behaviour = MenuAction { [weak self] in self?.newBranch() }
        create.target = behaviour
        create.representedObject = behaviour
        menu.addItem(create)
        let merge = NSMenuItem(title: "Merge into Current Branch…", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let mergeBehaviour = MenuAction { [weak self] in self?.mergeIntoCurrent() }
        merge.target = mergeBehaviour
        merge.representedObject = mergeBehaviour
        merge.isEnabled = gitBranches.count > 1
        menu.addItem(merge)
        return menu
    }

    func switchBranch(_ name: String) {
        gitAction(.checkout(name, create: false)) { [weak self] in self?.reloadExplorer() }
    }

    func newBranch() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "feature/name"
        let alert = NSAlert()
        alert.messageText = "New branch"
        alert.informativeText = "Created from the current commit and switched to."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        gitAction(.checkout(field.stringValue, create: true))
    }

    /// Reads the folders again (after a branch switch changed what is on disk).
    func reloadExplorer() {
        rootNode.refresh()   // keeps the nodes (and so what is expanded) of names that are still there
        // The selected rows would point at other items now, and selecting a file opens it: drop the selection without opening anything.
        isReloadingExplorer = true
        outline.reloadData()
        outline.deselectAll(nil)
        isReloadingExplorer = false
    }

    private var isReloadingExplorer = false

    var sourceControlRows: [String] { sourceControl.rowTexts }
    var sourceControlBranch: String { sourceControl.branchText }
    var gitPanelFiles: [String] { commitPanel.fileTitles }
    var gitPanelDiff: String { diffPanel.diffText }
    var gitPanelDiffTitle: String { diffPanel.titleText }
    var gitPanelCommits: [GitCommit] { commitPanel.commits }
    var gitPanelSections: [String] { commitPanel.sectionTitles }
    var commitPanelView: CommitPanelView { commitPanel }

    func windowDidBecomeKey(_ notification: Notification) {
        if AppPreferences.git.refreshOnFocus { refreshGit() }
        checkDisk()
    }

    // MARK: changes on disk

    private var diskTimer: Timer?
    private var recoveryTimer: Timer?
    /// Seconds between the writes of edited buffers while the window is watched (a crash must not lose the edits); a self-test shortens it.
    static var recoveryInterval: TimeInterval = 20
    /// Hash of the text last written to the recovery store, per path: an unchanged buffer is not written again.
    var recoveryStamps: [String: Int] = [:]
    /// True for a project opened by a person (not a self-test): its session is saved on close and restored on open.
    var persistsSession = false

    private var diskWatcher: DiskWatcher?

    /// Looks for files changed by something else: file-system events on the project folder (coalesced to ~150 ms) run `checkDisk()`,
    /// and a slow poll every 10 s catches what events miss (files outside the folder, network volumes).
    func startWatchingDisk() {
        guard diskTimer == nil else { return }
        diskWatcher = DiskWatcher(path: root.path) { [weak self] in self?.checkDisk() }
        diskTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkDisk(verifyContent: false) }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: Self.recoveryInterval, repeats: true) { [weak self] _ in self?.saveRecoveries(onlyChanged: true) }
    }

    var isWatchingDisk: Bool { diskTimer != nil }

    func stopWatchingDisk() { diskTimer?.invalidate(); diskTimer = nil; recoveryTimer?.invalidate(); recoveryTimer = nil; diskWatcher?.stop(); diskWatcher = nil }

    /// One round of the watcher: each open file, then the listed folders. Public so tests do not wait for the timer.
    /// `verifyContent` is false on the 10 s poll: files with equal metadata are not read then.
    func checkDisk(verifyContent: Bool = true) {
        guard window?.isVisible ?? false else { return }
        var reloaded: [String] = []
        for (path, pane) in panes {
            switch pane.checkDisk(verifyContent: verifyContent) {
            case .reload: reloaded.append(URL(fileURLWithPath: path).lastPathComponent)
            case .conflict, .deleted: autoSaveTimers[path]?.invalidate(); autoSaveTimers[path] = nil
            case .none: break
            }
        }
        if let name = reloaded.sorted().first { statusBar.set(note: "\(name) updated from disk") }
        if rootNode.refresh() {
            outline.reloadData()
            refreshGit()
        }
    }

    /// The project button's menu: where the project is on disk.
    func projectMenu() -> NSMenu {
        let menu = NSMenu(title: "Project")
        menu.autoenablesItems = false
        for (title, run) in [("Reveal in Finder", { [weak self] in if let root = self?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) } }),
                             ("Copy Path", { [weak self] in if let path = self?.root.path { ContextMenus.copyToPasteboard(path) } })] as [(String, () -> Void)] {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            let behaviour = MenuAction(run)
            item.target = behaviour
            item.representedObject = behaviour
            menu.addItem(item)
        }
        return menu
    }

    // MARK: debugging

    var breakpointsKey: String { "gobi.breakpoints." + root.path }

    func loadBreakpoints() {
        breakpoints = Breakpoints.decode(UserDefaults.standard.string(forKey: breakpointsKey) ?? "")
    }

    var debugState: DebugState { debugSession?.state ?? .idle }
    var debugFrameTitles: [String] { debugNavigator.frameTitles }
    var debugVariableNames: [String] { debugPanel.variableNames }
    var debugStatusText: String { debugPanel.statusText }
    var debugEnabledActions: Set<String> { debugPanel.enabledActions }

    /// Adds or removes a breakpoint, keeps it, and shows it in every open copy of the file (and tells a running session).
    func toggleBreakpoint(path: String, line: Int) {
        breakpoints.toggle(path: path, line: line)
        UserDefaults.standard.set(breakpoints.encoded(), forKey: breakpointsKey)
        applyBreakpoints(to: path)
        debugSession?.breakpointsChanged(in: path)
    }

    func applyBreakpoints(to path: String) {
        guard let editor = panes[path]?.editor else { return }
        let lines = breakpoints.lines(in: path)
        editor.breakpointLines = Set(lines)
        editor.conditionalBreakpointLines = Set(lines.filter { breakpoints.condition(path: path, line: $0) != nil })
        debugNavigator.update(frames: debugSession?.frames ?? [], selectedFrame: debugSession?.selectedFrame ?? 0, threads: debugSession?.threads ?? [], selectedThread: debugSession?.threadId ?? 0, breakpoints: breakpointListRows())
    }

    private func breakpointListRows() -> [DebugNavigatorView.BreakpointRow] {
        breakpoints.paths.flatMap { path in breakpoints.lines(in: path).map { DebugNavigatorView.BreakpointRow(path: path, line: $0, condition: breakpoints.condition(path: path, line: $0)) } }
    }

    /// Debug > Toggle Breakpoint: the line of the caret.
    func toggleBreakpointAtCaret() {
        guard let pane = currentPane else { return }
        let line = pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location).line + 1
        toggleBreakpoint(path: pane.editorFile.fileURL.path, line: line)
    }

    func startDebugging() {
        bottomPanel.isHidden = false
        guard isTrusted else {
            outputPanel.notice("Debugging runs your program and is off in Restricted Mode. Trust the project first.")
            bottomPanel.select(tab: 6)
            return
        }
        guard debugSession?.state.isActive != true else { return }
        guard confirmTargets() else { return }
        guard let package = runPackageTarget() else {
            outputPanel.notice("There is no main package to debug here. Open a file of the program, or add a main.go.")
            bottomPanel.select(tab: 6)
            return
        }
        saveAll()
        let directory = package == "." ? root.path : root.appendingPathComponent(package).standardizedFileURL.path
        let session = makeDebugSession()
        session.environment = Dictionary(uniqueKeysWithValues: (environments.runEntries() ?? []).compactMap { entry -> (String, String)? in
            guard let eq = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[entry.startIndex ..< eq]), String(entry[entry.index(after: eq)...]))
        })
        outputPanel.begin(commandLine: "dlv debug " + package)
        bottomPanel.select(tab: 3)
        selectSidebarTab(3)
        session.start(programDir: directory)
    }

    func debugAction(_ id: String) {
        switch id {
        case "continue": debugSession?.resume()
        case "over": debugSession?.stepOver()
        case "into": debugSession?.stepInto()
        case "out": debugSession?.stepOut()
        case "stop": debugSession?.stop()
        case "restart":
            debugSession?.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startDebugging() }
        default: break
        }
    }

    private func debugChanged() {
        guard let session = debugSession else { return }
        let results = session.watches.expressions.map { (expression: $0, value: session.watchResults[$0] ?? "") }
        debugPanel.update(state: session.state, project: root.lastPathComponent, variables: session.variables, watches: session.state.canStep ? results : session.watches.expressions.map { ($0, "") })
        debugNavigator.update(frames: session.frames, selectedFrame: session.selectedFrame, threads: session.threads, selectedThread: session.threadId, breakpoints: breakpointListRows())
        statusBar.set(note: session.state.statusText(project: root.lastPathComponent))
        let frame = session.currentFrame
        let paused = session.state.canStep
        if paused, let frame, frame.path.hasPrefix(root.path + "/"), panes[frame.path] == nil { openFile(URL(fileURLWithPath: frame.path)) }
        for (path, pane) in panes {
            let here = paused && frame?.path == path
            pane.editor.debugLine = here ? frame?.line : nil
            if here, let frame {
                let lines = pane.textView.string.split(separator: "\n", omittingEmptySubsequences: false).prefix(frame.line).map(String.init)
                pane.editor.inlineValues = InlineValues.compute(lines: lines, currentLine: frame.line, variables: session.variables)
            } else {
                pane.editor.inlineValues = [:]
            }
        }
        if paused, let frame, let pane = panes[frame.path], currentPane !== pane, frame.path.hasPrefix(root.path + "/") { activate(frame.path) }
        toolbar.set(debugging: session.state.isActive)
    }

    // MARK: find in files

    /// Edit > Find in Files… (⇧⌘F): the Find tab, the selected text as the query, and optionally only a folder of the project.
    func findInFiles(scope: String? = nil, focusReplace: Bool = false) {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 7)
        searchScope = scope
        let selected = currentPane.flatMap { pane -> String? in
            let range = pane.textView.selectedRange()
            return range.length > 0 ? (pane.textView.string as NSString).substring(with: range) : nil
        }
        findPanel.focusQuery(selected)
        if focusReplace { window?.makeFirstResponder(findPanel.replacement) }
    }

    /// Searches the project through gobid; a newer search makes an older answer go unnoticed.
    func runSearch(then: (() -> Void)? = nil) {
        let query = findPanel.query.stringValue
        guard !query.isEmpty else { findPanel.showMessage("Type something to search for."); return }
        searchToken += 1
        let token = searchToken
        let history = SearchHistory.adding(query, to: UserDefaults.standard.stringArray(forKey: Self.findHistoryKey) ?? [])
        UserDefaults.standard.set(history, forKey: Self.findHistoryKey)
        findPanel.setHistory(history)
        let options = (findPanel.isRegex, findPanel.isCaseSensitive, findPanel.isWholeWord, findPanel.includeGlobs, findPanel.replacementText)
        let rootPath = root.path
        let scope = searchScope
        findPanel.showMessage("Searching…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> SearchResults in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.searchFiles(root: rootPath, query: query, regex: options.0, caseSensitive: options.1, wholeWord: options.2, include: options.3, replacement: options.4)
            }
            DispatchQueue.main.async {
                guard let self, token == self.searchToken else { return }
                switch result {
                case .success(var found):
                    if let scope {
                        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
                        let kept = found.hits.filter { $0.path.hasPrefix(prefix) }
                        found.hits = kept
                        found.files = Set(kept.map(\.path)).count
                    }
                    self.findPanel.show(found, scope: scope)
                case .failure(let error): self.findPanel.showMessage("\(error)")
                }
                then?()
            }
        }
    }

    private func open(hit: SearchHit) {
        let url = root.appendingPathComponent(hit.path)
        guard openFile(url) else { return }
        currentPane?.reveal(line: hit.line, character: hit.start)
    }

    /// Replaces the given hits. Open files change in the editor (one undo step each, and they stay unsaved); other files are written.
    /// The search is repeated first so that the replacements match the replacement text now in the field.
    func replace(hits: [SearchHit], exact: Bool = false) {
        guard findPanel.replacementText != nil else { findPanel.showMessage("Type the replacement first."); return }
        runSearch { [weak self] in
            guard let self else { return }
            let fresh = ReplaceSelection.refresh(self.findPanel.results.hits, chosen: hits, exact: exact)
            let summary = self.applyReplacements(fresh)
            self.findPanel.showMessage(summary)
            self.runSearch { self.findPanel.appendSummary(summary) }
            self.refreshGit()
        }
    }

    /// Applies hits (with their replacement text) to the files; returns "Replaced 5 in 2 files, 1 skipped".
    func applyReplacements(_ hits: [SearchHit]) -> String {
        var replaced = 0, skipped = 0, files = 0
        for (path, fileHits) in Dictionary(grouping: hits, by: \.path) {
            let url = root.appendingPathComponent(path)
            if let pane = panes[url.path] {
                let plan = ReplacePlan.make(hits: fileHits, text: pane.textView.string)
                skipped += plan.skipped
                guard !plan.edits.isEmpty else { continue }
                pane.apply(plan.edits.map { TextEdit(start: LSPPosition(line: $0.line, character: $0.start), end: LSPPosition(line: $0.line, character: $0.end), newText: $0.replacement) }, named: "Replace in Files")
                replaced += plan.edits.count
                files += 1
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let plan = ReplacePlan.make(hits: fileHits, text: text)
                skipped += plan.skipped
                guard !plan.edits.isEmpty, (try? plan.apply(to: text).write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
                replaced += plan.edits.count
                files += 1
            } else {
                skipped += fileHits.count
            }
        }
        return "Replaced \(replaced) in \(files) file\(files == 1 ? "" : "s")" + (skipped > 0 ? ", \(skipped) skipped (changed since the search)" : "")
    }

    static let findHistoryKey = "gobi.findHistory"
    var findHistory: [String] { findPanel.recentQueries }
    var findIncludedHits: [SearchHit] { findPanel.includedHits }
    func setFindIncluded(_ path: String, _ included: Bool) { findPanel.setIncluded(path, included) }
    var findSummary: String { findPanel.summaryText }
    var findResultPaths: [String] { findPanel.groupPaths }
    var findResultCount: Int { findPanel.results.hits.count }
    var findHits: [SearchHit] { findPanel.results.hits }
    func setSearch(_ query: String, replacement: String = "", regex: Bool = false, include: String = "") {
        findPanel.query.stringValue = query
        findPanel.replacement.stringValue = replacement
        findPanel.include.stringValue = include
        findPanel.setRegex(regex)
    }

    // MARK: environments

    /// The environment menu (Run menu and toolbar popup): each profile, the active one checked, then Manage Environments….
    func environmentMenu() -> NSMenu {
        let menu = NSMenu(title: "Environment")
        menu.autoenablesItems = false
        for profile in environments.file.profiles {
            let item = NSMenuItem(title: profile.name + (profile.isRemote ? "  (remote)" : ""), action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            let behaviour = MenuAction { [weak self] in self?.selectEnvironment(profile.name) }
            item.target = behaviour
            item.representedObject = behaviour
            item.state = profile.name == environments.activeName ? .on : .off
            menu.addItem(item)
        }
        if !environments.file.profiles.isEmpty { menu.addItem(.separator()) }
        let manage = NSMenuItem(title: "Manage Environments…", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let behaviour = MenuAction { NSApp.sendAction(#selector(AppDelegate.showEnvironments(_:)), to: nil, from: nil) }
        manage.target = behaviour
        manage.representedObject = behaviour
        menu.addItem(manage)
        return menu
    }

    func selectEnvironment(_ name: String) {
        environments.activeName = name
        refreshChrome()
    }

    func reloadEnvironments() {
        environments.reload()
        refreshChrome()
    }

    /// Asks before a run touches services that are not on this machine, when the active profile says to. True to go on.
    private func confirmTargets() -> Bool {
        let targets = environments.nonLocalTargetsToConfirm()
        guard !targets.isEmpty else { return true }
        if let confirmNonLocal { return confirmNonLocal(targets) }
        let alert = NSAlert()
        alert.messageText = "Run against non-local services?"
        alert.informativeText = "The “\(environments.activeName)” environment points at:\n" + targets.map { "• \($0.component)  \($0.address)" }.joined(separator: "\n") + "\n\nTests, migrations and scripts can change or delete data there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: terminal

    /// View > New Terminal (⌃⇧`): shows the Terminal tab and opens one more shell.
    func openNewTerminal() {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 2)
        terminalPane?.newTerminal()
    }

    var terminalFindStatus: String { terminalPane?.findStatus ?? "" }
    var terminalAppearance: (fontSize: Int, optionAsMeta: Bool)? { terminalPane?.terminalAppearance }
    var terminalFontInfo: (family: String, fallbacks: Int)? { terminalPane?.terminalFontInfo }
    var statusNote: String { statusBar.noteText }
    var terminalScrollback: Int? { terminalPane?.scrollbackLines }
    var terminalStartFolder: String { terminalPane?.lastStartFolder ?? "" }
    var terminalCopyOnSelect: (enabled: Bool, selectionEvents: Int)? { terminalPane?.copyOnSelectState }
    func terminalSelectAll() { terminalPane?.selectAllForTest() }
    func terminalCopySelection(_ text: String) -> Bool { terminalPane?.copySelectionForTest(text) ?? false }
    func newTerminalForTest() { terminalPane?.newTerminal() }

    /// Files with unsaved changes and run or debug sessions in progress, for the quit confirmation.
    var unsavedFileCount: Int { tabs.dirtyPaths.count }
    var runningTaskCount: Int { (isRunning ? 1 : 0) + (debugState.isActive ? 1 : 0) }
    var terminalIsSplit: Bool { terminalPane?.isSplit ?? false }
    var terminalShellList: [String] { terminalPane?.shells ?? [] }
    var terminalMenuItems: [(title: String, checked: Bool)] { terminalPane?.terminalMenu().items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.state == .on) } ?? [] }
    func splitTerminal() { terminalPane?.splitSelected() }
    func findInTerminal(_ text: String) { terminalPane?.search(text) }

    // MARK: profiler

    private var profilesFolder: URL { root.appendingPathComponent(".gobi/profiles") }

    /// Profile > Profile (⌘I) and the toolbar button: shows the Profiler tab with the project's saved profiles.
    func showProfiler() {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 4)
        refreshProfiles()
        if profileURL == nil, let newest = profileFiles().first { loadProfile(newest) }
    }

    private func profileFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: profilesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return names.filter { $0.pathExtension == "pprof" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    private var profileLoadGeneration = 0

    private func refreshProfiles() { profilerPanel.show(files: profileFiles(), selected: profileURL) }

    /// Reads a .pprof file through gobid and shows it.
    func loadProfile(_ url: URL, sample: Int? = nil) {
        profileURL = url
        profileLoadGeneration += 1
        let mine = profileLoadGeneration
        profilerPanel.showMessage("Reading \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> ProfileData in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.profileLoad(path: url.path, sampleIndex: sample)
            }
            DispatchQueue.main.async {
                // A newer load has started since: its answer is the one to show, not this older one.
                guard self?.profileLoadGeneration == mine else { return }
                switch result {
                case .success(let data): self?.profilerPanel.show(profile: data, name: url.lastPathComponent)
                case .failure(let error): self?.profilerPanel.showMessage("Cannot read \(url.lastPathComponent): \(error)")
                }
            }
        }
    }

    /// Downloads a profile from a running program that serves net/http/pprof, saves it in `.gobi/profiles` and shows it.
    func captureProfile(address: String, kind: String, seconds: Int) {
        guard isTrusted else { profilerPanel.showMessage("Profiling is off in Restricted Mode. Trust the project first."); return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let output = profilesFolder.appendingPathComponent("\(kind)-\(stamp).pprof")
        try? FileManager.default.createDirectory(at: profilesFolder, withIntermediateDirectories: true)
        try? "*\n".write(to: profilesFolder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        profilerPanel.showMessage(kind == "cpu" ? "Capturing \(seconds) s of CPU from \(address)…" : "Capturing \(kind) from \(address)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> Void in
                let client = try ControlClient.connect()
                defer { client.close() }
                try client.profileCapture(address: address, kind: kind, seconds: seconds, output: output.path)
            }
            DispatchQueue.main.async {
                switch result {
                case .success: self?.refreshProfiles(); self?.loadProfile(output)
                case .failure(let error): self?.profilerPanel.showMessage("Capture failed: \(error)")
                }
            }
        }
    }

    /// Per-line cost of a function of the open profile, for the Source view.
    func loadProfileLines(_ function: String) {
        guard let url = profileURL else { return }
        let sample = profilerPanel.data?.index
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> ProfileLines in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.profileLines(path: url.path, sampleIndex: sample, function: function)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let lines): self?.profilerPanel.show(lines: lines)
                case .failure(let error): self?.profilerPanel.showMessage("Cannot read the lines of \(function): \(error)")
                }
            }
        }
    }

    /// Compares the open profile with another file: the Top table then lists the change per function.
    func compareProfile(with other: URL) {
        guard let base = profileURL, let profile = profilerPanel.data, profile.sampleTypes.indices.contains(profile.index) else {
            profilerPanel.showMessage("Open a profile first, then choose one to compare with.")
            return
        }
        let type = profile.sampleTypes[profile.index].type
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> ProfileDiff in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.profileDiff(base: base.path, other: other.path, type: type)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let diff): self?.profilerPanel.show(diff: diff, name: other.lastPathComponent)
                case .failure(let error): self?.profilerPanel.showMessage("Cannot compare with \(other.lastPathComponent): \(error)")
                }
            }
        }
    }

    private func chooseProfileToCompare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.message = "Choose the profile to compare with"
        panel.directoryURL = profilesFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compareProfile(with: url)
    }

    var profilerDiffNames: [String] { profilerPanel.diff == nil ? [] : profilerPanel.topNames }
    var profilerDiffDeltas: [Int] { profilerPanel.visibleDiff.map(\.flatDelta) }
    func setProfilerFilter(_ query: String) { profilerPanel.setFilter(query) }
    func showProfilerSource(of name: String) {
        selectProfilerFrame(named: name)
        profilerPanel.showSource()
    }
    var profilerSourceCostLines: [Int] { profilerPanel.sourceCostLines }
    var profilerSourceRowCount: Int { profilerPanel.sourceRows.count }
    var profilerSourceFirstLine: Int? { profilerPanel.sourceRows.first?.line }
    var profilerSourceLastLine: Int? { profilerPanel.sourceRows.last?.line }
    func setProfilerWholeFile(_ on: Bool) { profilerPanel.setWholeFile(on) }
    func openProfilerSourceLine(_ line: Int) { profilerPanel.openSourceLine(line) }

    private func chooseProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.message = "Choose a profile (.pprof)"
        panel.directoryURL = profilesFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProfile(url)
    }

    var profilerStatus: String { profilerPanel.statusText }
    var profilerInspector: String { profilerPanel.inspectorText }
    var profilerTopNames: [String] { profilerPanel.topNames }
    var profilerFlameCount: Int { profilerPanel.flameRectCount }
    func selectProfilerFrame(named name: String) {
        if let node = profilerPanel.data?.nodes.first(where: { $0.name == name }) { profilerPanel.select(id: node.id) }
    }

    // MARK: watches, conditions, attach

    private func saveWatches() { UserDefaults.standard.set(watches.encoded(), forKey: "gobi.watches." + root.path) }

    func addWatch(_ expression: String) {
        watches.add(expression)
        saveWatches()
        debugSession?.watches = watches
        debugSession?.evaluateWatches()
        debugChanged()
    }

    func removeWatch(at index: Int) {
        watches.remove(at: index)
        saveWatches()
        debugSession?.watches = watches
        debugChanged()
    }

    /// Debug > Add Conditional Breakpoint…: asks for the expression, then makes the caret's line stop only when it is true.
    func addConditionalBreakpoint() {
        guard let pane = currentPane else { return }
        let path = pane.editorFile.fileURL.path
        let line = pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location).line + 1
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = breakpoints.condition(path: path, line: line) ?? ""
        field.placeholderString = "len(errc) > 0"
        let alert = NSAlert()
        alert.messageText = "Conditional breakpoint"
        alert.informativeText = "\(pane.editorFile.fileURL.lastPathComponent):\(line). Pauses only when the expression is true. Leave it empty for a plain breakpoint."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setCondition(field.stringValue, path: path, line: line)
    }

    func setCondition(_ condition: String, path: String, line: Int) {
        breakpoints.setCondition(condition, path: path, line: line)
        UserDefaults.standard.set(breakpoints.encoded(), forKey: breakpointsKey)
        applyBreakpoints(to: path)
        debugSession?.breakpointsChanged(in: path)
    }

    /// Debug > Attach to Process…
    func attachToProcess() {
        guard isTrusted, let window else { return }
        let sheet = AttachProcessSheet()
        sheet.onAttach = { [weak self] pid in self?.startAttach(pid: pid) }
        attachSheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow) }
        sheet.load()
    }

    private var attachSheet: AttachProcessSheet?

    func startAttach(pid: Int) {
        guard debugSession?.state.isActive != true else { return }
        let session = makeDebugSession()
        outputPanel.begin(commandLine: "dlv attach \(pid)")
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 3)
        selectSidebarTab(3)
        session.attach(pid: pid)
    }

    private func makeDebugSession() -> DebugSession {
        let session = DebugSession(root: root)
        session.breakpoints = { [weak self] in self?.breakpoints ?? Breakpoints() }
        session.watches = watches
        session.onChange = { [weak self] in self?.debugChanged() }
        session.onOutput = { [weak self] text in self?.outputPanel.append(Array(text.utf8), isError: false) }
        debugSession = session
        return session
    }

    /// Debug > Show Goroutines: the navigator on the left.
    func showGoroutines() { selectSidebarTab(3) }

    var debugWatchRows: [(expression: String, value: String)] { debugPanel.watchRows }
    var debugGoroutineTitles: [String] { debugNavigator.threadTitles }
    var debugGoroutinesHeader: String { debugNavigator.threadsHeaderText }
    var debugNavigatorBreakpoints: [DebugNavigatorView.BreakpointRow] { debugNavigator.breakpointRows }

    // MARK: Go toolchain

    private var toolchainKey: String { "gobi.toolchain." + root.path }

    var toolchainResolution: ToolchainChoice.Resolution {
        ToolchainChoice.resolve(toolchainSelection, goMod: moduleFacts, installs: goInstalls)
    }

    /// The text of the toolbar popup: the version Run will use.
    var toolchainTitle: String {
        switch toolchainResolution {
        case .system: return goVersion.map { "Go " + $0 } ?? "Go"
        case .install(let install): return "Go " + install.version
        case .missing(let wanted): return "Go " + wanted + " (not installed)"
        }
    }

    /// Pins a version, or goes back to Auto when `version` is nil.
    func selectToolchain(version: String?) {
        setToolchain(version.map { ToolchainSelection(mode: .pinned, pinnedVersion: $0) } ?? ToolchainSelection())
    }

    /// The Go folder gopls and runs use now ("" for the go on PATH, also when the wanted version is missing).
    private var currentGoRoot: String { ToolchainChoice.goRoot(toolchainResolution, home: NSHomeDirectory()) ?? "" }

    /// The folder to run with. Nil only when a pinned version is not installed; with Auto the go on PATH is used and Go's own
    /// toolchain handling applies.
    private var runGoRoot: String? {
        let root = ToolchainChoice.goRoot(toolchainResolution, home: NSHomeDirectory())
        return root ?? (toolchainSelection.mode == .pinned ? nil : "")
    }

    /// After the installed versions are known or the choice changes: gopls restarts in every open file whose Go differs.
    private func applyGoRoot() {
        let goRoot = currentGoRoot
        for pane in panes.values where pane.goRoot != goRoot {
            pane.goRoot = goRoot
            pane.reconnect()
        }
    }

    func setToolchain(_ selection: ToolchainSelection) {
        toolchainSelection = selection
        UserDefaults.standard.set(selection.encoded(), forKey: toolchainKey)
        applyGoRoot()
        refreshChrome()
    }

    func loadGoInstalls() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = GoInstalls.merge(system: GoTool.system(), sdk: GoTool.sdkInstalls())
            DispatchQueue.main.async { self?.goInstalls = found; self?.applyGoRoot(); self?.refreshChrome() }
        }
    }

    /// The Go Toolchain menu (Run menu and toolbar popup): Auto, each installed version, then Manage.
    func toolchainMenu() -> NSMenu {
        let menu = NSMenu(title: "Go Toolchain")
        menu.autoenablesItems = false
        for entry in ToolchainChoice.menuItems(selection: toolchainSelection, goMod: moduleFacts, installs: goInstalls) {
            let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            let behaviour = MenuAction { [weak self] in self?.selectToolchain(version: entry.version) }
            item.target = behaviour
            item.representedObject = behaviour
            item.state = entry.isChecked ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let multi = NSMenuItem(title: "Run on Multiple Go Versions…", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let multiBehaviour = MenuAction { NSApp.sendAction(#selector(AppDelegate.runMultiVersion(_:)), to: nil, from: nil) }
        multi.target = multiBehaviour
        multi.representedObject = multiBehaviour
        menu.addItem(multi)
        let manage = NSMenuItem(title: "Manage Go Toolchains…", action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let behaviour = MenuAction { NSApp.sendAction(#selector(AppDelegate.showToolchains(_:)), to: nil, from: nil) }
        manage.target = behaviour
        manage.representedObject = behaviour
        menu.addItem(manage)
        return menu
    }

    // MARK: auto save

    private var autoSaveTimers: [String: Timer] = [:]
    static let autoSaveDelay: TimeInterval = 1

    /// Settings > Editor > Auto save "After a delay": one second after the last edit the file is saved the way Save would, unless
    /// the file changed on disk meanwhile (`EditorPane.save(automatic:)` then leaves it and the conflict notice asks).
    func scheduleAutoSave(_ path: String, delay: TimeInterval = ProjectWindowController.autoSaveDelay) {
        autoSaveTimers[path]?.invalidate()
        guard EditorPreferences.current.autoSave == .afterDelay else { return }
        autoSaveTimers[path] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.tabs.isDirty(path) else { return }
            self.panes[path]?.save(automatic: true)
        }
    }

    /// Drops every pending auto save (a git operation that rewrites files is starting).
    func cancelAutoSaves() {
        autoSaveTimers.values.forEach { $0.invalidate() }
        autoSaveTimers.removeAll()
    }

    /// After such an operation: look at the disk (a conflict notice appears for an edited buffer whose file changed), then let the
    /// buffers that are still edited be saved again.
    func resumeAfterWorkingTreeChange() {
        checkDisk()
        for path in tabs.dirtyPaths { scheduleAutoSave(path) }
    }

    /// "When the window loses focus".
    func windowDidResignKey(_ notification: Notification) {
        if EditorPreferences.current.autoSave == .onFocusLoss { saveAll(automatic: true) }
    }

    /// Whether the file has unsaved edits, for the self-test.
    func isDirty(_ url: URL) -> Bool { tabs.isDirty(url.path) }

    /// The mark git gives an explorer row, for the self-test.
    func gitMark(ofRow row: Int) -> GitMark? {
        guard let node = outline.item(atRow: row) as? FileNode else { return nil }
        return gitStatus?.mark(of: relativePath(of: node.url), isDirectory: node.isDirectory)
    }

    /// Brings the status bar, breadcrumb and window title in line with the active file.
    func refreshChrome() {
        let path = currentPane?.editorFile.fileURL.path
        let connected = path.map(connectedPaths.contains) ?? false
        var uts = utsname(); uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        toolbar.set(environment: environments.activeName.isEmpty ? "local" : environments.activeName, remote: environments.active?.isRemote ?? false)
        toolbar.set(project: root.lastPathComponent, branch: branchName, target: runPackageTarget().map { "go run " + $0 } ?? "go run", toolchain: toolchainTitle,
                    status: ToolbarText.status(goplsReady: connected, goVersion: goVersion, platform: ToolbarText.platform(system: "darwin", machine: machine)))
        toolbar.set(running: isRunning)
        let language = currentPane?.editorFile.language ?? "go"
        let problemsHere = path.map { diagnosticsByPath[$0]?.count ?? 0 } ?? 0
        statusBar.set(branch: branchName, service: StatusBar.serviceText(language: language, connected: connected, restricted: !isTrusted), languageLabel: StatusBar.languageLabel(language: language, goVersion: goVersion, problems: problemsHere))
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

    func rebuildProblems() {
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
        errorPaths = Set(items.filter { $0.severity == 1 }.map(\.path))
        outline.reloadData()
        refreshChrome()
    }

    /// Opens the file a compiler or test message names. Compiler paths are relative to the project; `go test` prints them
    /// relative to the package, so a path that is not under the project root is looked for by its tail.
    func open(reference: SourceReference) {
        guard let url = resolve(reference.path) else { statusBar.set(note: "Cannot find \(reference.path)"); return }
        openFile(url)
        currentPane?.reveal(line: max(0, reference.line - 1), character: max(0, (reference.column ?? 1) - 1))
    }

    private func resolve(_ path: String) -> URL? {
        let manager = FileManager.default
        let direct = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
        if manager.fileExists(atPath: direct.path) { return direct }
        let name = (path as NSString).lastPathComponent
        let tail = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        var best: URL?
        if let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker where url.lastPathComponent == name {
                if url.path.hasSuffix("/" + tail) { return url }
                best = best ?? url
            }
        }
        return best
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
                if self?.currentPane?.editorFile.fileURL.path == path { self?.refreshOutline(after: 0.4) }
            }
            pane.onCaret = { [weak self] _, _ in if self?.currentPane?.editorFile.fileURL.path == path { self?.refreshChrome() } }
            pane.editorFile.onTextChanged = { [weak self] in
                if self?.currentPane?.editorFile.fileURL.path == path { self?.refreshOutline(after: 0.8) }
                self?.scheduleAutoSave(path)
            }
            pane.editorFile.onEditedChanged = { [weak self] edited in
                self?.tabs.setDirty(path, edited)
                if !edited { self?.refreshGit(); self?.forgetRecovery(path) }
                self?.tabBar.reload(self?.tabs ?? TabStrip())
                self?.window?.isDocumentEdited = !(self?.tabs.dirtyPaths.isEmpty ?? true)
            }
            pane.goRoot = currentGoRoot
            pane.onPreviewModeChanged = { [weak self] _ in self?.refreshOutline() }
            pane.editor.onRunLine = { [weak self, weak pane] line in if let pane { self?.runTest(in: pane, line: line - 1) } }
            pane.lens.onAction = { [weak self, weak pane] action, declaration in if let pane { self?.lensClicked(action, declaration, in: pane) } }
            pane.editor.onToggleBreakpoint = { [weak self] line in self?.toggleBreakpoint(path: path, line: line) }
            pane.markDiskKnown()
            pane.onDeletedClose = { [weak self] in self?.closeTab(path, force: true) }
            panes[path] = pane
            applyBreakpoints(to: path)
            tabs.open(path)
            show(pane)
            pane.connect()
        } else {
            tabs.open(path)
            show(panes[path]!)
        }
        recordRecentFile(url)
        tabBar.reload(tabs)
        return true
    }

    /// Opens each file in its own tab; the last one ends up active. Files that cannot be read are skipped.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Int {
        urls.filter { openFile($0) }.count
    }

    /// The pane of an open file, or nil when it is not open in a tab.
    func paneIfOpen(_ url: URL) -> EditorPane? { panes[url.path] }

    /// A short message in the status bar.
    func showNote(_ text: String) { statusBar.set(note: text) }

    func contains(_ url: URL) -> Bool { url.path.hasPrefix(root.path + "/") }

    func activate(_ path: String) {
        defer { updateGitMarks() }
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
        refreshOutline(after: 0.2)
    }

    // MARK: run and test

    /// What the Output and Tests panels show, for the self-test.
    var runOutputText: String { outputPanel.content }
    var runOutputLinks: [String] { outputPanel.linkedReferences }
    func clickRunOutputLink(at index: Int) { outputPanel.clickLink(at: index) }
    var testFilterText: String { get { testsPanel.filterText } set { testsPanel.filterText = newValue } }
    func selectTestRow(titled title: String) { testsPanel.select(title: title) }
    var currentFileName: String? { currentPane?.editorFile.fileURL.lastPathComponent }
    var currentCaretLine: Int? { currentPane.map { $0.editorFile.lineIndex.position(at: $0.textView.selectedRange().location).line } }
    var runStateText: String { outputPanel.stateText }
    var runCommandText: String { outputPanel.commandText }
    var testCounts: (passed: Int, failed: Int, skipped: Int) { (results.passed, results.failed, results.skipped) }
    var testRowTitles: [String] { testsPanel.titles }
    var testFailureLines: [String] { testsPanel.detailLines }
    var isRunFailedEnabled: Bool { testsPanel.isRunFailedEnabled }
    var selectedPanelTab: Int { bottomPanel.selectedTab }

    func relativePath(of url: URL) -> String { StatusBar.relativePath(projectRoot: root.path, file: url.path) }

    /// The package Run would start: the open file's folder when it is `package main`, else the project's main package.
    private func runPackageTarget() -> String? {
        let file = currentPane?.editorFile.fileURL
        let text = currentPane?.textView.string ?? ""
        let directory = file.map { (relativePath(of: $0) as NSString).deletingLastPathComponent }
        let commands = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cmd").path)) ?? []).sorted().filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("cmd/\($0)/main.go").path)
        }.map { "cmd/" + $0 }
        return RunTarget.runPackage(
            currentFileDirectory: directory, currentFileIsMain: text.hasPrefix("package main") || text.contains("\npackage main\n"),
            rootHasMain: FileManager.default.fileExists(atPath: root.appendingPathComponent("main.go").path), commandFolders: commands)
    }

    /// Run (⌘R).
    func runProject() {
        let target = runPackageTarget()
        guard let target else {
            outputPanel.notice("There is no main package to run here. Open a file of the program, or add a main.go.")
            bottomPanel.isHidden = false
            bottomPanel.select(tab: 6)
            return
        }
        begin(command: "run", packages: [target], filter: "", arguments: [], tab: 6)
    }

    /// Run Tests (⌘U): every test of the project.
    func runTests() { begin(command: "test", packages: ["./..."], filter: "", arguments: [], tab: 1) }

    /// Run Test at Cursor (⌥⌘U): the test function the caret is in, in its package.
    func runTestAtCursor() {
        guard let pane = currentPane, pane.editorFile.fileURL.lastPathComponent.hasSuffix("_test.go") else {
            statusBar.set(note: "Run Test at Cursor needs a _test.go file")
            NSSound.beep()
            return
        }
        runTest(in: pane, line: pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location).line)
    }

    /// Runs the test function that the zero-based `line` is in.
    func runTest(in pane: EditorPane, line: Int) {
        guard let name = TestAtCursor.name(in: pane.textView.string, line: line) else {
            statusBar.set(note: "No test at the cursor")
            NSSound.beep()
            return
        }
        begin(command: "test", packages: [RunTarget.testPackage(forFile: relativePath(of: pane.editorFile.fileURL))], filter: TestAtCursor.filter(forName: name), arguments: [], tab: 1)
    }

    /// Run Failed: only the tests that failed in the last run (the filter names them; every package is searched).
    func rerunFailed() {
        guard let filter = results.failedFilter else { return }
        begin(command: "test", packages: ["./..."], filter: filter, arguments: [], tab: 1)
    }

    func stopRun() { runClient?.stop() }

    func begin(command: String, packages: [String], filter: String, arguments: [String], tab: Int) {
        bottomPanel.isHidden = false
        guard isTrusted else {
            outputPanel.notice("Running code is off in Restricted Mode. Trust the project to run it.")
            bottomPanel.select(tab: 6)
            return
        }
        guard let goRoot = runGoRoot else {
            if case .missing(let wanted) = toolchainResolution { outputPanel.notice("Go \(wanted) is not installed. Pick another version in Run > Go Toolchain, or install it from Manage Go Toolchains.") }
            bottomPanel.select(tab: 6)
            return
        }
        guard confirmTargets() else { return }
        saveAll()
        runClient?.close()
        let profileEnvironment = environments.runEntries()
        if command == "test" {
            results.clear()
            testsPanel.update(results, running: true)
            sidebarTestsPanel?.update(results, running: true)
        }
        outputPanel.begin(commandLine: RunTarget.commandLine(command: command, packages: packages, filter: filter, arguments: arguments))
        bottomPanel.select(tab: tab)
        isRunning = true
        runStarted = Date()
        let rootPath = root.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let client = try RunClient(workspaceRoot: rootPath, trusted: true)
                DispatchQueue.main.async {
                    guard let self else { client.close(); return }
                    self.runClient = client
                    client.onOutput = { [weak self, weak client] bytes, stream in
                        DispatchQueue.main.async { if self?.runClient === client { self?.outputPanel.append(bytes, isError: stream == 2) } }
                    }
                    client.onTest = { [weak self, weak client] event in
                        DispatchQueue.main.async { if self?.runClient === client { self?.apply(event) } }
                    }
                    client.onExit = { [weak self, weak client] code, message in
                        DispatchQueue.main.async { if self?.runClient === client { self?.runFinished(code: code, message: message) } }
                    }
                    client.start(command: command, packages: packages, filter: filter, arguments: arguments, envFile: profileEnvironment != nil || !WindowSettings.loadDotEnv ? "-" : "", goRoot: goRoot, environment: profileEnvironment ?? [])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isRunning = false
                    AppLog.shared.logError("run channel: cannot start the run: \(error)")
                    self?.outputPanel.notice("Cannot start the run: \(error)")
                }
            }
        }
    }

    private func apply(_ event: TestEvent) {
        results.apply(event)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.testsPanel.update(self.results, running: self.isRunning)
            self.sidebarTestsPanel?.update(self.results, running: self.isRunning)
        }
    }

    private func runFinished(code: Int, message: String) {
        if !message.isEmpty { AppLog.shared.logWarn("run channel: \(message)") }
        isRunning = false
        outputPanel.finish(code: code, message: message, seconds: Date().timeIntervalSince(runStarted))
        testsPanel.update(results, running: false)
        sidebarTestsPanel?.update(results, running: false)
        let tests = results.passed + results.failed + results.skipped
        if tests > 0 { statusBar.set(note: results.failed > 0 ? "\(results.failed) of \(tests) tests failed" : "\(results.passed) tests passed") }
        runClient?.close()
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
            handlers["goToImplementation"] = { [weak self] in self?.goToImplementation() }
            handlers["findReferences"] = { [weak self] in self?.findReferences() }
            handlers["renameSymbol"] = { [weak self] in self?.renameSymbol() }
            handlers["codeActions"] = { [weak self] in self?.showCodeActions() }
            if !pane.editorFile.isReadOnlyByLineLength { handlers["formatDocument"] = { [weak pane] in pane?.formatDocument() } }
        }
        return ContextMenus.build(ContextMenuSpec.editor, handlers: handlers)
    }

    /// The explorer's menu for a row, or for the project folder itself when `row` is -1 (a click on empty space).
    func explorerMenu(row: Int) -> NSMenu? {
        guard let node = (row >= 0 ? outline.item(atRow: row) as? FileNode : rootNode) else { return nil }
        let url = node.url
        var handlers: [String: () -> Void] = [
            "revealInFinder": { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            "copyPath": { ContextMenus.copyToPasteboard(url.path) },
            "copyRelativePath": { [weak self] in ContextMenus.copyToPasteboard(self?.relativePath(url) ?? url.path) },
            "copyFileName": { ContextMenus.copyToPasteboard(url.lastPathComponent) },
            "findInFiles": { [weak self] in self?.findInFiles(scope: node.isDirectory ? self?.relativePath(url) : nil) },
            "replaceInFiles": { [weak self] in self?.findInFiles(scope: node.isDirectory ? self?.relativePath(url) : nil, focusReplace: true) },
        ]
        if !node.isDirectory { handlers["open"] = { [weak self] in self?.openFile(url) } }
        else if row >= 0 { handlers["open"] = { [weak self] in self?.outline.expandItem(node) } }
        // New entries go into the folder clicked, or next to the file clicked.
        let target = node.isDirectory ? url : url.deletingLastPathComponent()
        handlers["newFile"] = { [weak self] in self?.newEntry(.file, in: target) }
        handlers["newFolder"] = { [weak self] in self?.newEntry(.folder, in: target) }
        handlers["newGoFile"] = { [weak self] in self?.newEntry(.goFile, in: target) }
        handlers["newGoTestFile"] = { [weak self] in self?.newEntry(.goTestFile, in: target) }
        // Cut, Copy, Delete, Rename and Move act on the selected rows (the row clicked when it was not selected); Paste goes into the
        // folder clicked, next to the file clicked, or into the project folder from empty space.
        let picked = selectedURLs()
        let items = row >= 0 ? (picked.isEmpty ? [url] : picked) : []
        if !items.isEmpty {
            handlers["cutFiles"] = { [weak self] in self?.copyToClipboard(items, cut: true) }
            handlers["copyFiles"] = { [weak self] in self?.copyToClipboard(items, cut: false) }
            handlers["deleteFiles"] = { [weak self] in self?.deleteItems(items) }
            handlers["moveFile"] = { [weak self] in self?.moveWithSheet(items) }
            if items.count == 1 { handlers["renameFile"] = { [weak self] in self?.renameItem(items[0]) } }
        }
        if canPaste { handlers["pasteFiles"] = { [weak self] in self?.paste(into: target) } }
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
    func closeTab(_ path: String, force: Bool = false) -> Bool {
        guard let pane = panes[path] else { return true }
        if tabs.isDirty(path), !force {
            switch askToSave(pane.editor.document.fileURL.lastPathComponent) {
            case .save: if !pane.save() { return false }
            case .discard: break
            case .cancel: return false
            }
        }
        forgetRecovery(path)
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

    enum SaveAnswer { case save, discard, cancel }

    /// Answers the "save changes?" question without a modal (self-tests); nil asks with an alert.
    var saveAnswerHook: ((String) -> SaveAnswer)?

    private func askToSave(_ name: String) -> SaveAnswer {
        if let saveAnswerHook { return saveAnswerHook(name) }
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

    /// Closing the window asks about each tab with unsaved edits. Nothing changes until every question is answered: Cancel on any
    /// of them leaves the window, the tabs, the kept buffers and the watchers as they were. Then the saves run (a failed one stops
    /// the close before anything is discarded), then the edited tabs close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        var saving: [String] = [], discarding: [String] = []
        for path in tabs.dirtyPaths {
            guard let pane = panes[path] else { continue }
            switch askToSave(pane.editor.document.fileURL.lastPathComponent) {
            case .save: saving.append(path)
            case .discard: discarding.append(path)
            case .cancel: return false
            }
        }
        if persistsSession { saveSession(); saveRecoveries() }
        for path in saving where !(panes[path]?.save() ?? true) { return false }
        for path in saving + discarding { closeTab(path, force: true) }
        stopWatchingDisk()
        fetchTimer?.invalidate()
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
        let mark = gitStatus?.mark(of: relativePath(of: node.url), isDirectory: node.isDirectory)
        cell.textField?.textColor = AppPreferences.git.showColours ? Self.nameColour(for: mark) : .labelColor
        if !node.isDirectory, errorPaths.contains(node.url.path), let field = cell.textField {
            let marked = NSMutableAttributedString(string: node.url.lastPathComponent, attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: field.textColor ?? NSColor.labelColor])
            marked.append(NSAttributedString(string: "  !", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.systemRed]))
            field.attributedStringValue = marked
        }
        return cell
    }

    private static func nameColour(for mark: GitMark?) -> NSColor {
        switch mark {
        case .modified: return .systemOrange
        case .added, .untracked: return .systemGreen
        case .renamed: return .systemBlue
        case .deleted, .conflict: return .systemRed
        case .ignored: return .tertiaryLabelColor
        case nil: return .labelColor
        }
    }

    // MARK: drag and drop in the explorer (rows can be dragged onto a folder to move them there)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? { (item as? FileNode).map { $0.url as NSURL } }

    /// Whether `urls` may be moved into `folder`: inside the project, not into themselves, not where they already are.
    func explorerDropAllowed(_ urls: [URL], onto folder: URL) -> Bool {
        guard !urls.isEmpty, folder.path == root.path || isInsideProject(folder) else { return false }
        for url in urls {
            guard isInsideProject(url) else { return false }
            if FileOperations.isSameOrInside(folder.path, root: url.path) { return false }   // into itself or below itself
        }
        return urls.contains { $0.deletingLastPathComponent().path != folder.path }
    }

    @discardableResult
    func performExplorerDrop(_ urls: [URL], onto folder: URL) -> Bool {
        guard explorerDropAllowed(urls, onto: folder) else { return false }
        return !moveItems(urls, to: folder).isEmpty
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The folder a drop on `item` lands in: the folder itself, the folder of a file, or the project folder.
    private func dropFolder(for item: Any?) -> (folder: URL, node: FileNode?) {
        guard let node = item as? FileNode else { return (root, nil) }
        if node.isDirectory { return (node.url, node) }
        return (node.url.deletingLastPathComponent(), nil)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let target = dropFolder(for: item)
        // Always drop ON the folder, never between rows.
        outlineView.setDropItem(target.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return explorerDropAllowed(droppedURLs(info), onto: target.folder) ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        performExplorerDrop(droppedURLs(info), onto: dropFolder(for: item).folder)
    }

    /// A double click on a folder opens (or closes) it; a file is already open from the single click.
    @objc private func explorerDoubleClicked() { activateExplorerRow(outline.clickedRow) }

    func activateExplorerRow(_ row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, node.isDirectory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// For tests: the row of a top-level entry of the explorer, and whether it is expanded.
    func explorerRow(named name: String) -> Int? {
        (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.url.lastPathComponent == name }
    }
    func isExplorerRowExpanded(_ row: Int) -> Bool { (outline.item(atRow: row) as? FileNode).map { outline.isItemExpanded($0) } ?? false }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isReloadingExplorer { return }
        // Every selected file gets a tab, so shift- or command-clicking several files opens them all.
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }.filter { !$0.isDirectory }
        openFiles(selected.map(\.url))
    }
}
