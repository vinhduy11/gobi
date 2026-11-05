import AppKit
import GobiModel

/// What the Welcome window shows for one recent project, read from its folder.
struct RecentRowFacts {
    let path: String
    let name: String
    let displayPath: String
    let badge: String?       // "go.mod" or "go.work · 3 modules"
    let isRestricted: Bool
    let branch: String       // branch, short hash, or "no git"

    init(project: RecentProject, isTrusted: Bool) {
        path = project.path
        name = (project.path as NSString).lastPathComponent
        displayPath = (project.path as NSString).abbreviatingWithTildeInPath
        switch project.kind {
        case .module: badge = "go.mod"
        case .workspace:
            let text = (try? String(contentsOfFile: project.path + "/go.work", encoding: .utf8)) ?? ""
            let count = GoWork.moduleCount(text)
            badge = count > 0 ? "go.work · \(count) module\(count == 1 ? "" : "s")" : "go.work"
        case .folder: badge = nil
        }
        isRestricted = !isTrusted
        let head = (try? String(contentsOfFile: project.path + "/.git/HEAD", encoding: .utf8)) ?? ""
        branch = GitHead.branch(head) ?? "no git"
    }
}

/// A small rounded label, used for the go.mod, go.work and Restricted badges.
private final class Chip: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    override var wantsUpdateLayer: Bool { true }
}

/// One of the four actions on the left: symbol, title, subtitle and shortcut, as in the mock.
private final class ActionRow: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, subtitle: String, shortcut: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = NSFont.systemFont(ofSize: 12)
        shortcutLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, texts, NSView(), shortcutLabel])
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48), icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(subtitle)")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// "Drag a folder here to open it": a dashed box that accepts a dropped folder, go.mod or go.work.
private final class DropZone: NSView {
    var onDrop: ((URL) -> Void)?
    private var isTargeted = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let label = NSTextField(labelWithString: "Drag a folder here to open it")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        setAccessibilityLabel("Drop a folder to open it")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        path.setLineDash([4, 3], count: 2, phase: 0)
        (isTargeted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isTargeted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

/// Shown when no project is open, laid out as in the Welcome mock: actions on the left, recent projects on the right.
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let versionLabel = NSTextField(labelWithString: "")
    private let showAtLaunch = NSButton(checkboxWithTitle: "Show this window when Gobi launches", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear recent…", target: nil, action: nil)
    private var rows: [RecentRowFacts] = []
    var onOpenFolder: (() -> Void)?
    var onNewProject: (() -> Void)?
    var onClone: (() -> Void)?
    var onImport: (() -> Void)?
    var onOpenRecent: ((RecentProject) -> Void)?
    var onDropFolder: ((URL) -> Void)?
    var onClearRecents: (() -> Void)?

    /// Paints the window into a PNG (used by `--selftest-welcome --snapshot`).
    func snapshotWindow(to path: String) { WindowSnapshot.write(window, to: path) }

    /// Number of recent rows shown, for the self-test.
    var visibleRowCount: Int { rows.count }
    var rowNames: [String] { rows.map(\.name) }

    init() {
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false))
        window?.title = "Welcome to Gobi"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        build()
        reload()
        loadGoVersion()
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        let trust = ProjectStore.shared.trust
        let query = search.stringValue
        var shown = ProjectStore.shared.recents
        let matches = shown.matching(query)
        shown = RecentProjects(limit: 100)
        for item in matches.reversed() { shown.add(path: item.path, kind: item.kind) }
        rows = shown.items.map { RecentRowFacts(project: $0, isTrusted: trust.isTrusted(path: $0.path)) }
        table.reloadData()
        clearButton.isEnabled = !ProjectStore.shared.recents.items.isEmpty
        showAtLaunch.state = ProjectStore.shared.showWelcomeAtLaunch ? .on : .off
    }

    private func loadGoVersion() {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        versionLabel.stringValue = "Version \(version)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let go = GoTool.version()
            DispatchQueue.main.async { self?.versionLabel.stringValue = "Version \(version) · " + (go.map { "Go \($0) ready" } ?? "Go not found") }
        }
    }

    // MARK: layout

    private func build() {
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true
        icon.setAccessibilityLabel("Gobi")
        let title = NSTextField(labelWithString: "Welcome to Gobi")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.stringValue = "Version"
        let brand = NSStackView(views: [icon, title, versionLabel])
        brand.orientation = .vertical
        brand.spacing = 4
        brand.setCustomSpacing(14, after: icon)

        let rowsData: [(String, String, String, String, () -> Void)] = [
            ("plus", "New Project…", "Create a Go module from a template", "⌘⇧N", { [weak self] in self?.onNewProject?() }),
            ("folder", "Open…", "Folder, go.mod or go.work", "⌘O", { [weak self] in self?.onOpenFolder?() }),
            ("arrow.triangle.branch", "Clone Repository…", "From a Git URL", "⌘⇧K", { [weak self] in self?.onClone?() }),
            ("square.and.arrow.down", "Import Existing Code…", "Folder without go.mod: create the module", "", { [weak self] in self?.onImport?() }),
        ]
        let actions = NSStackView(views: rowsData.map { symbol, name, subtitle, shortcut, handler in
            let row = ActionRow(symbol: symbol, title: name, subtitle: subtitle, shortcut: shortcut)
            row.onClick = handler
            return row
        })
        actions.orientation = .vertical
        actions.spacing = 2
        actions.alignment = .leading
        actions.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true }

        let drop = DropZone()
        drop.onDrop = { [weak self] url in self?.onDropFolder?(url) }

        let left = NSStackView(views: [brand, actions, NSView(), drop])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 28
        left.edgeInsets = NSEdgeInsets(top: 52, left: 28, bottom: 28, right: 28)
        left.translatesAutoresizingMaskIntoConstraints = false
        actions.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -56).isActive = true
        drop.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -56).isActive = true
        side.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: side.leadingAnchor), left.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            left.topAnchor.constraint(equalTo: side.topAnchor), left.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 420),
        ])

        // Right: header with search, recent rows, footer.
        let heading = NSTextField(labelWithString: "Recent projects")
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        search.placeholderString = "Search"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        search.setAccessibilityLabel("Search recent projects")
        let header = NSStackView(views: [heading, NSView(), search])
        header.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowActivated)
        table.setAccessibilityLabel("Recent projects")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        showAtLaunch.target = self
        showAtLaunch.action = #selector(showAtLaunchToggled)
        showAtLaunch.font = NSFont.systemFont(ofSize: 12)
        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.isBordered = false
        clearButton.font = NSFont.systemFont(ofSize: 12)
        let footer = NSStackView(views: [showAtLaunch, NSView(), clearButton])
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)

        let rule1 = NSBox(), rule2 = NSBox()
        rule1.boxType = .separator
        rule2.boxType = .separator
        let right = NSStackView(views: [header, rule1, scroll, rule2, footer])
        right.orientation = .vertical
        right.spacing = 0
        for part in [header, rule1, scroll, rule2, footer] { part.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }

        let content = NSStackView(views: [side, right])
        content.orientation = .horizontal
        content.spacing = 0
        content.alignment = .top
        side.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        window?.contentView = content
    }

    // MARK: actions

    @objc private func rowActivated() {
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        open(rows[table.clickedRow])
    }

    private func open(_ facts: RecentRowFacts) {
        guard let project = ProjectStore.shared.recents.items.first(where: { $0.path == facts.path }) else { return }
        onOpenRecent?(project)
    }

    @objc private func showAtLaunchToggled() { ProjectStore.shared.showWelcomeAtLaunch = showAtLaunch.state == .on }

    @objc private func clearPressed() {
        let alert = NSAlert()
        alert.messageText = "Clear the list of recent projects?"
        alert.informativeText = "The projects stay on disk; only this list is emptied."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onClearRecents?()
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let facts = rows[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: facts.isRestricted ? "folder" : "folder.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = facts.isRestricted ? .secondaryLabelColor : .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let name = NSTextField(labelWithString: facts.name)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let path = NSTextField(labelWithString: facts.displayPath)
        path.font = NSFont.systemFont(ofSize: 12)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [name, path])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        var views: [NSView] = [icon, texts, NSView()]
        if let badge = facts.badge { views.append(Chip(badge)) }
        if facts.isRestricted { views.append(Chip("Restricted")) }
        let branch = NSTextField(labelWithString: facts.branch)
        branch.font = NSFont.systemFont(ofSize: 12)
        branch.textColor = .secondaryLabelColor
        views.append(branch)
        let cell = NSStackView(views: views)
        cell.spacing = 12
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        cell.setAccessibilityLabel("\(facts.name), \(facts.displayPath), \(facts.branch)")
        return cell
    }
}

/// Finds the user's Go toolchain for the version line on the Welcome window.
enum GoTool {
    static func version() -> String? {
        let extra = ["/usr/local/go/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/go/bin"]
        let path = ((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + extra)
        guard let go = path.map({ $0 + "/go" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: go)
        process.arguments = ["env", "GOVERSION"]
        process.environment = ["GOTOOLCHAIN": "local", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return GoVersion.display(fromGoEnv: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
