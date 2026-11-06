import AppKit
import GobiEditor
import GobiModel

/// Projects without a go.mod: running the Go files of a folder, the notice that offers a go.mod, Create go.mod and New > Go Package….
extension ProjectWindowController {
    private func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) }

    /// A go.work at the project root, or a go.mod in `directory` (relative to the project root) or a folder above it inside the project.
    func hasGoModule(forDirectory directory: String) -> Bool {
        if exists("go.work") { return true }
        return GoModule.lookupFolders(forDirectory: directory).contains { exists($0.isEmpty ? "go.mod" : $0 + "/go.mod") }
    }

    private func goFiles(inDirectory directory: String) -> [SingleFileRun.Sibling] {
        let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".go") }.sorted().prefix(200)
        return names.compactMap { name in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), let package = SingleFileRun.packageName(inSource: text) else { return nil }
            return SingleFileRun.Sibling(name: name, package: package)
        }
    }

    /// The Go files to hand to `go run` / `go test` in place of a package pattern when the folder of the current file (or the project
    /// root) has no go.mod; nil when a module applies or there is nothing honest to run.
    func filesWithoutModule(includeTests: Bool) -> [String]? {
        var directory = ""
        var current: String?
        if let url = currentPane?.editorFile.fileURL, url.pathExtension == "go", contains(url) {
            directory = (relativePath(of: url) as NSString).deletingLastPathComponent
            current = url.lastPathComponent
        }
        guard !hasGoModule(forDirectory: directory) else { return nil }
        var siblings = goFiles(inDirectory: directory)
        var file = includeTests && current != nil ? current : SingleFileRun.mainFile(current: current, siblings: siblings)
        if file == nil, !directory.isEmpty {
            directory = ""
            siblings = goFiles(inDirectory: "")
            file = SingleFileRun.mainFile(current: nil, siblings: siblings)
        }
        guard let file else { return nil }
        return SingleFileRun.arguments(currentFile: file, directory: directory, siblings: siblings, includeTests: includeTests)
    }

    private var noticeKey: String { GoModule.noticeKey(project: root.path) }

    /// The notice for a Go file in a project with no go.mod. Restricted projects get the text without the button that writes a file.
    func showGoModNotice(on pane: EditorPane) {
        let path = pane.editorFile.fileURL.path
        guard pane.editorFile.language == "go", contains(pane.editorFile.fileURL), !UserDefaults.standard.bool(forKey: noticeKey) else { return }
        let directory = (relativePath(of: pane.editorFile.fileURL) as NSString).deletingLastPathComponent
        guard !hasGoModule(forDirectory: directory), pane.editor.noticeText.isEmpty else { return }
        goModNoticePaths.insert(path)
        var actions = [NoticeAction(title: "Not Now") { [weak self] in self?.dismissGoModNotice() }]
        if isTrusted { actions.insert(NoticeAction(title: "Create go.mod") { [weak self] in self?.createGoMod() }, at: 0) }
        pane.editor.showNotice("This folder has no go.mod. gopls works best, and Run and Test need one for several files or packages.", style: .info, actions: actions)
    }

    private func hideGoModNotices() {
        for path in goModNoticePaths { panes[path]?.editor.hideNotice() }
        goModNoticePaths.removeAll()
    }

    func dismissGoModNotice() {
        UserDefaults.standard.set(true, forKey: noticeKey)
        hideGoModNotices()
    }

    var isGoModNoticeShown: Bool { currentPane.map { goModNoticePaths.contains($0.editorFile.fileURL.path) } ?? false }

    /// Writes go.mod in the project root and tells everything that depends on it. Returns the file, nil when refused.
    @discardableResult
    func createGoMod() -> URL? {
        guard isTrusted else { return nil }
        let url = root.appendingPathComponent("go.mod")
        guard !FileManager.default.fileExists(atPath: url.path) else { statusBar.set(note: "go.mod already exists"); return nil }
        var version = goVersion
        if case .install(let install) = toolchainResolution { version = install.version }
        let name = GoModule.moduleName(fromFolder: root.lastPathComponent)
        do {
            try GoModule.source(module: name, goVersion: version).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusBar.set(note: "Create go.mod: \(error.localizedDescription)")
            return nil
        }
        hideGoModNotices()
        reloadExplorer()
        loadModuleFacts()
        for pane in panes.values where pane.editorFile.language == "go" { pane.reconnect(reason: "Restarting the language server for the new go.mod…") }
        refreshChrome()
        statusBar.set(note: "Created go.mod (\(name))")
        return url
    }

    /// Explorer > New > Go Package…: a folder with a first file of the same name. Returns the file, nil when cancelled or refused.
    @discardableResult
    func newGoPackage(in folder: URL, name: String? = nil) -> URL? {
        let typed: String
        if let name { typed = name } else {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "package name, for example cart"
            let alert = NSAlert()
            alert.messageText = "New Go Package"
            alert.informativeText = "A folder and a file of the same name, in \(folder.lastPathComponent)"
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            typed = field.stringValue
        }
        let package = typed.trimmingCharacters(in: .whitespaces)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if let problem = NewEntry.problem(with: package, existing: existing) {
            statusBar.set(note: "New Go Package: " + (problem == .exists ? "\(package) already exists" : "type a package name without /"))
            return nil
        }
        guard GoModule.isValidPackageName(package) else {
            statusBar.set(note: "New Go Package: \(package) is not a valid Go package name")
            return nil
        }
        let directory = folder.appendingPathComponent(package)
        let file = directory.appendingPathComponent(package + ".go")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try NewEntry.goSource(package: package).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            statusBar.set(note: "New Go Package: \(error.localizedDescription)")
            return nil
        }
        reloadExplorer()
        openFile(file)
        return file
    }
}
