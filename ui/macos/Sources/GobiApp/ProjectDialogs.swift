import AppKit
import GobiClient
import GobiModel

/// The New Project, Clone and Import dialogs. Each shows a form, checks it, asks gobid on a background thread and
/// hands the resulting folder to `completion` on the main thread.
final class ProjectDialogs {
    private let templates: [(title: String, id: String)] = [
        ("Command-line tool", "cli"), ("Library", "library"), ("HTTP service", "http"),
        ("Go workspace (go.work)", "workspace"), ("Empty module", "empty"),
    ]
    private let goVersions = ["Auto", "1.22", "1.23", "1.24", "1.25", "1.26"]
    private var busy: NSPanel?

    // MARK: new project

    func newProject(completion: @escaping (ProjectInfo, _ trustIt: Bool) -> Void) {
        let template = NSPopUpButton(frame: .zero, pullsDown: false)
        template.addItems(withTitles: templates.map(\.title))
        let name = NSTextField(string: "")
        let location = NSTextField(string: NSHomeDirectory() + "/Work")
        let module = NSTextField(string: "")
        module.placeholderString = "Same as the name"
        let version = NSPopUpButton(frame: .zero, pullsDown: false)
        version.addItems(withTitles: goVersions)
        let git = NSButton(checkboxWithTitle: "Create a git repository (branch master)", target: nil, action: nil)
        git.state = .on
        let choose = chooseButton(for: location)
        let locationRow = NSStackView(views: [location, choose])
        location.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let form = grid([("Template", template), ("Name", name), ("Location", locationRow), ("Module path", module), ("Go version", version), ("", git)])

        runForm(title: "New Project", message: "Creates a Go module with the selected template.", accept: "Create", form: form, focus: name) { [self] in
            let projectName = name.stringValue.trimmingCharacters(in: .whitespaces)
            if let problem = ProjectForm.problem(withName: projectName) ?? ProjectForm.problem(withModulePath: module.stringValue) { return problem }
            let request = NewProjectRequest(
                template: templates[template.indexOfSelectedItem].id, name: projectName, location: (location.stringValue as NSString).expandingTildeInPath,
                modulePath: module.stringValue, goVersion: version.indexOfSelectedItem == 0 ? "" : goVersions[version.indexOfSelectedItem],
                gitInit: git.state == .on)
            work("Creating “\(projectName)”…", { try ControlClient.connect().newProject(request) }) { completion($0, true) }
            return nil
        }
    }

    // MARK: clone

    func clone(completion: @escaping (ProjectInfo, _ trustIt: Bool) -> Void) {
        let url = NSTextField(string: "")
        url.placeholderString = "https://host/team/project.git"
        let name = NSTextField(string: "")
        name.placeholderString = "Repository name"
        let location = NSTextField(string: NSHomeDirectory() + "/Work")
        let locationRow = NSStackView(views: [location, chooseButton(for: location)])
        location.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        url.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let form = grid([("URL", url), ("Location", locationRow), ("Folder name", name)])

        runForm(title: "Clone Repository", message: "Uses your git, so credentials and ssh config work as in a terminal.", accept: "Clone", form: form, focus: url) { [self] in
            let address = url.stringValue.trimmingCharacters(in: .whitespaces)
            if let problem = ProjectForm.problem(withCloneURL: address) { return problem }
            let folder = name.stringValue.isEmpty ? ProjectForm.repositoryName(fromURL: address) : name.stringValue
            if let problem = ProjectForm.problem(withName: folder) { return problem }
            let target = (location.stringValue as NSString).expandingTildeInPath
            // Cloned code is someone else's: it is not trusted automatically.
            work("Cloning \(address)…", { try ControlClient.connect().clone(url: address, location: target, name: folder) }) { completion($0, false) }
            return nil
        }
    }

    // MARK: import

    func importFolder(completion: @escaping (ProjectInfo, _ trustIt: Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a folder that has Go code but no go.mod"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("go.mod").path) {
            let alert = NSAlert()
            alert.messageText = "“\(folder.lastPathComponent)” already has a go.mod"
            alert.informativeText = "Use Open to open it."
            alert.runModal()
            return
        }
        let module = NSTextField(string: "")
        module.placeholderString = "From the git remote, or the folder name"
        module.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let form = grid([("Module path", module)])
        runForm(title: "Import “\(folder.lastPathComponent)”", message: "Creates go.mod in this folder.", accept: "Create go.mod", form: form, focus: module) { [self] in
            if let problem = ProjectForm.problem(withModulePath: module.stringValue) { return problem }
            let path = folder.path, modulePath = module.stringValue
            work("Creating go.mod…", { try ControlClient.connect().importFolder(path: path, modulePath: modulePath) }) { completion($0, false) }
            return nil
        }
    }

    // MARK: pieces

    /// Shows the form in an alert; `submit` returns a problem to show (and keep the form open) or nil when done.
    private func runForm(title: String, message: String, accept: String, form: NSView, focus: NSView, submit: () -> String?) {
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.accessoryView = form
            alert.addButton(withTitle: accept)
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = focus
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let problem = submit() else { return }
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = problem
            warning.runModal()
        }
    }

    private func grid(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.frame.size = grid.fittingSize
        return grid
    }

    private func chooseButton(for field: NSTextField) -> NSButton {
        let button = NSButton(title: "Choose…", target: nil, action: nil)
        let picker = FolderPicker(field: field)
        button.target = picker
        button.action = #selector(FolderPicker.choose)
        objc_setAssociatedObject(button, Unmanaged.passUnretained(button).toOpaque(), picker, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    /// Runs gobid work off the main thread behind a small progress panel, then calls back on the main thread; failures
    /// are shown in an alert.
    private func work(_ message: String, _ job: @escaping () throws -> ProjectInfo, done: @escaping (ProjectInfo) -> Void) {
        showBusy(message)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try job() }
            DispatchQueue.main.async { [self] in
                hideBusy()
                switch outcome {
                case .success(let info): done(info)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "That did not work"
                    alert.informativeText = "\(error)"
                    alert.runModal()
                }
            }
        }
    }

    private func showBusy(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 70), styleMask: [.titled, .hudWindow], backing: .buffered, defer: false)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: message)
        label.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views: [spinner, label])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = row
        panel.title = "Gobi"
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        busy = panel
    }

    private func hideBusy() {
        busy?.close()
        busy = nil
    }
}

private final class FolderPicker: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field }

    @objc func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
    }
}
