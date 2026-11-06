import AppKit
import GobiModel

/// The sidebar's Commit tab (Git mock), laid out like IntelliJ's Commit tool window: Commit / Stash / Log segments, a toolbar,
/// the changes tree with a checkbox per file (checked means staged), then Amend, the message and the commit buttons.
final class CommitPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let modeControl = NSSegmentedControl(labels: CommitPanelMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let branchLabel = NSTextField(labelWithString: "")
    private let changesTable = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: ChangesTree.emptyText)
    private let amendBox = NSButton(checkboxWithTitle: "Amend", target: nil, action: nil)
    private let messageView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "Commit Message")
    private let warningLabel = NSTextField(labelWithString: "")
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let pushButton = NSButton(title: "Commit and Push", target: nil, action: nil)
    private let commitPage = NSStackView()
    private var rollbackButton = NSButton()

    private let stashTable = NSTableView()
    private let stashEmpty = NSTextField(labelWithString: "No stashes")
    private let stashPage = NSStackView()
    private var stashButtons: [NSButton] = []
    private let logTable = NSTableView()
    private let logEmpty = NSTextField(labelWithString: "No commits yet")
    private let logPage = NSView()

    private var tree = ChangesTree(files: [])
    private var changeCount = 0
    private(set) var commits: [GitCommit] = []
    private(set) var stashes: [StashEntry] = []
    private(set) var selectedPath: String?

    var onRefresh: () -> Void = {}
    var onRollback: (String) -> Void = { _ in }
    var onPull: () -> Void = {}
    var onShowDiff: (String) -> Void = { _ in }
    var onToggle: (ChangesTree.Toggle) -> Void = { _ in }
    var onCommit: (_ message: String, _ amend: Bool, _ push: Bool) -> Void = { _, _, _ in }
    var onAmend: (Bool) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onModeChanged: (CommitPanelMode) -> Void = { _ in }
    var onStashNew: () -> Void = {}
    var onStashApply: (Int) -> Void = { _ in }
    var onStashPop: (Int) -> Void = { _ in }
    var onStashDrop: (Int) -> Void = { _ in }

    var mode: CommitPanelMode {
        get { CommitPanelMode(rawValue: modeControl.selectedSegment) ?? .commit }
        set {
            modeControl.selectedSegment = newValue.rawValue
            commitPage.isHidden = newValue != .commit
            stashPage.isHidden = newValue != .stash
            logPage.isHidden = newValue != .log
        }
    }

    // MARK: what the self-test reads

    var fileTitles: [String] { tree.rows.compactMap { if case .file(let file) = $0 { return file.path } else { return nil } } }
    var sectionTitles: [String] { tree.sections.map(\.title) }
    var isEmptyShown: Bool { !emptyLabel.isHidden }
    var stashTitles: [String] { stashes.map(\.title) }
    var branchText: String { branchLabel.stringValue }
    var messageText: String { messageView.string }
    var warningText: String { warningLabel.stringValue }
    var commitEnabled: Bool { commitButton.isEnabled }
    var commitAndPushEnabled: Bool { pushButton.isEnabled }
    var isAmending: Bool { amendBox.state == .on }
    var messageHasFocus: Bool { window?.firstResponder === messageView }
    func checkState(of path: String) -> ChangesTree.CheckState? {
        for section in tree.sections { if let file = section.files.first(where: { $0.path == path }) { return ChangesTree.checkState(of: file) } }
        return nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .texturedRounded
        modeControl.setAccessibilityLabel("Commit view")
        branchLabel.font = NSFont.systemFont(ofSize: 11)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel.setAccessibilityLabel("Branch")
        let header = NSStackView(views: [modeControl, NSView(), branchLabel])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 2, right: 10)

        buildCommitPage()
        buildStashPage()
        buildLogPage()

        let all = NSStackView(views: [header, commitPage, stashPage, logPage])
        all.orientation = .vertical
        all.spacing = 4
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for part in [header, commitPage, stashPage, logPage] { part.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true }
        for page in [commitPage, stashPage, logPage] { page.setContentHuggingPriority(.defaultLow, for: .vertical) }
        mode = .commit
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: building

    private static func icon(_ symbol: String, _ label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func table(_ table: NSTableView, label: String, rowHeight: CGFloat) -> NSScrollView {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.rowHeight = rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    private func overlay(_ label: NSTextField, on scroll: NSView) {
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28)])
    }

    private func buildCommitPage() {
        rollbackButton = Self.icon("arrow.uturn.backward", "Roll Back selected file", target: self, action: #selector(rollbackPressed))
        let tools = NSStackView(views: [
            Self.icon("arrow.clockwise", "Refresh", target: self, action: #selector(refreshPressed)), rollbackButton,
            Self.icon("arrow.down.to.line", "Update (fast-forward pull)", target: self, action: #selector(pullPressed)),
            Self.icon("eye", "Show Diff", target: self, action: #selector(diffPressed)), Self.separator(),
            Self.icon("chevron.down.2", "Expand all", target: self, action: #selector(expandPressed)),
            Self.icon("chevron.up.2", "Collapse all", target: self, action: #selector(collapsePressed)), NSView(),
        ])
        tools.spacing = 10
        tools.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 10)

        let scroll = table(changesTable, label: "Changes", rowHeight: 22)
        changesTable.target = self
        changesTable.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.addItem(MenuIconImage.apply(to: NSMenuItem(title: "Show Diff", action: #selector(diffPressed), keyEquivalent: ""), title: "Show Diff"))
        menu.addItem(MenuIconImage.apply(to: NSMenuItem(title: "Roll Back…", action: #selector(rollbackPressed), keyEquivalent: ""), title: "Roll Back…"))
        menu.items.forEach { $0.target = self }
        changesTable.menu = menu
        overlay(emptyLabel, on: scroll)

        amendBox.target = self
        amendBox.action = #selector(amendChanged)
        amendBox.setAccessibilityLabel("Amend")
        amendBox.toolTip = "Replace the last commit instead of adding a new one"
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.font = NSFont.systemFont(ofSize: 12)
        messageView.textContainerInset = NSSize(width: 4, height: 5)
        messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        messageView.delegate = self
        messageView.setAccessibilityLabel("Commit Message")
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = NSFont.systemFont(ofSize: 12)
        placeholder.frame.origin = NSPoint(x: 8, y: 5)
        placeholder.sizeToFit()
        messageView.addSubview(placeholder)
        warningLabel.textColor = .systemOrange
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.isHidden = true
        warningLabel.setAccessibilityLabel("Commit message warning")

        commitButton.target = self
        commitButton.action = #selector(commitPressed)
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = ""
        commitButton.toolTip = "Commit the ticked files (all changes when none is ticked)"
        pushButton.target = self
        pushButton.action = #selector(commitAndPushPressed)
        pushButton.bezelStyle = .rounded
        pushButton.toolTip = "Commit, then push"
        let gear = Self.icon("gearshape", "Git settings", target: self, action: #selector(settingsPressed))
        let buttons = NSStackView(views: [commitButton, pushButton, NSView(), gear])
        buttons.spacing = 6

        let form = NSStackView(views: [Hairline(), amendBox, messageScroll, warningLabel, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 5
        form.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        for part in form.arrangedSubviews { part.widthAnchor.constraint(equalTo: form.widthAnchor, constant: part is Hairline ? 0 : -20).isActive = true }

        commitPage.orientation = .vertical
        commitPage.alignment = .leading
        commitPage.spacing = 2
        for part in [tools, scroll, form] { commitPage.addArrangedSubview(part); part.widthAnchor.constraint(equalTo: commitPage.widthAnchor).isActive = true }
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }

    private func buildStashPage() {
        let new = NSButton(title: "Stash Changes…", target: self, action: #selector(stashNewPressed))
        new.bezelStyle = .rounded
        new.setAccessibilityLabel("Stash Changes")
        let scroll = table(stashTable, label: "Stashes", rowHeight: 40)
        overlay(stashEmpty, on: scroll)
        stashButtons = [("Apply", #selector(stashApplyPressed)), ("Pop", #selector(stashPopPressed)), ("Drop", #selector(stashDropPressed))].map { title, action in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.setAccessibilityLabel("\(title) stash")
            button.isEnabled = false
            return button
        }
        let buttons = NSStackView(views: stashButtons)
        buttons.distribution = .fillEqually
        buttons.spacing = 6
        let top = NSStackView(views: [new])
        top.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        let bottom = NSStackView(views: [Hairline(), buttons])
        bottom.orientation = .vertical
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        stashPage.orientation = .vertical
        stashPage.alignment = .leading
        stashPage.spacing = 4
        for part in [top, scroll, bottom] { stashPage.addArrangedSubview(part); part.widthAnchor.constraint(equalTo: stashPage.widthAnchor).isActive = true }
        buttons.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -20).isActive = true
        new.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -20).isActive = true
    }

    private func buildLogPage() {
        let scroll = table(logTable, label: "Log", rowHeight: 40)
        overlay(logEmpty, on: scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logPage.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: logPage.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: logPage.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: logPage.topAnchor), scroll.bottomAnchor.constraint(equalTo: logPage.bottomAnchor),
        ])
    }

    // MARK: data

    func show(_ status: GitStatus?) {
        let files = status?.changedFiles ?? []
        tree = tree.updated(files: files)
        changeCount = files.count
        if let status {
            branchLabel.stringValue = status.branch + (status.ahead > 0 ? " ↑\(status.ahead)" : "") + (status.behind > 0 ? " ↓\(status.behind)" : "")
        } else {
            branchLabel.stringValue = "Not a git repository"
        }
        reloadTree()
        updateButtons()
    }

    func show(log: [GitCommit]) {
        commits = log
        logEmpty.isHidden = !log.isEmpty
        logTable.reloadData()
    }

    func show(stashes list: [StashEntry]) {
        stashes = list
        stashEmpty.isHidden = !list.isEmpty
        stashTable.reloadData()
        updateStashButtons()
    }

    private func reloadTree() {
        changesTable.reloadData()
        emptyLabel.isHidden = !tree.isEmpty
        if let path = selectedPath, let row = tree.rows.firstIndex(where: { if case .file(let file) = $0 { return file.path == path } else { return false } }) {
            changesTable.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            selectedPath = nil
        }
    }

    func setMessage(_ text: String) {
        messageView.string = text
        updateButtons()
    }

    func clearMessage() {
        amendBox.state = .off
        setMessage("")
    }

    func focusMessage() { window?.makeFirstResponder(messageView) }

    /// Ticks or unticks Amend as the checkbox does.
    func toggleAmend(_ on: Bool) {
        amendBox.state = on ? .on : .off
        amendChanged()
    }

    func updateButtons() {
        let state = CommitButtonState(message: messageView.string, hasChanges: changeCount > 0, amend: isAmending, warnLongSubject: AppPreferences.git.warnLongSubject)
        commitButton.isEnabled = state.enabled
        pushButton.isEnabled = state.enabled
        warningLabel.stringValue = state.warning ?? ""
        warningLabel.isHidden = state.warning == nil
        placeholder.isHidden = !messageView.string.isEmpty
        rollbackButton.isEnabled = selectedPath != nil
    }

    private func updateStashButtons() {
        let selected = stashTable.selectedRow >= 0 && stashes.indices.contains(stashTable.selectedRow)
        for button in stashButtons { button.isEnabled = selected }
    }

    // MARK: actions (the self-test calls the same ones)

    @objc private func modeChanged() {
        let chosen = mode
        mode = chosen
        onModeChanged(chosen)
    }

    @objc private func refreshPressed() { onRefresh() }
    @objc private func pullPressed() { onPull() }
    @objc private func settingsPressed() { onSettings() }
    @objc private func amendChanged() { updateButtons(); onAmend(isAmending) }
    @objc func commitPressed() { if commitButton.isEnabled { onCommit(messageView.string, isAmending, false) } }
    @objc func commitAndPushPressed() { if pushButton.isEnabled { onCommit(messageView.string, isAmending, true) } }
    @objc private func stashNewPressed() { onStashNew() }
    @objc private func expandPressed() { tree.expandAll(); reloadTree() }
    @objc private func collapsePressed() { tree.collapseAll(); reloadTree() }

    @objc func rollbackPressed() { if let path = targetPath() { onRollback(path) } }
    @objc func diffPressed() { if let path = targetPath() { onShowDiff(path) } }
    @objc private func rowDoubleClicked() { if let path = path(atRow: changesTable.clickedRow) { onShowDiff(path) } }

    @objc func stashApplyPressed() { if let stash = selectedStash() { onStashApply(stash.index) } }
    @objc func stashPopPressed() { if let stash = selectedStash() { onStashPop(stash.index) } }
    @objc func stashDropPressed() { if let stash = selectedStash() { onStashDrop(stash.index) } }

    func selectFile(_ path: String) {
        guard let row = tree.rows.firstIndex(where: { if case .file(let file) = $0 { return file.path == path } else { return false } }) else { return }
        changesTable.selectRowIndexes([row], byExtendingSelection: false)
    }

    func selectStash(at position: Int) {
        guard stashes.indices.contains(position) else { return }
        stashTable.selectRowIndexes([position], byExtendingSelection: false)
    }

    /// Ticks or unticks a file as its checkbox does.
    func toggleFile(_ path: String) {
        for section in tree.sections { if let file = section.files.first(where: { $0.path == path }) { onToggle(ChangesTree.toggle(file: file)) } }
    }

    private func selectedStash() -> StashEntry? { stashes.indices.contains(stashTable.selectedRow) ? stashes[stashTable.selectedRow] : nil }

    private func path(atRow row: Int) -> String? {
        guard tree.rows.indices.contains(row), case .file(let file) = tree.rows[row] else { return nil }
        return file.path
    }

    /// The file under the right-click, or the selected one.
    private func targetPath() -> String? { path(atRow: changesTable.clickedRow) ?? selectedPath }

    @objc private func fileBoxPressed(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        toggleFile(path)
    }

    @objc private func groupBoxPressed(_ sender: NSButton) {
        guard tree.sections.indices.contains(sender.tag) else { return }
        onToggle(tree.sections[sender.tag].toggle())
    }

    @objc private func disclosurePressed(_ sender: NSButton) {
        guard tree.sections.indices.contains(sender.tag) else { return }
        tree.toggleCollapsed(tree.sections[sender.tag].group)
        reloadTree()
    }

    func textDidChange(_ notification: Notification) { updateButtons() }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === changesTable ? tree.rows.count : (tableView === stashTable ? stashes.count : commits.count)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === changesTable ? path(atRow: row) != nil : true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === changesTable {
            selectedPath = path(atRow: changesTable.selectedRow)
            updateButtons()
        } else if table === stashTable {
            updateStashButtons()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === stashTable { return Self.twoLine(stashes[row].title, nil, wrap: true) }
        if tableView === logTable {
            let commit = commits[row]
            return Self.twoLine(commit.subject, "\(commit.shortHash) · \(commit.author) · \(commit.when)", wrap: false)
        }
        switch tree.rows[row] {
        case .section(let section): return sectionRow(section)
        case .file(let file): return fileRow(file)
        }
    }

    private static func twoLine(_ title: String, _ detail: String?, wrap: Bool) -> NSView {
        let main = NSTextField(labelWithString: title)
        main.font = NSFont.systemFont(ofSize: 12)
        main.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        main.maximumNumberOfLines = wrap ? 2 : 1
        main.cell?.truncatesLastVisibleLine = true
        main.toolTip = title
        var views: [NSView] = [main]
        if let detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = NSFont.systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            views.append(sub)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        return stack
    }

    private func checkbox(_ state: ChangesTree.CheckState, label: String) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: nil)
        box.allowsMixedState = true
        box.state = state == .checked ? .on : (state == .mixed ? .mixed : .off)
        box.setAccessibilityLabel(label)
        return box
    }

    private func sectionRow(_ section: ChangesTree.Section) -> NSView {
        let index = tree.sections.firstIndex { $0.group == section.group } ?? 0
        let arrow = NSButton(image: NSImage(systemSymbolName: section.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: section.collapsed ? "Expand \(section.title)" : "Collapse \(section.title)") ?? NSImage(), target: self, action: #selector(disclosurePressed(_:)))
        arrow.isBordered = false
        arrow.imagePosition = .imageOnly
        arrow.tag = index
        arrow.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let box = checkbox(section.checkState, label: "\(section.title), all files")
        box.tag = index
        box.action = #selector(groupBoxPressed(_:))
        let title = NSTextField(labelWithString: section.title)
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let count = NSTextField(labelWithString: section.countText)
        count.font = NSFont.systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [arrow, box, title, count])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return stack
    }

    private func fileRow(_ file: GitFile) -> NSView {
        let box = checkbox(ChangesTree.checkState(of: file), label: "Include \(file.path) in the commit")
        box.identifier = NSUserInterfaceItemIdentifier(file.path)
        box.action = #selector(fileBoxPressed(_:))
        let (fileName, folder) = ChangesTree.nameAndFolder(file.path)
        let name = NSTextField(labelWithString: fileName)
        name.font = NSFont.systemFont(ofSize: 12)
        name.textColor = GitUI.colour(for: file.mark)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var views: [NSView] = [box, name]
        if !folder.isEmpty {
            let dir = NSTextField(labelWithString: folder)
            dir.font = NSFont.systemFont(ofSize: 11)
            dir.textColor = .secondaryLabelColor
            dir.lineBreakMode = .byTruncatingHead
            dir.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(dir)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 26, bottom: 0, right: 6)
        stack.toolTip = file.path
        return stack
    }
}
