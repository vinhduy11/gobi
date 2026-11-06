import AppKit
import GobiClient
import GobiModel

/// Go Toolchains (Run > Manage Go Toolchains…) per the Toolchains mock. Shows what is installed and what go.mod asks for.
/// Choosing a default, installing versions and running on several versions need a toolchain service and are drawn disabled.
final class ToolchainsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The project whose Go choice this window edits (the front project when it was opened).
    weak var project: ProjectWindowController?
    private let mode = NSSegmentedControl(labels: ["Auto (go.mod)", "Pinned", "Installed only"], trackingMode: .selectOne, target: nil, action: nil)
    private let update = NSTextField(labelWithString: "")
    private(set) var installSheet: InstallVersionSheet?
    private let table = NSTableView()
    private let note = NSTextField(labelWithString: "")
    private(set) var installs: [GoInstall] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.title = "Go Toolchains"
        let heading = NSTextField(labelWithString: "THIS PROJECT")
        heading.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        mode.target = self
        mode.action = #selector(modeChanged)
        update.textColor = .systemOrange
        note.textColor = .secondaryLabelColor
        let installedHeading = NSTextField(labelWithString: "INSTALLED")
        installedHeading.font = heading.font
        installedHeading.textColor = .secondaryLabelColor
        for (title, id) in [("Version", "version"), ("Source", "source"), ("Location", "location"), ("Status", "status")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = id == "location" ? 220 : 110
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Installed Go versions")
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let install = NSButton(title: "+ Install version…", target: self, action: #selector(installVersion))
        let updates = NSButton(title: "Check for updates", target: self, action: #selector(checkForUpdates))
        let hint = NSTextField(wrappingLabelWithString: "The selected version is used for Run, Test and gopls. Pinned uses the version selected in the list; Auto follows go.mod.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12)
        let stack = NSStackView(views: [heading, mode, note, installedHeading, scroll, NSStackView(views: [install, updates]), update, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Reads what is installed (runs `go`, so it hops off the main thread) and the project's go.mod.
    func reload(projectRoot: URL?) {
        let goMod = projectRoot.flatMap { try? String(contentsOf: $0.appendingPathComponent("go.mod"), encoding: .utf8) }
        note.stringValue = GoInstalls.projectNote(goMod.map(GoModFacts.parse))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = GoInstalls.merge(system: GoTool.system(), sdk: GoTool.sdkInstalls())
            DispatchQueue.main.async { self?.installs = found; self?.table.reloadData(); self?.sync() }
        }
    }

    var noteText: String { note.stringValue }
    var updateText: String { update.stringValue }
    var selectedMode: Int { mode.selectedSegment }

    /// Shows the project's current choice in the controls.
    func sync() {
        guard let selection = project?.toolchainSelection else { return }
        mode.selectedSegment = [.auto, .pinned, .installedOnly].firstIndex(of: selection.mode) ?? 0
        if selection.mode == .pinned, let row = installs.firstIndex(where: { $0.version == selection.pinnedVersion }) { table.selectRowIndexes([row], byExtendingSelection: false) }
    }

    @objc private func modeChanged() {
        guard let project else { return }
        switch mode.selectedSegment {
        case 1:
            let version = table.selectedRow >= 0 && table.selectedRow < installs.count ? installs[table.selectedRow].version : installs.first?.version
            project.selectToolchain(version: version)
        case 2: project.setToolchain(ToolchainSelection(mode: .installedOnly))
        default: project.selectToolchain(version: nil)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard mode.selectedSegment == 1, table.selectedRow >= 0, table.selectedRow < installs.count else { return }
        project?.selectToolchain(version: installs[table.selectedRow].version)
    }

    @objc func installVersion() {
        guard let window else { return }
        let sheet = InstallVersionSheet(installed: installs)
        sheet.onInstalled = { [weak self] in
            self?.reload(projectRoot: self?.project?.root)
            self?.project?.loadGoInstalls()
        }
        installSheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow) }
        sheet.load()
    }

    @objc private func checkForUpdates() {
        update.stringValue = "Checking…"
        let known = installs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [String] in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.toolchainAvailable()
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let available): self?.show(update: GoInstalls.updateNotice(available: available, installed: known))
                case .failure(let error): self?.update.stringValue = "Cannot check: \(error)"
                }
            }
        }
    }

    func show(update notice: GoUpdate?) {
        update.stringValue = notice.map { "go\($0.available) is available (you have go\($0.installed)). Use Install version… to get it." } ?? "Go is up to date."
    }

    func numberOfRows(in tableView: NSTableView) -> Int { installs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let install = installs[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "version": text = "go" + install.version
        case "source": text = install.source
        case "location": text = install.location
        default: text = install.source == "System" ? "Default" : "Ready"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
