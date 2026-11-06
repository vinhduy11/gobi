import AppKit
import GobiClient
import GobiModel

/// "Run on Multiple Go Versions" (Toolchains mock): go vet and go test ./... once for each checked Go version, one after the
/// other, with a table of the results. Each run goes through the run channel with that version's Go folder.
final class MultiVersionWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let project: ProjectWindowController
    private let table = NSTableView()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var checks: [(install: GoInstall, box: NSButton)] = []
    private(set) var rows: [MultiVersionRow] = []
    private var plan: [GoInstall] = []
    private var client: RunClient?
    private var stopRequested = false
    private(set) var isRunning = false
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let lastRun = NSTextField(labelWithString: "")
    private var finishedAt: Int?
    private let now: () -> Int
    private var outputTail = ""

    /// The key the last result of a project is kept under.
    static func defaultsKey(root: String) -> String { "gobi.multiversion." + root }
    private var defaultsKey: String { Self.defaultsKey(root: project.root.path) }
    var lastRunText: String { lastRun.stringValue }

    /// `now` is the clock in seconds, injected so the "last run" text is testable.
    init(project: ProjectWindowController, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.project = project
        self.now = now
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Run on Multiple Go Versions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let boxes = NSStackView()
        boxes.spacing = 14
        for install in MultiVersionRow.choices(from: project.goInstalls) {
            let minor = install.version.split(separator: ".").prefix(2).joined(separator: ".")
            let box = NSButton(checkboxWithTitle: minor, target: nil, action: nil)
            box.state = .on
            box.toolTip = "go" + install.version
            boxes.addArrangedSubview(box)
            checks.append((install, box))
        }
        for (title, id, width) in [("Version", "version", 110), ("go vet", "vet", 90), ("go test ./…", "test", 190), ("Time", "time", 70)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Results per Go version")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        runButton.target = self; runButton.action = #selector(runPressed); runButton.bezelStyle = .rounded; runButton.keyEquivalent = "\r"
        stopButton.target = self; stopButton.action = #selector(stopPressed); stopButton.bezelStyle = .rounded; stopButton.isEnabled = false
        clearButton.target = self; clearButton.action = #selector(clearPressed); clearButton.bezelStyle = .rounded
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 12)
        lastRun.textColor = .secondaryLabelColor
        lastRun.font = NSFont.systemFont(ofSize: 12)
        let buttons = NSStackView(views: [note, NSView(), clearButton, stopButton, runButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [boxes, scroll, lastRun, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = stack
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        restoreLast()
        if checks.isEmpty { note.stringValue = "No Go versions were found." }
        if !project.isTrusted { note.stringValue = "Running code is off in Restricted Mode. Trust the project first."; runButton.isEnabled = false }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var checkedVersions: [String] { checks.filter { $0.box.state == .on }.map(\.install.version) }
    func setChecked(_ versions: Set<String>) { for (install, box) in checks { box.state = versions.contains(install.version) ? .on : .off } }

    @objc private func runPressed() { run(versions: checks.filter { $0.box.state == .on }.map(\.install)) }

    @objc private func stopPressed() {
        stopRequested = true
        client?.stop()
    }

    /// Shows the saved result of the last run, when there is one.
    private func restoreLast() {
        guard let text = UserDefaults.standard.string(forKey: defaultsKey), let saved = MultiVersionSnapshot.decode(text) else { return updateLastRun() }
        rows = saved.rows
        finishedAt = saved.finishedAt
        updateLastRun()
        table.reloadData()
    }

    private func updateLastRun() {
        lastRun.stringValue = finishedAt.map { MultiVersionSnapshot.lastRunText(finishedAt: $0, now: now()) } ?? ""
        clearButton.isEnabled = !isRunning && !rows.isEmpty
    }

    private func saveLast() {
        let time = now()
        finishedAt = time
        UserDefaults.standard.set(MultiVersionSnapshot(finishedAt: time, rows: rows).encoded, forKey: defaultsKey)
        updateLastRun()
    }

    @objc func clearPressed() {
        guard !isRunning else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        rows = []
        finishedAt = nil
        table.reloadData()
        updateLastRun()
    }

    /// Runs vet then test for each install in turn.
    func run(versions: [GoInstall]) {
        guard !isRunning, !versions.isEmpty, project.isTrusted else { return }
        plan = versions
        rows = versions.map { MultiVersionRow(version: $0.version) }
        table.reloadData()
        isRunning = true
        stopRequested = false
        runButton.isEnabled = false
        stopButton.isEnabled = true
        note.stringValue = ""
        finishedAt = nil
        updateLastRun()
        next(index: 0, phase: .vet)
    }

    private enum Phase { case vet, test }

    private func next(index: Int, phase: Phase) {
        guard index < plan.count, !stopRequested else { return finish() }
        let install = plan[index]
        guard let goRoot = ToolchainChoice.goRoot(.install(install), home: NSHomeDirectory()) else { return finish() }
        let started = Date()
        var results = TestResults()
        outputTail = ""
        if phase == .vet { rows[index].vetStarted() } else { rows[index].testStarted() }
        table.reloadData()
        let rootPath = project.root.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let client = try RunClient(workspaceRoot: rootPath, trusted: true)
                client.onOutput = { bytes, _ in DispatchQueue.main.async { self?.outputTail = String((self?.outputTail ?? "") + String(decoding: bytes, as: UTF8.self)).suffix(2000).description } }
                client.onTest = { event in DispatchQueue.main.async { results.apply(event) } }
                client.onExit = { [weak self] code, message in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.client?.close()
                        self.client = nil
                        let excerpt = MultiVersionRow.excerpt(of: self.outputTail)
                        if phase == .vet { self.rows[index].vetExcerpt = excerpt } else { self.rows[index].testExcerpt = excerpt }
                        if self.stopRequested { self.rows[index].stopped(); self.table.reloadData(); return self.finish() }
                        if phase == .vet {
                            self.rows[index].vetFinished(exitCode: code)
                            self.next(index: index, phase: .test)
                        } else {
                            self.rows[index].testFinished(exitCode: code, results: results, seconds: Date().timeIntervalSince(started))
                            self.table.reloadData()
                            self.next(index: index + 1, phase: .vet)
                        }
                        self.table.reloadData()
                        _ = message
                    }
                }
                DispatchQueue.main.async { self?.client = client }
                client.start(command: phase == .vet ? "vet" : "test", packages: ["./..."], envFile: WindowSettings.loadDotEnv ? "" : "-", goRoot: goRoot)
            } catch {
                AppLog.shared.logError("run channel: multi-version run cannot start: \(error)")
                DispatchQueue.main.async { self?.note.stringValue = "Cannot start: \(error)"; self?.finish() }
            }
        }
    }

    private func finish() {
        for index in rows.indices where !rows[index].isFinished { rows[index].stopped() }
        isRunning = false
        runButton.isEnabled = project.isTrusted
        stopButton.isEnabled = false
        table.reloadData()
        if !rows.isEmpty { saveLast() } else { updateLastRun() }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text: String
        var colour = NSColor.labelColor
        switch tableColumn?.identifier.rawValue {
        case "version": text = "go" + item.version
        case "vet": text = item.vetText; colour = Self.colour(for: text)
        case "test": text = item.testText; colour = Self.colour(for: text)
        default: text = item.timeText; colour = .secondaryLabelColor
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = colour
        let excerpt = tableColumn?.identifier.rawValue == "vet" ? item.vetExcerpt : tableColumn?.identifier.rawValue == "test" ? item.testExcerpt : ""
        if !excerpt.isEmpty { label.toolTip = excerpt }
        return label
    }

    private static func colour(for text: String) -> NSColor {
        if text.hasPrefix("Passed") { return .systemGreen }
        if text.contains("ailed") { return .systemRed }
        return .secondaryLabelColor
    }
}
