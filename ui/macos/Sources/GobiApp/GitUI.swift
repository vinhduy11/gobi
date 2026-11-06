import AppKit
import GobiModel

/// The Source control block under the Explorer (Main mock): the branch, the changed files with their letters, and Commit….
final class SourceControlView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let branch = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let commit = NSButton(title: "Commit…", target: nil, action: nil)
    private(set) var files: [GitFile] = []
    var onCommit: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }
    var onShowDiff: (String) -> Void = { _ in }

    var branchText: String { branch.stringValue }
    var rowTexts: [String] { files.map { $0.mark.badge + " " + $0.path } }
    var commitEnabled: Bool { commit.isEnabled }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let header = NSTextField(labelWithString: "SOURCE CONTROL")
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        branch.font = NSFont.systemFont(ofSize: 12)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowOpened)
        table.setAccessibilityLabel("Changed files")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        commit.target = self
        commit.action = #selector(commitPressed)
        commit.bezelStyle = .rounded
        commit.isEnabled = false
        let rule = NSBox()
        rule.boxType = .separator
        let stack = NSStackView(views: [rule, header, branch, scroll, commit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24), commit.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ status: GitStatus?) {
        guard let status, !status.branch.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        files = status.changedFiles
        branch.stringValue = status.branch + (status.ahead > 0 ? "   ↑\(status.ahead)" : "") + (status.behind > 0 ? "   ↓\(status.behind)" : "")
        commit.isEnabled = !files.isEmpty
        table.reloadData()
    }

    @objc private func commitPressed() { onCommit() }
    @objc private func rowOpened() { if table.clickedRow >= 0, files.indices.contains(table.clickedRow) { onOpen(files[table.clickedRow].path) } }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        GitUI.fileRow(files[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0, files.indices.contains(table.selectedRow) { onShowDiff(files[table.selectedRow].path) }
    }
}

enum GitUI {
    static func colour(for mark: GitMark) -> NSColor {
        switch mark {
        case .modified: return .systemOrange
        case .added, .untracked: return .systemGreen
        case .renamed: return .systemBlue
        case .deleted, .conflict: return .systemRed
        case .ignored: return .tertiaryLabelColor
        }
    }

    static func fileRow(_ file: GitFile) -> NSView {
        let badge = NSTextField(labelWithString: file.mark.badge)
        badge.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badge.textColor = colour(for: file.mark)
        badge.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let name = NSTextField(labelWithString: file.path)
        name.font = NSFont.systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingHead
        let stack = NSStackView(views: [badge, name])
        stack.spacing = 6
        return stack
    }

    /// Diff text with coloured added and removed lines.
    static func attributed(diff: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for line in DiffLine.parse(diff) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch line.kind {
            case .added: attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
            case .removed: attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.16)
            case .hunk: attributes[.foregroundColor] = NSColor.secondaryLabelColor; attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06)
            case .header: attributes[.foregroundColor] = NSColor.secondaryLabelColor
            case .context: break
            }
            result.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
        }
        return result
    }
}

/// The Git tab of the bottom panel (Git mock): Changes (staged and unstaged files with their diff) and Log.
final class GitPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let mode = NSSegmentedControl(labels: ["Changes", "Log"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let filesTable = NSTableView()
    private let logTable = NSTableView()
    private let diffView = NSTextView()
    private let changesBox = NSStackView()
    private let logScroll = NSScrollView()
    private enum Row { case section(String), file(GitFile, staged: Bool) }
    private var rows: [Row] = []
    private(set) var commits: [GitCommit] = []
    var onSelectFile: (String, Bool) -> Void = { _, _ in }
    var onStage: (String) -> Void = { _ in }
    var onUnstage: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onShowLog: () -> Void = {}
    var onPull: () -> Void = {}
    var onPush: () -> Void = {}
    var onDiscard: (String) -> Void = { _ in }
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)
    var pushTitle: String { pushButton.title }

    var diffText: String { diffView.string }
    var sectionTitles: [String] { rows.compactMap { if case .section(let t) = $0 { return t } else { return nil } } }
    var fileTitles: [String] { rows.compactMap { if case .file(let f, _) = $0 { return f.path } else { return nil } } }
    var statusText: String { status.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 12)
        let bar = NSStackView(views: [mode, NSView(), status])
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 12)
        bar.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        filesTable.addTableColumn(column)
        filesTable.headerView = nil
        filesTable.rowHeight = 22
        filesTable.style = .plain
        filesTable.backgroundColor = .clear
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.setAccessibilityLabel("Changes")
        let filesScroll = NSScrollView()
        filesScroll.documentView = filesTable
        filesScroll.hasVerticalScroller = true
        filesScroll.drawsBackground = false
        filesScroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let commit = NSButton(title: "Commit…", target: self, action: #selector(commitPressed))
        commit.bezelStyle = .rounded
        let pullButton = NSButton(title: "Pull", target: self, action: #selector(pullPressed))
        pullButton.bezelStyle = .rounded
        pullButton.toolTip = "Fast-forward only"
        pushButton.target = self
        pushButton.action = #selector(pushPressed)
        pushButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [commit, pullButton, pushButton])
        buttons.spacing = 6
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Discard Changes…", action: #selector(discardPressed), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        filesTable.menu = menu
        let left = NSStackView(views: [filesScroll, buttons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 6)
        diffView.isEditable = false
        diffView.drawsBackground = false
        diffView.textContainerInset = NSSize(width: 8, height: 6)
        diffView.setAccessibilityLabel("Diff")
        let diffScroll = NSScrollView()
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.drawsBackground = false
        changesBox.orientation = .horizontal
        changesBox.spacing = 0
        changesBox.alignment = .top
        changesBox.addArrangedSubview(left)
        changesBox.addArrangedSubview(diffScroll)
        for part in [left, diffScroll] { part.topAnchor.constraint(equalTo: changesBox.topAnchor).isActive = true; part.bottomAnchor.constraint(equalTo: changesBox.bottomAnchor).isActive = true }

        for (id, title, width) in [("hash", "Commit", 80), ("subject", "Message", 460), ("author", "Author", 130), ("when", "When", 130)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            logTable.addTableColumn(c)
        }
        logTable.dataSource = self
        logTable.delegate = self
        logTable.rowHeight = 22
        logTable.style = .plain
        logTable.backgroundColor = .clear
        logTable.setAccessibilityLabel("Log")
        logScroll.documentView = logTable
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.isHidden = true

        let all = NSStackView(views: [bar, changesBox, logScroll])
        all.orientation = .vertical
        all.spacing = 0
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: all.widthAnchor), changesBox.widthAnchor.constraint(equalTo: all.widthAnchor), logScroll.widthAnchor.constraint(equalTo: all.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ status: GitStatus?) {
        rows = []
        if let status {
            let staged = status.stagedFiles, unstaged = status.unstagedFiles
            if !staged.isEmpty { rows.append(.section("STAGED")); rows += staged.map { .file($0, staged: true) } }
            if !unstaged.isEmpty { rows.append(.section("CHANGES")); rows += unstaged.map { .file($0, staged: false) } }
            self.status.stringValue = status.branch + (status.ahead > 0 ? " ↑\(status.ahead)" : "") + (status.behind > 0 ? " ↓\(status.behind)" : "")
            pushButton.title = status.ahead > 0 ? "Push ↑\(status.ahead)" : "Push"
        } else {
            self.status.stringValue = "Not a git repository"
        }
        filesTable.reloadData()
    }

    func show(diff: String) {
        diffView.textStorage?.setAttributedString(diff.isEmpty ? NSAttributedString(string: "No changes to show.", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]) : GitUI.attributed(diff: diff))
    }

    func show(log: [GitCommit]) { commits = log; logTable.reloadData() }

    @objc private func modeChanged() {
        changesBox.isHidden = mode.selectedSegment != 0
        logScroll.isHidden = mode.selectedSegment != 1
        if mode.selectedSegment == 1 { onShowLog() }
    }

    func showLogTab() { mode.selectedSegment = 1; modeChanged() }
    @objc private func commitPressed() { onCommit() }
    @objc private func pullPressed() { onPull() }
    @objc private func pushPressed() { onPush() }

    @objc private func discardPressed() {
        guard let path = discardTarget() else { return }
        onDiscard(path)
    }

    /// The file under the right-click, or the selected one.
    private func discardTarget() -> String? {
        let row = filesTable.clickedRow >= 0 ? filesTable.clickedRow : filesTable.selectedRow
        guard rows.indices.contains(row), case .file(let file, _) = rows[row] else { return nil }
        return file.path
    }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === filesTable ? rows.count : commits.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableView === filesTable && { if case .section = rows[row] { return true } else { return false } }()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === logTable ? true : { if case .file = rows[row] { return true } else { return false } }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === logTable {
            let commit = commits[row]
            let text: String
            switch tableColumn?.identifier.rawValue {
            case "hash": text = commit.shortHash
            case "subject": text = commit.subject
            case "author": text = commit.author
            default: text = commit.when
            }
            let label = NSTextField(labelWithString: text)
            label.font = tableColumn?.identifier.rawValue == "hash" ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
            label.textColor = tableColumn?.identifier.rawValue == "subject" ? .labelColor : .secondaryLabelColor
            return label
        }
        switch rows[row] {
        case .section(let title):
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .file(let file, let staged):
            let line = GitUI.fileRow(file)
            let button = NSButton(title: staged ? "−" : "+", target: self, action: #selector(toggleStage(_:)))
            button.isBordered = false
            button.toolTip = staged ? "Unstage" : "Stage"
            button.identifier = NSUserInterfaceItemIdentifier((staged ? "u:" : "s:") + file.path)
            let stack = NSStackView(views: [line, NSView(), button])
            stack.spacing = 4
            return stack
        }
    }

    @objc private func toggleStage(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.count > 2 else { return }
        let path = String(id.dropFirst(2))
        if id.hasPrefix("u:") { onUnstage(path) } else { onStage(path) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === filesTable, filesTable.selectedRow >= 0, rows.indices.contains(filesTable.selectedRow), case .file(let file, let staged) = rows[filesTable.selectedRow] else { return }
        onSelectFile(file.path, staged)
    }
}
