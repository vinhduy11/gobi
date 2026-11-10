import AppKit
import GobiClient
import GobiEditor
import GobiModel

/// One labelled row of a settings pane: a right-aligned grey label, then the controls.
func settingsRow(_ title: String, _ controls: [NSView], labelWidth: CGFloat = 170) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.alignment = .right
    label.textColor = .secondaryLabelColor
    label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
    let stack = NSStackView(views: [label] + controls)
    stack.spacing = 12
    stack.alignment = .firstBaseline
    return stack
}

func settingsHint(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 12)
    return label
}

func settingsPopup(_ items: [String], enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: items)
    popup.isEnabled = enabled
    popup.target = target
    popup.action = action
    return popup
}

func settingsCheckbox(_ title: String, enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
    let box = NSButton(checkboxWithTitle: title, target: target, action: action)
    box.isEnabled = enabled
    return box
}

/// A pop-up for a program the user may point Gobi at: "Automatic" (the one on PATH), the chosen path when there is one, and
/// Choose… to pick a file. A path that is not an executable file is refused and the old value stays.
final class ToolPathChooser: NSObject {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let automatic: String
    private(set) var path = ""
    var onChange: (String) -> Void = { _ in }
    /// Replaced by the self-test so Choose… does not open a panel.
    var pick: () -> String? = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    init(automatic: String) {
        self.automatic = automatic
        super.init()
        popup.target = self
        popup.action = #selector(selected)
        show("")
    }

    var itemTitles: [String] { popup.itemTitles }

    func show(_ value: String) {
        path = value
        popup.removeAllItems()
        popup.addItem(withTitle: automatic)
        if !value.isEmpty { popup.addItem(withTitle: (value as NSString).abbreviatingWithTildeInPath) }
        popup.addItem(withTitle: "Choose…")
        popup.selectItem(at: value.isEmpty ? 0 : 1)
    }

    /// Takes a path from the user. Returns false (and keeps the old one) when it is not an executable file.
    @discardableResult
    func choose(_ candidate: String) -> Bool {
        let clean = ToolPath.clean(candidate)
        var isDirectory: ObjCBool = false
        guard !clean.isEmpty, FileManager.default.fileExists(atPath: clean, isDirectory: &isDirectory), !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: clean) else { show(path); return false }
        show(clean)
        onChange(clean)
        return true
    }

    @objc private func selected() {
        let index = popup.indexOfSelectedItem
        if index == 0 { show(""); onChange(""); return }
        if index == popup.numberOfItems - 1 {
            if let picked = pick() { choose(picked) } else { show(path) }
        }
    }
}

/// A column of rows, centred under the tabs, that a pane lays itself out with.
class SettingsPane: NSView {
    func install(_ rows: [NSView]) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.centerXAnchor.constraint(equalTo: centerXAnchor)])
    }

    func sync() {}
}

// MARK: General

final class GeneralSettingsPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    let launch = settingsPopup(["Reopen the last project", "Show the Welcome window"])
    let recents = settingsPopup(GeneralSettings.recentLimits.map(String.init))
    let confirmQuit = settingsCheckbox("Before quitting with unsaved changes or running work")
    /// Stays off: there is no update server to ask yet.
    let updates = settingsCheckbox("Check for updates automatically", enabled: false)
    let trustedTable = NSTableView()
    private(set) var trustedPaths: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for popup in [launch, recents] { popup.target = self; popup.action = #selector(changed) }
        confirmQuit.target = self
        confirmQuit.action = #selector(changed)
        updates.toolTip = "Gobi has no update server yet"
        let forget = NSButton(title: "Forget Recent Projects", target: self, action: #selector(forgetRecents))
        forget.bezelStyle = .rounded
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        trustedTable.addTableColumn(column)
        trustedTable.headerView = nil
        trustedTable.dataSource = self
        trustedTable.delegate = self
        trustedTable.rowHeight = 22
        trustedTable.setAccessibilityLabel("Trusted folders")
        let scroll = NSScrollView()
        scroll.documentView = trustedTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelectedTrusted))
        remove.bezelStyle = .rounded
        let trusted = NSStackView(views: [scroll, remove])
        trusted.alignment = .top
        install([
            settingsRow("On launch", [launch]),
            settingsRow("Recent projects", [recents, settingsHint("shown in the Welcome window and File > Open Recent")]),
            settingsRow("Confirm", [confirmQuit]),
            settingsRow("Updates", [updates]),
            settingsRow("Trusted folders", [trusted]),
            settingsRow("", [settingsHint("Projects inside a trusted folder open without asking. Others open in Restricted Mode until you trust them.")]),
            settingsRow("Reset", [forget]),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func sync() {
        let general = AppPreferences.general
        launch.selectItem(at: general.onLaunch == .welcome ? 1 : 0)
        recents.selectItem(at: GeneralSettings.recentLimits.firstIndex(of: general.recentLimit) ?? 1)
        confirmQuit.state = general.confirmQuit ? .on : .off
        trustedPaths = ProjectStore.shared.trust.paths
        trustedTable.reloadData()
    }

    @objc private func changed() {
        AppPreferences.update(\.general) {
            $0.onLaunch = launch.indexOfSelectedItem == 1 ? .welcome : .reopenLast
            $0.recentLimit = GeneralSettings.recentLimits[max(0, recents.indexOfSelectedItem)]
            $0.confirmQuit = confirmQuit.state == .on
        }
    }

    @objc private func forgetRecents() {
        var list = ProjectStore.shared.recents
        list.clear()
        ProjectStore.shared.recents = list
    }

    @objc private func removeSelectedTrusted() {
        guard trustedTable.selectedRow >= 0, trustedPaths.indices.contains(trustedTable.selectedRow) else { return }
        removeTrusted(path: trustedPaths[trustedTable.selectedRow])
    }

    func removeTrusted(path: String) {
        var list = ProjectStore.shared.trust
        list.remove(path: path)
        ProjectStore.shared.trust = list
        sync()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { trustedPaths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: (trustedPaths[row] as NSString).abbreviatingWithTildeInPath)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

// MARK: Terminal

final class TerminalSettingsPane: SettingsPane {
    let shell = settingsPopup(["Login shell"])
    let font = settingsPopup(TerminalFont.choices())
    let size = settingsPopup(TerminalSettings.fontSizes.map { "\($0) pt" })
    let iconHint = settingsHint(TerminalFonts.iconHint(chain: TerminalFont.iconChain()))
    let cursor = NSSegmentedControl(labels: ["Block", "Bar", "Underline"], trackingMode: .selectOne, target: nil, action: nil)
    let blink = settingsCheckbox("Blink")
    let optionAsMeta = settingsCheckbox("Use Option as Meta")
    let copyOnSelect = settingsCheckbox("Copy on select")
    let startIn = settingsPopup(["Project folder", "Home folder"])
    let scrollback = settingsPopup(TerminalSettings.scrollbackLines.map { AppSettingsText.lines($0) })
    let bell = settingsPopup(["Sound", "Off"])
    private var shells: [String] = []
    private var login = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        for control in [shell, font, size, bell, startIn, scrollback] { control.target = self; control.action = #selector(changed) }
        for box in [blink, optionAsMeta, copyOnSelect] { box.target = self; box.action = #selector(changed) }
        cursor.target = self
        cursor.action = #selector(changed)
        install([
            settingsRow("Shell", [shell]),
            settingsRow("Start in", [startIn, settingsHint("new terminals")]),
            settingsRow("Font", [font, size]),
            settingsRow("", [iconHint]),
            settingsRow("Cursor", [cursor, blink]),
            settingsRow("Scrollback", [scrollback, settingsHint("new terminals")]),
            settingsRow("Keys", [optionAsMeta, copyOnSelect]),
            settingsRow("Bell", [bell]),
            settingsRow("", [settingsHint("Terminals are off in Restricted Mode. Colours follow the app appearance. Changes apply to open terminals at once, except the shell, start folder and scrollback, which apply to new ones.")]),
        ])
        sync()
        loadShells()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadShells() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let client = try? ControlClient.connect() else { return }
            defer { client.close() }
            guard let found = try? client.terminalShells() else { return }
            DispatchQueue.main.async { self?.shells = found.shells; self?.login = found.login; self?.sync() }
        }
    }

    override func sync() {
        let items = ShellChoice.menuItems(shells: shells, login: login.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "") : login, selected: WindowSettings.terminalShell)
        shell.removeAllItems()
        shell.addItems(withTitles: items.isEmpty ? ["Login shell"] : items.map(\.title))
        if let index = items.firstIndex(where: \.isChecked) { shell.selectItem(at: index) }
        let settings = AppPreferences.terminal
        if font.itemTitles.contains(settings.fontName) { font.selectItem(withTitle: settings.fontName) } else { font.selectItem(at: 0) }
        iconHint.stringValue = TerminalFonts.iconHint(chain: TerminalFont.iconChain())
        size.selectItem(at: TerminalSettings.fontSizes.firstIndex(of: settings.fontSize) ?? 1)
        cursor.selectedSegment = [.block, .bar, .underline].firstIndex(of: settings.cursor) ?? 0
        blink.state = settings.blink ? .on : .off
        optionAsMeta.state = settings.optionAsMeta ? .on : .off
        bell.selectItem(at: settings.bell == .off ? 1 : 0)
        startIn.selectItem(at: settings.startIn == .home ? 1 : 0)
        scrollback.selectItem(at: TerminalSettings.scrollbackLines.firstIndex(of: settings.scrollback) ?? 2)
        copyOnSelect.state = settings.copyOnSelect ? .on : .off
    }

    var shellTitles: [String] { shell.itemTitles }

    @objc private func changed() {
        let items = ShellChoice.menuItems(shells: shells, login: login.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "") : login, selected: "")
        if items.indices.contains(shell.indexOfSelectedItem) { WindowSettings.terminalShell = items[shell.indexOfSelectedItem].path == login ? "" : items[shell.indexOfSelectedItem].path }
        AppPreferences.update(\.terminal) {
            $0.fontName = font.titleOfSelectedItem ?? "SF Mono"
            $0.fontSize = TerminalSettings.fontSizes[max(0, size.indexOfSelectedItem)]
            $0.cursor = [.block, .bar, .underline][max(0, cursor.selectedSegment)]
            $0.blink = blink.state == .on
            $0.optionAsMeta = optionAsMeta.state == .on
            $0.bell = bell.indexOfSelectedItem == 1 ? .off : .sound
            $0.startIn = startIn.indexOfSelectedItem == 1 ? .home : .project
            $0.scrollback = TerminalSettings.scrollbackLines[max(0, scrollback.indexOfSelectedItem)]
            $0.copyOnSelect = copyOnSelect.state == .on
        }
    }
}

// MARK: Git

final class GitSettingsPane: SettingsPane {
    let colours = settingsCheckbox("Colours for changed files in the Explorer")
    let gutter = settingsCheckbox("Marks in the editor gutter")
    let refresh = settingsCheckbox("Update status when the window is focused")
    let warn = settingsCheckbox("Warn when the first line is over 50")
    let gitPath = ToolPathChooser(automatic: "Automatic (git on PATH)")
    let fetch = settingsPopup(GitSettings.fetchIntervals.map { $0 == 0 ? "Never" : "Every \($0) minutes" })

    override init(frame: NSRect) {
        super.init(frame: frame)
        for box in [colours, gutter, refresh, warn] { box.target = self; box.action = #selector(changed) }
        fetch.target = self
        fetch.action = #selector(changed)
        gitPath.onChange = { [weak self] _ in self?.changed() }
        install([
            settingsRow("Git", [gitPath.popup, settingsHint("used by project windows opened or refreshed after the change")]),
            settingsRow("Author", [settingsHint("Read from your git config (user.name, user.email)")]),
            settingsRow("Show", [colours, gutter]),
            settingsRow("Refresh", [refresh]),
            settingsRow("Fetch", [fetch, settingsHint("Fetching uses the network and your credentials helper.")]),
            settingsRow("Commit message", [warn, settingsPopup(["Wrap at 72"], enabled: false)]),
            settingsRow("", [settingsHint("Git runs only in trusted projects: repository hooks and filters can run code.")]),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func sync() {
        let git = AppPreferences.git
        colours.state = git.showColours ? .on : .off
        gutter.state = git.showGutterMarks ? .on : .off
        refresh.state = git.refreshOnFocus ? .on : .off
        warn.state = git.warnLongSubject ? .on : .off
        gitPath.show(git.gitPath)
        fetch.selectItem(at: GitSettings.fetchIntervals.firstIndex(of: git.fetchMinutes) ?? 0)
    }

    @objc private func changed() {
        AppPreferences.update(\.git) {
            $0.showColours = colours.state == .on
            $0.showGutterMarks = gutter.state == .on
            $0.refreshOnFocus = refresh.state == .on
            $0.warnLongSubject = warn.state == .on
            $0.gitPath = gitPath.path
            $0.fetchMinutes = GitSettings.fetchIntervals[max(0, fetch.indexOfSelectedItem)]
        }
    }
}

// MARK: Advanced

final class AdvancedSettingsPane: SettingsPane {
    let daemon = NSTextField(labelWithString: "Checking…")
    let logLevel = settingsPopup(["Debug", "Info", "Warn", "Error"])
    let goplsPath = ToolPathChooser(automatic: "Automatic (GOBIN, GOPATH/bin, PATH)")
    let lineLimit = settingsPopup(AdvancedSettings.lineLimits.map { "Line over \(AdvancedSettings.lineLimitTitle($0)): read-only" })
    private(set) var daemonStatus: ControlClient.DaemonStatus?
    var onRestarted: () -> Void = {}
    var onCheckSetup: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        let restart = NSButton(title: "Restart", target: self, action: #selector(restartPressed))
        restart.bezelStyle = .rounded
        let logs = NSButton(title: "Open Logs Folder", target: self, action: #selector(logsPressed))
        logs.bezelStyle = .rounded
        let setup = NSButton(title: "Check Setup…", target: self, action: #selector(setupPressed))
        setup.bezelStyle = .rounded
        let reset = NSButton(title: "Reset All Settings…", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        logLevel.target = self
        logLevel.action = #selector(levelChanged)
        lineLimit.target = self
        lineLimit.action = #selector(advancedChanged)
        goplsPath.onChange = { [weak self] _ in self?.advancedChanged() }
        install([
            settingsRow("Daemon", [daemon, restart, logs]),
            settingsRow("Log level", [logLevel, settingsHint("what gobid writes to its log")]),
            settingsRow("Tools", [settingsHint("go, gopls, dlv, git"), setup]),
            settingsRow("gopls", [goplsPath.popup, settingsHint("open Go files restart their language server")]),
            settingsRow("Large files", [lineLimit, settingsHint("also applies to open files")]),
            settingsRow("Reset", [reset, settingsHint("Does not touch your projects, trusted folders or secrets.")]),
        ])
        syncStored()
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func sync() { syncStored(); refreshStatus() }

    private func syncStored() {
        let advanced = AppPreferences.advanced
        goplsPath.show(advanced.goplsPath)
        lineLimit.selectItem(at: AdvancedSettings.lineLimits.firstIndex(of: advanced.lineLimit) ?? 2)
    }

    @objc private func advancedChanged() {
        AppPreferences.update(\.advanced) {
            $0.goplsPath = goplsPath.path
            $0.lineLimit = AdvancedSettings.lineLimits[max(0, lineLimit.indexOfSelectedItem)]
        }
    }

    func refreshStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = try? { () -> ControlClient.DaemonStatus in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.daemonStatus()
            }()
            DispatchQueue.main.async { self?.show(status) }
        }
    }

    func show(_ status: ControlClient.DaemonStatus?) {
        daemonStatus = status
        guard let status else { daemon.stringValue = "gobid is not reachable"; return }
        daemon.stringValue = "gobid is running · pid \(status.pid) · \(status.runtime)"
        logLevel.selectItem(withTitle: status.logLevel.prefix(1).uppercased() + status.logLevel.dropFirst())
    }

    @objc private func levelChanged() {
        let level = (logLevel.titleOfSelectedItem ?? "Info").lowercased()
        DispatchQueue.global(qos: .utility).async {
            guard let client = try? ControlClient.connect() else { return }
            defer { client.close() }
            try? client.setLogLevel(level)
        }
    }

    @objc private func restartPressed() { restartDaemon() }

    /// Stops gobid; the next connection (made by the open files) starts a fresh one.
    func restartDaemon(then done: (() -> Void)? = nil) {
        AppLog.shared.logInfo("gobid restart requested")
        daemon.stringValue = "Restarting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let client = try? ControlClient.connect() { try? client.stopDaemon(); client.close() }
            Thread.sleep(forTimeInterval: 0.8)
            DispatchQueue.main.async {
                self?.onRestarted()
                self?.refreshStatus()
                done?()
            }
        }
    }

    @objc private func logsPressed() { LogSupport.revealLogs() }

    @objc private func setupPressed() { onCheckSetup() }

    @objc private func resetPressed() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Editor, terminal, git, keymap and general settings go back to their defaults. Projects, trusted folders and secrets are not touched."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        if alert.runModal() == .alertSecondButtonReturn { AppPreferences.resetAll() }
    }
}

// MARK: Keymap

final class KeymapSettingsPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private(set) var visible: [KeymapItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search commands or shortcuts…"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 320).isActive = true
        for (id, title, width) in [("command", "Command", 250), ("menu", "Menu", 150), ("shortcut", "Shortcut", 110)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.doubleAction = #selector(changePressed)
        table.target = self
        table.setAccessibilityLabel("Commands and shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 270).isActive = true
        let change = NSButton(title: "Change…", target: self, action: #selector(changePressed))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetPressed))
        let resetAll = NSButton(title: "Reset to Default", target: self, action: #selector(resetAllPressed))
        for b in [change, reset, resetAll] { b.bezelStyle = .rounded }
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 12)
        install([
            settingsRow("Keymap", [settingsPopup(["Gobi default"], enabled: false)], labelWidth: 80),
            settingsRow("Search", [search], labelWidth: 80),
            scroll,
            NSStackView(views: [change, reset, resetAll, status]),
            settingsHint("Double-click a command, or press Change…, then press the new keys. A shortcut already in use is shown before it is saved."),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func sync() { applyFilter() }

    private func applyFilter() {
        let keymap = AppPreferences.keymap
        let query = search.stringValue.lowercased()
        visible = KeymapItems.all.filter { item in
            guard item.isLive else { return false }
            if query.isEmpty { return true }
            return item.title.lowercased().contains(query) || item.menu.lowercased().contains(query) || keymap.shortcut(for: item.id, default: item.defaultShortcut).lowercased().contains(query)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        let keymap = AppPreferences.keymap
        let text: String
        var colour = NSColor.labelColor
        switch tableColumn?.identifier.rawValue {
        case "command": text = item.title
        case "menu": text = item.menu; colour = .secondaryLabelColor
        default:
            text = keymap.shortcut(for: item.id, default: item.defaultShortcut)
            if keymap.isCustom(item.id) { colour = ThemeColors.accent }
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = colour
        label.font = tableColumn?.identifier.rawValue == "shortcut" ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
        return label
    }

    var selectedItem: KeymapItem? { table.selectedRow >= 0 && visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil }
    var rowTitles: [String] { visible.map(\.title) }
    func search(_ text: String) { search.stringValue = text; applyFilter() }
    func select(id: String) { if let row = visible.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([row], byExtendingSelection: false) } }

    /// Gives a command a new shortcut. Returns the command that already uses it (nothing is changed then), or nil on success.
    @discardableResult
    func assign(_ shortcut: String, to item: KeymapItem) -> String? {
        let all = KeymapItems.all.filter { !$0.defaultShortcut.isEmpty || AppPreferences.keymap.isCustom($0.id) }.map { ($0.id, $0.defaultShortcut) }
        if let taken = AppPreferences.keymap.conflict(for: shortcut, changing: item.id, among: all) {
            status.stringValue = "\(shortcut) is already used by \(taken)."
            return taken
        }
        AppPreferences.update(\.keymap) { $0.set(shortcut, for: item.id) }
        status.stringValue = "\(item.title) is now \(shortcut)."
        applyFilter()
        return nil
    }

    @objc private func changePressed() {
        guard let item = selectedItem else { return }
        let capture = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        let alert = NSAlert()
        alert.messageText = "Shortcut for \(item.title)"
        alert.informativeText = "Press the keys you want, then choose Set."
        alert.accessoryView = capture
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = capture
        capture.window?.makeFirstResponder(capture)
        guard alert.runModal() == .alertFirstButtonReturn, let glyphs = capture.glyphs else { return }
        assign(glyphs, to: item)
    }

    @objc private func resetPressed() {
        guard let item = selectedItem else { return }
        AppPreferences.update(\.keymap) { $0.reset(item.id) }
        applyFilter()
    }

    @objc private func resetAllPressed() {
        AppPreferences.update(\.keymap) { $0.resetAll() }
        status.stringValue = "All shortcuts are back to their defaults."
        applyFilter()
    }
}

/// Shows the keys the user presses, as the glyphs a shortcut is written with.
final class KeyCaptureView: NSView {
    private let label = NSTextField(labelWithString: "Press keys…")
    private(set) var glyphs: String?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { capture(event); return true }
    override func keyDown(with event: NSEvent) { capture(event) }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers ?? ""
        if let result = ShortcutGlyphs.make(key: key, command: flags.contains(.command), option: flags.contains(.option), control: flags.contains(.control), shift: flags.contains(.shift)) {
            glyphs = result
            label.stringValue = result
        } else {
            label.stringValue = "Use ⌘, ⌃ or ⌥ with a key"
        }
    }
}

enum AppSettingsText {
    /// "10,000 lines"
    static func lines(_ count: Int) -> String {
        let text = AdvancedSettings.lineLimitTitle(count)
        return String(text.dropLast(" characters".count)) + " lines"
    }
}
