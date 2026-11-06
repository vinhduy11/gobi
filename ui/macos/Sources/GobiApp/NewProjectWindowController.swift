import AppKit
import GobiClient
import GobiModel

/// The New Project window of the mock: template list on the left; name, location, module path, Go version, options and
/// the "Will create" list on the right. Runs modally and hands the finished request to `onCreate`.
final class NewProjectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row { case group(String); case template(Int) }

    private var templates = TemplateCatalog.all
    private var rows: [Row] = []
    /// True once the list on screen is the one gobid sent (the self-test waits for it).
    private(set) var catalogueFromCore = false
    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let name = NSTextField()
    private let location = NSTextField()
    private let module = NSTextField()
    private let version = NSPopUpButton(frame: .zero, pullsDown: false)
    private let environment = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gitInit = NSButton(checkboxWithTitle: "Initialize Git repository (branch master)", target: nil, action: nil)
    private let scaffold = NSButton(checkboxWithTitle: "Add .gitignore, .env.example and README.md", target: nil, action: nil)
    private let sampleTest = NSButton(checkboxWithTitle: "Add a sample test", target: nil, action: nil)
    private let addToWork = NSButton(checkboxWithTitle: "Add to an existing go.work", target: nil, action: nil)
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(labelWithString: "")
    private let previewText = NSTextView()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private var selected = 0
    private var workDir = ""
    private var previewTimer: Timer?
    private var previewGeneration = 0
    private var goVersionText = "Auto"
    private(set) var request: NewProjectRequest?
    private let versions = ["1.22", "1.23", "1.24", "1.25", "1.26"]

    init() {
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false))
        window?.title = "New Project"
        rows = Self.rows(for: templates)
        build()
        window?.center()
        table.selectRowIndexes([1], byExtendingSelection: false)
        applyTemplate()
        loadCatalogue()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let go = GoTool.version()
            DispatchQueue.main.async { self?.setInstalledGo(go) }
        }
    }

    private static func rows(for templates: [ProjectTemplate]) -> [Row] {
        var built: [Row] = []
        var lastGroup = ""
        for (index, template) in templates.enumerated() {
            if template.group != lastGroup { built.append(.group(template.group)); lastGroup = template.group }
            built.append(.template(index))
        }
        return built
    }

    /// Asks gobid for the template list; the offline list stays on screen when it cannot answer.
    private func loadCatalogue() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = try? { () -> [ProjectTemplate] in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.templates()
            }()
            DispatchQueue.main.async { self?.show(catalogue: loaded ?? []) }
        }
    }

    /// Replaces the list, keeping the chosen template when the new list still has it.
    private func show(catalogue: [ProjectTemplate]) {
        guard !catalogue.isEmpty else { return }
        let chosen = template.id
        TemplateCatalog.use(catalogue)
        templates = TemplateCatalog.all
        rows = Self.rows(for: templates)
        selected = templates.firstIndex { $0.id == chosen } ?? 0
        table.reloadData()
        if let row = rows.firstIndex(where: { if case .template(let index) = $0 { return index == selected } else { return false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        catalogueFromCore = true
        applyTemplate()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the window as a modal and returns the request when the user pressed Create.
    func runModal() -> NewProjectRequest? {
        guard let window else { return nil }
        window.makeFirstResponder(name)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return request
    }

    // MARK: self-test access

    var previewString: String { previewText.string }
    var isCreateEnabled: Bool { createButton.isEnabled }
    var isSampleTestEnabled: Bool { sampleTest.isEnabled }
    var isAddToWorkEnabled: Bool { addToWork.isEnabled }
    /// The titles of the template list on screen, in order.
    var templateTitles: [String] { templates.map(\.title) }
    var templateGroups: [String] { rows.compactMap { if case .group(let title) = $0 { return title } else { return nil } } }

    func snapshotWindow(to path: String) { WindowSnapshot.write(window, to: path) }

    func choose(templateTitled title: String) {
        guard let row = rows.firstIndex(where: { if case .template(let index) = $0 { return templates[index].title == title } else { return false } }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        selected = { if case .template(let index) = rows[row] { return index } else { return 0 } }()
        applyTemplate()
    }

    func type(name text: String) {
        name.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
    }

    func setSampleTest(_ on: Bool) { sampleTest.state = on ? .on : .off; refresh() }
    func setLocation(_ path: String) { location.stringValue = path; refresh() }

    // MARK: layout

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Templates")
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 270).isActive = true

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        for field in [name, location, module] {
            field.delegate = self
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.cell?.isScrollable = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        }
        name.placeholderString = "hello"
        location.stringValue = (NSHomeDirectory() + "/Work")
        module.placeholderString = "example.com/hello"
        version.addItems(withTitles: ["Auto"] + versions)
        environment.addItem(withTitle: "local")
        environment.isEnabled = false
        environment.toolTip = "Environment profiles arrive with the environments window."

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseLocation))
        let locationRow = NSStackView(views: [location, choose])
        let grid = NSGridView(views: [
            [label("Name"), name], [label("Location"), locationRow], [label("Module path"), module],
            [label("Go version"), version], [label("Environment"), environment],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        for box in [gitInit, scaffold, sampleTest, addToWork] { box.target = self; box.action = #selector(optionChanged) }
        gitInit.state = .on
        scaffold.state = .on
        sampleTest.state = .on
        let options = NSStackView(views: [gitInit, scaffold, sampleTest, addToWork])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6

        commandLabel.textColor = .secondaryLabelColor
        commandLabel.font = NSFont.systemFont(ofSize: 12)
        problemLabel.textColor = .systemRed
        problemLabel.font = NSFont.systemFont(ofSize: 12)

        let willCreate = NSTextField(labelWithString: "Will create")
        willCreate.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        previewText.isEditable = false
        previewText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        previewText.textContainerInset = NSSize(width: 8, height: 6)
        previewText.backgroundColor = .textBackgroundColor
        previewText.setAccessibilityLabel("Files that will be created")
        let previewScroll = NSScrollView()
        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        previewScroll.setContentHuggingPriority(.defaultLow, for: .vertical)   // the list takes the spare height

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(createPressed)
        createButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, createButton])

        let form = NSStackView(views: [titleLabel, summaryLabel, grid, options, commandLabel, problemLabel, willCreate, previewScroll, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.distribution = .fill
        form.spacing = 12
        form.setCustomSpacing(18, after: summaryLabel)
        form.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        for part in [previewScroll, buttons, summaryLabel] { part.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -56).isActive = true }

        let content = NSStackView(views: [list, form])
        content.orientation = .horizontal
        content.spacing = 0
        content.alignment = .top
        list.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        form.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        window?.contentView = content
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    // MARK: state

    private func setInstalledGo(_ go: String?) {
        goVersionText = go.map { "Auto · \($0) (installed)" } ?? "Auto · Go not found"
        version.item(at: 0)?.title = goVersionText
    }

    private var template: ProjectTemplate { templates[selected] }

    private func applyTemplate() {
        titleLabel.stringValue = template.title
        summaryLabel.stringValue = template.summary
        sampleTest.isEnabled = template.isAvailable && template.id != "empty"
        refresh()
    }

    @objc private func optionChanged() { refresh() }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === name { module.placeholderString = ProjectForm.suggestedModulePath(forName: name.stringValue).nonEmpty ?? "example.com/hello" }
        refresh()
    }

    @objc private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { location.stringValue = url.path; refresh() }
    }

    private var expandedLocation: String { (location.stringValue as NSString).expandingTildeInPath }

    private var effectiveModulePath: String {
        module.stringValue.isEmpty ? ProjectForm.suggestedModulePath(forName: name.stringValue) : module.stringValue
    }

    /// Re-checks the form and schedules the "Will create" refresh.
    private func refresh() {
        let projectName = name.stringValue.trimmingCharacters(in: .whitespaces)
        workDir = findGoWork(from: expandedLocation) ?? ""
        addToWork.isEnabled = !workDir.isEmpty && template.id != "workspace" && template.isAvailable
        if !addToWork.isEnabled { addToWork.state = .off }
        addToWork.toolTip = workDir.isEmpty ? "No go.work found in or above the location." : "Adds the module to \(workDir)/go.work"
        commandLabel.stringValue = ProjectForm.commandSummary(modulePath: effectiveModulePath)
        var problem: String?
        if !template.isAvailable { problem = "\(template.title) is not available yet." }
        else if !projectName.isEmpty { problem = ProjectForm.problem(withName: projectName) ?? ProjectForm.problem(withModulePath: module.stringValue) }
        problemLabel.stringValue = problem ?? ""
        problemLabel.isHidden = problem == nil
        createButton.isEnabled = template.isAvailable && !projectName.isEmpty && problem == nil
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.loadPreview() }
    }

    private func currentRequest() -> NewProjectRequest {
        NewProjectRequest(
            template: template.id, name: name.stringValue.trimmingCharacters(in: .whitespaces), location: expandedLocation,
            modulePath: module.stringValue, goVersion: version.indexOfSelectedItem == 0 ? "" : versions[version.indexOfSelectedItem - 1],
            gitInit: gitInit.state == .on, sampleTest: sampleTest.state == .on && sampleTest.isEnabled, scaffold: scaffold.state == .on,
            workDir: addToWork.state == .on ? workDir : "")
    }

    private func loadPreview() {
        guard template.isAvailable else { previewText.string = ""; return }
        let projectName = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !projectName.isEmpty, ProjectForm.problem(withName: projectName) == nil else { previewText.string = "Enter a name to see the files."; return }
        previewGeneration += 1
        let generation = previewGeneration
        let request = currentRequest()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { () -> [String] in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.preview(request)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.previewGeneration else { return }
                switch outcome {
                case .success(let files): self.previewText.string = PreviewTree.lines(root: request.name, files: files).joined(separator: "\n")
                case .failure(let error): self.previewText.string = "\(error)"
                }
            }
        }
    }

    /// The folder that holds a go.work at or above `path`, within a few levels.
    private func findGoWork(from path: String) -> String? {
        var folder = path
        for _ in 0 ..< 6 {
            if FileManager.default.fileExists(atPath: folder + "/go.work") { return folder }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
        return nil
    }

    // MARK: buttons

    @objc private func cancelPressed() {
        request = nil
        NSApp.stopModal()
    }

    @objc private func createPressed() {
        request = currentRequest()
        NSApp.stopModal()
    }

    // MARK: template list

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .template = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .template(let index):
            let item = templates[index]
            let label = NSTextField(labelWithString: item.title)
            label.textColor = item.isAvailable ? .labelColor : .tertiaryLabelColor
            return label
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, case .template(let index) = rows[table.selectedRow] else { return }
        selected = index
        applyTemplate()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
