import AppKit
import GobiModel

/// Environments (Run > Manage Environments…), per the Environments mock: profiles on the left; on the right the selected
/// profile's env files, variables (secrets go to the Keychain), Go settings, safety switches and the services it points at.
final class EnvironmentsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: ProjectEnvironments
    private var draft: EnvironmentFile
    private var pendingSecrets: [String: [String: String]] = [:]   // profile -> name -> value to store on Save
    private var removedSecrets: [(profile: String, name: String)] = []
    private var selected = 0
    var onSaved: () -> Void = {}

    private let profilesTable = NSTableView()
    private let filesTable = NSTableView()
    private let varsTable = NSTableView()
    private let targetsTable = NSTableView()
    private let remote = NSButton(checkboxWithTitle: "Remote (services that are not on this machine)", target: nil, action: nil)
    private let isDefault = NSButton(checkboxWithTitle: "Default profile", target: nil, action: nil)
    private let confirm = NSButton(checkboxWithTitle: "Ask before tests, migrations or scripts that touch non-local targets", target: nil, action: nil)
    private let blockDestructive = NSButton(checkboxWithTitle: "Block DROP / CREATE and destructive migrations on non-local databases", target: nil, action: nil)
    private let toolchain = NSTextField(), tags = NSTextField(), goflags = NSTextField(), goos = NSTextField(), goarch = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var targets: [EnvTarget] = []

    var profileNames: [String] { draft.profiles.map(\.name) }
    var targetRows: [(component: String, address: String, local: Bool)] { targets.map { ($0.component, $0.address, $0.isLocal) } }
    var statusText: String { status.stringValue }
    var selectedName: String { draft.profiles.indices.contains(selected) ? draft.profiles[selected].name : "" }

    init(store: ProjectEnvironments) {
        self.store = store
        var initial = store.file
        if initial.profiles.isEmpty {
            var local = EnvProfile(name: "local")
            local.isDefault = true
            local.envFiles = FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".env").path) ? [".env"] : []
            initial.profiles = [local]
        }
        draft = initial
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Environments — " + store.root.lastPathComponent
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        selected = max(0, draft.profiles.firstIndex { $0.name == store.activeName } ?? 0)
        showSelected()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func table(_ table: NSTableView, columns: [(String, String, CGFloat)], height: CGFloat, header: Bool = true) -> NSScrollView {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        if !header { table.headerView = nil }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func build() {
        // left: profiles
        let profilesScroll = table(profilesTable, columns: [("profile", "Profiles", 190)], height: 400)
        profilesScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let left = NSStackView(views: [profilesScroll, NSStackView(views: [button("+ New", #selector(newProfile)), button("Duplicate", #selector(duplicateProfile)), button("Delete", #selector(deleteProfile))])])
        left.orientation = .vertical
        left.spacing = 8
        left.widthAnchor.constraint(equalToConstant: 210).isActive = true

        // right: details
        for box in [remote, isDefault, confirm, blockDestructive] { box.target = self; box.action = #selector(profileFlagsChanged) }
        for field in [toolchain, tags, goflags, goos, goarch] { field.delegate = self; field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
        toolchain.placeholderString = "auto"
        tags.placeholderString = "staging integration"
        goflags.placeholderString = "-mod=readonly"
        goos.placeholderString = "darwin"
        goarch.placeholderString = "arm64"
        func labelled(_ title: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            return NSStackView(views: [label, field])
        }
        let filesScroll = table(filesTable, columns: [("file", "File", 520)], height: 70, header: false)
        let varsScroll = table(varsTable, columns: [("name", "Name", 170), ("value", "Value", 330), ("secret", "Keychain", 70)], height: 130)
        let targetsScroll = table(targetsTable, columns: [("component", "Component", 120), ("address", "Host:port", 240), ("source", "Config source", 140), ("local", "Local?", 60)], height: 100)
        let goGrid = NSStackView(views: [labelled("Toolchain", toolchain), labelled("Build tags", tags), labelled("GOFLAGS", goflags), NSStackView(views: [labelled("GOOS", goos), labelled("GOARCH", goarch)])])
        goGrid.orientation = .vertical
        goGrid.alignment = .leading
        let details = NSStackView(views: [
            remote, isDefault,
            heading("Env files (later overrides earlier)"), filesScroll, NSStackView(views: [button("+ Add file…", #selector(addFile)), button("Remove", #selector(removeFile))]),
            heading("Variables (override the files)"), varsScroll, NSStackView(views: [button("+ Add variable", #selector(addVariable)), button("Remove", #selector(removeVariable)), button("Set Secret Value…", #selector(setSecretValue))]),
            heading("Go"), goGrid,
            heading("Safety"), confirm, blockDestructive,
            heading("Resolved targets"), targetsScroll,
        ])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        details.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 10, right: 10)
        details.translatesAutoresizingMaskIntoConstraints = false
        let detailScroll = NSScrollView()
        let flipped = FlippedView()
        flipped.addSubview(details)
        detailScroll.documentView = flipped
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), details.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            details.topAnchor.constraint(equalTo: flipped.topAnchor), details.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
        ])
        for view in [filesScroll, varsScroll, targetsScroll] { view.widthAnchor.constraint(equalToConstant: 620).isActive = true }

        let split = NSStackView(views: [left, detailScroll])
        split.spacing = 12
        split.alignment = .top
        status.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let save = NSButton(title: "Save", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        let bottom = NSStackView(views: [status, NSView(), cancel, save])
        let root = NSStackView(views: [split, bottom])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        window?.contentView = root
        split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    // MARK: model <-> controls

    private var current: EnvProfile {
        get { draft.profiles.indices.contains(selected) ? draft.profiles[selected] : EnvProfile(name: "") }
        set { if draft.profiles.indices.contains(selected) { draft.profiles[selected] = newValue } }
    }

    private func showSelected() {
        profilesTable.reloadData()
        if draft.profiles.indices.contains(selected) { profilesTable.selectRowIndexes([selected], byExtendingSelection: false) }
        let p = current
        remote.state = p.isRemote ? .on : .off
        isDefault.state = p.isDefault ? .on : .off
        confirm.state = p.confirmNonLocal ? .on : .off
        blockDestructive.state = p.blockDestructive ? .on : .off
        toolchain.stringValue = p.toolchain; tags.stringValue = p.tags; goflags.stringValue = p.goflags; goos.stringValue = p.goos; goarch.stringValue = p.goarch
        filesTable.reloadData()
        varsTable.reloadData()
        refreshTargets()
    }

    private func refreshTargets() {
        // The resolution reads the files from disk and secrets from the Keychain, plus values typed but not saved yet.
        var profile = current
        var environment = store.resolved(profile)
        _ = environment
        let pending = pendingSecrets[profile.name] ?? [:]
        profile.vars += pending.map { EnvVar(name: $0.key, value: $0.value) }
        environment = store.resolved(profile)
        targets = EnvTargets.find(in: environment)
        targetsTable.reloadData()
    }

    @objc private func profileFlagsChanged() {
        var p = current
        p.isRemote = remote.state == .on
        p.confirmNonLocal = confirm.state == .on
        p.blockDestructive = blockDestructive.state == .on
        let makeDefault = isDefault.state == .on
        current = p
        if makeDefault { for i in draft.profiles.indices { draft.profiles[i].isDefault = i == selected } } else { current.isDefault = false }
        profilesTable.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) { fieldsChanged() }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let table = field.superview?.superview as? NSTableView ?? (field.superview as? NSTableView) else { return fieldsChanged() }
        let row = table.row(for: field), column = table.column(for: field)
        guard row >= 0, column >= 0 else { return }
        var p = current
        if table === filesTable, p.envFiles.indices.contains(row) { p.envFiles[row] = field.stringValue }
        if table === varsTable, p.vars.indices.contains(row) {
            if table.tableColumns[column].identifier.rawValue == "name" {
                guard EnvVar.isValidName(field.stringValue) else { status.stringValue = "\"\(field.stringValue)\" is not a valid variable name."; varsTable.reloadData(); return }
                p.vars[row].name = field.stringValue
            } else { p.vars[row].value = field.stringValue }
        }
        if table === profilesTable, draft.profiles.indices.contains(row) {
            let name = field.stringValue
            guard EnvProfile.isValidName(name), !draft.profiles.enumerated().contains(where: { $0.offset != row && $0.element.name == name }) else { status.stringValue = "Profile names use letters, digits, - and _, and must be unique."; profilesTable.reloadData(); return }
            draft.profiles[row].name = name
            return profilesTable.reloadData()
        }
        current = p
        refreshTargets()
    }

    private func fieldsChanged() {
        var p = current
        p.toolchain = toolchain.stringValue; p.tags = tags.stringValue; p.goflags = goflags.stringValue; p.goos = goos.stringValue; p.goarch = goarch.stringValue
        current = p
    }

    // MARK: actions

    @objc private func newProfile() {
        var number = 1
        while draft.profiles.contains(where: { $0.name == "profile\(number)" }) { number += 1 }
        draft.profiles.append(EnvProfile(name: "profile\(number)"))
        selected = draft.profiles.count - 1
        showSelected()
    }

    @objc private func duplicateProfile() {
        var copy = current
        var name = copy.name + "-copy"
        var number = 2
        while draft.profiles.contains(where: { $0.name == name }) { name = copy.name + "-copy\(number)"; number += 1 }
        copy.name = name
        copy.isDefault = false
        draft.profiles.append(copy)
        for secret in copy.secretNames { if let value = pendingSecrets[current.name]?[secret] ?? Keychain.get(secret, root: store.root.path) { pendingSecrets[name, default: [:]][secret] = value } }
        selected = draft.profiles.count - 1
        showSelected()
    }

    @objc private func deleteProfile() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selected) else { status.stringValue = "A project keeps at least one profile."; return }
        let gone = draft.profiles.remove(at: selected)
        for name in gone.secretNames { removedSecrets.append((gone.name, name)) }
        selected = min(selected, draft.profiles.count - 1)
        if !draft.profiles.contains(where: \.isDefault) { draft.profiles[0].isDefault = true }
        showSelected()
    }

    @objc private func addFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = store.root
        panel.message = "Choose an env file inside the project"
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(file: url.path)
    }

    /// Adds an env file (an absolute path inside the project is stored relative to it).
    func add(file path: String) {
        let base = store.root.standardizedFileURL.path + "/"
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standard.hasPrefix(base) || !path.hasPrefix("/") else { status.stringValue = "Env files must be inside the project."; return }
        var p = current
        p.envFiles.append(standard.hasPrefix(base) ? String(standard.dropFirst(base.count)) : path)
        current = p
        filesTable.reloadData()
        refreshTargets()
    }

    @objc private func removeFile() {
        guard filesTable.selectedRow >= 0, current.envFiles.indices.contains(filesTable.selectedRow) else { return }
        var p = current
        p.envFiles.remove(at: filesTable.selectedRow)
        current = p
        filesTable.reloadData()
        refreshTargets()
    }

    @objc private func addVariable() { add(variable: "NAME", value: "") }

    func add(variable name: String, value: String) {
        var p = current
        var unique = name, number = 2
        while p.vars.contains(where: { $0.name == unique }) { unique = name + "_\(number)"; number += 1 }
        p.vars.append(EnvVar(name: unique, value: value))
        current = p
        varsTable.reloadData()
        refreshTargets()
    }

    @objc private func removeVariable() {
        let row = varsTable.selectedRow
        var p = current
        if row >= 0, p.vars.indices.contains(row) { p.vars.remove(at: row) }
        else if row >= p.vars.count, p.secretNames.indices.contains(row - p.vars.count) {
            let name = p.secretNames.remove(at: row - p.vars.count)
            removedSecrets.append((p.name, name))
            pendingSecrets[p.name]?[name] = nil
        }
        current = p
        varsTable.reloadData()
        refreshTargets()
    }

    /// Stores a secret for the selected profile; it is written to the Keychain when the window is saved.
    func setSecret(_ name: String, value: String) {
        var p = current
        guard EnvVar.isValidName(name) else { status.stringValue = "\"\(name)\" is not a valid variable name."; return }
        if !p.secretNames.contains(name) { p.secretNames.append(name) }
        p.vars.removeAll { $0.name == name }
        current = p
        pendingSecrets[p.name, default: [:]][name] = value
        removedSecrets.removeAll { $0.profile == p.name && $0.name == name }
        varsTable.reloadData()
        refreshTargets()
    }

    @objc private func setSecretValue() {
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = "DB_PASSWORD"
        let value = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        value.placeholderString = "value"
        let box = NSStackView(views: [name, value])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        let alert = NSAlert()
        alert.messageText = "Set a secret"
        alert.informativeText = "The value goes to the macOS Keychain. Only its name is written to .gobi/environments.toml."
        alert.accessoryView = box
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setSecret(name.stringValue, value: value.stringValue)
    }

    @objc private func cancelPressed() { window?.close() }

    @objc private func savePressed() { _ = save() }

    /// Writes the file and the Keychain items. Returns an error text, or nil.
    @discardableResult
    func save() -> String? {
        fieldsChanged()
        let names = draft.profiles.map(\.name)
        guard Set(names).count == names.count, names.allSatisfy(EnvProfile.isValidName) else { status.stringValue = "Profile names must be unique."; return status.stringValue }
        do { try store.save(draft) } catch { status.stringValue = "Cannot save: \(error)"; return status.stringValue }
        for (profile, values) in pendingSecrets where names.contains(profile) { for (name, value) in values { Keychain.set(value, name: name, root: store.root.path) } }
        for gone in removedSecrets where !(draft.profiles.first { $0.name == gone.profile }?.secretNames.contains(gone.name) ?? false) {
            // A secret is shared by name across profiles of the project (one Keychain item per name): remove it only when no profile uses it.
            if !draft.profiles.contains(where: { $0.secretNames.contains(gone.name) }) { Keychain.delete(gone.name, root: store.root.path) }
        }
        pendingSecrets = [:]
        removedSecrets = []
        status.stringValue = "Saved."
        onSaved()
        return nil
    }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case profilesTable: return draft.profiles.count
        case filesTable: return current.envFiles.count
        case varsTable: return current.vars.count + current.secretNames.count
        default: return targets.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        var text = ""
        var editable = false
        var colour = NSColor.labelColor
        switch tableView {
        case profilesTable:
            let p = draft.profiles[row]
            text = p.name + (p.isDefault ? "   default" : "") + (p.isRemote ? "   remote" : "")
            editable = false
        case filesTable: text = current.envFiles[row]; editable = true
        case varsTable:
            let p = current
            if row < p.vars.count {
                text = id == "name" ? p.vars[row].name : (id == "value" ? p.vars[row].value : "")
                editable = id != "secret"
            } else {
                let name = p.secretNames[row - p.vars.count]
                text = id == "name" ? name : (id == "value" ? "••••••••" : "Keychain")
                colour = id == "name" ? .labelColor : .secondaryLabelColor
            }
        default:
            let t = targets[row]
            switch id {
            case "component": text = t.component
            case "address": text = t.address
            case "source": text = t.source; colour = .secondaryLabelColor
            default: text = t.isLocal ? "Yes" : "No"; colour = t.isLocal ? .systemGreen : .systemRed
            }
        }
        let label = NSTextField(string: text)
        label.isEditable = editable
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = colour
        label.lineBreakMode = .byTruncatingTail
        label.font = tableView === profilesTable ? NSFont.systemFont(ofSize: 13) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.delegate = self
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === profilesTable, profilesTable.selectedRow >= 0, profilesTable.selectedRow != selected else { return }
        fieldsChanged()
        selected = profilesTable.selectedRow
        showSelected()
    }
}
