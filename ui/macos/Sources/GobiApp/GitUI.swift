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

/// The Diff tab of the bottom panel (Git mock): the path of the selected file, then its coloured diff.
final class DiffPanelView: NSView {
    static let emptyText = "Select a changed file to see its diff."
    private let titleLabel = NSTextField(labelWithString: "")
    private let diffView = NSTextView()
    private(set) var path: String?

    var diffText: String { diffView.string }
    var titleText: String { titleLabel.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.setAccessibilityLabel("Diff file")
        diffView.isEditable = false
        diffView.drawsBackground = false
        diffView.textContainerInset = NSSize(width: 8, height: 6)
        diffView.setAccessibilityLabel("Diff")
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let header = NSStackView(views: [titleLabel])
        header.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        let stack = NSStackView(views: [header, Hairline(), scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showEmpty()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setNote(_ text: String) {
        diffView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
    }

    /// No file picked yet (or the picked one is no longer changed).
    func showEmpty() {
        path = nil
        titleLabel.stringValue = ""
        setNote(Self.emptyText)
    }

    func show(diff: String, path: String, staged: Bool) {
        self.path = path
        titleLabel.stringValue = path + (staged ? "  ·  staged changes" : "  ·  unstaged changes")
        if diff.isEmpty { setNote("No changes to show.") } else { diffView.textStorage?.setAttributedString(GitUI.attributed(diff: diff)) }
    }

    func show(error: String, path: String) {
        self.path = path
        titleLabel.stringValue = path
        setNote(error)
    }
}
