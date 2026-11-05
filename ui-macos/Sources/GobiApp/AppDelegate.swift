import AppKit
import GobiClient
import GobiEditor

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [EditorWindowController] = []
    private var projects: [ProjectWindowController] = []
    private var welcome: WelcomeWindowController?
    private let dialogs = ProjectDialogs()

    private let selfTest = CommandLine.arguments.contains("--selftest")
    private let snapshotPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        // Paths on the command line reach us through application(_:openFile:), which AppKit calls for each one.
        if controllers.isEmpty && projects.isEmpty && !selfTest { showWelcome() }
        if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // AppKit also offers option values that look like paths (the --snapshot target); those are not documents.
        if filename == snapshotPath { return true }
        return openChosen(URL(fileURLWithPath: filename))
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder, a go.mod or go.work, or files (several files open as tabs)"
        guard panel.runModal() == .OK else { return }
        openChosen(panel.urls)
    }

    /// Files inside the front project open as tabs there; anything else is opened as a project or on its own.
    private func openChosen(_ urls: [URL]) {
        var rest = urls
        if let project = frontProject {
            let inside = urls.filter { ProjectFolder.projectRoot(for: $0) == nil && project.contains($0) }
            if !inside.isEmpty {
                project.openFiles(inside)
                rest.removeAll { url in inside.contains(url) }
            }
        }
        for url in rest { openChosen(url) }
    }

    /// A folder, go.mod or go.work opens a project window; any other file opens on its own.
    @discardableResult
    private func openChosen(_ url: URL) -> Bool {
        if let root = ProjectFolder.projectRoot(for: url) { return openProject(root) }
        return open(url, selfTest: selfTest, snapshotPath: snapshotPath)
    }

    @objc func newProject(_ sender: Any?) { dialogs.newProject { [weak self] info, trust in self?.openCreated(info, trust: trust) } }
    @objc func cloneRepository(_ sender: Any?) { dialogs.clone { [weak self] info, trust in self?.openCreated(info, trust: trust) } }
    @objc func importCode(_ sender: Any?) { dialogs.importFolder { [weak self] info, trust in self?.openCreated(info, trust: trust) } }

    /// A project the user just made is trusted (they wrote it); a clone or import still gets the trust question.
    private func openCreated(_ info: ProjectInfo, trust: Bool) {
        if trust {
            var list = ProjectStore.shared.trust
            list.trust(path: info.root)
            ProjectStore.shared.trust = list
        }
        openProject(URL(fileURLWithPath: info.root))
    }

    private func showWelcome() {
        let controller = welcome ?? WelcomeWindowController()
        controller.onOpenFolder = { [weak self] in self?.openDocument(nil) }
        controller.onNewProject = { [weak self] in self?.newProject(nil) }
        controller.onClone = { [weak self] in self?.cloneRepository(nil) }
        controller.onImport = { [weak self] in self?.importCode(nil) }
        controller.onOpenRecent = { [weak self] project in self?.openProject(URL(fileURLWithPath: project.path)) }
        welcome = controller
        controller.reload()
        controller.showWindow(nil)
    }

    @discardableResult
    private func openProject(_ root: URL) -> Bool {
        if let existing = projects.first(where: { $0.root == root }) {
            existing.showWindow(nil)
            return true
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            ProjectStore.shared.recents.remove(path: root.path)
            welcome?.reload()
            return false
        }
        var trust = ProjectStore.shared.trust
        if !trust.isTrusted(path: root.path), !selfTest, let answer = askTrust(root) {
            if answer.trusted { trust.trust(path: answer.parentToo ? root.deletingLastPathComponent().path : root.path) }
            ProjectStore.shared.trust = trust
        } else if !trust.isTrusted(path: root.path), !selfTest {
            return false   // Cancel
        }
        let kind = ProjectFolder.kind(of: root)
        let controller = ProjectWindowController(root: root, kind: kind, isTrusted: trust.isTrusted(path: root.path))
        projects.append(controller)
        ProjectStore.shared.recents.add(path: root.path, kind: kind)
        welcome?.close()
        if NSApp.activationPolicy() != .regular { controller.window?.alphaValue = 0; controller.window?.ignoresMouseEvents = true }
        controller.showWindow(nil)
        if selfTest { runProjectSelfTest(controller) }
        return true
    }

    /// nil means Cancel; otherwise whether to trust, and whether to trust the whole parent folder.
    private func askTrust(_ root: URL) -> (trusted: Bool, parentToo: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Do you trust the authors of “\(root.lastPathComponent)”?"
        alert.informativeText = "Building, running or debugging a Go project can run code from its files. In Restricted Mode you can still edit, navigate and see gopls diagnostics, but Run, Debug, Test, Profile, terminals and automatic toolchain downloads are off."
        alert.addButton(withTitle: "Trust and Open")
        alert.addButton(withTitle: "Open in Restricted Mode")
        alert.addButton(withTitle: "Cancel")
        let parentBox = NSButton(checkboxWithTitle: "Also trust projects in “\(root.deletingLastPathComponent().lastPathComponent)”", target: nil, action: nil)
        alert.accessoryView = parentBox
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (true, parentBox.state == .on)
        case .alertSecondButtonReturn: return (false, false)
        default: return nil
        }
    }

    /// `GobiApp FOLDER --selftest`: opens the explorer, opens a file from it and checks the editor shows it.
    private func runProjectSelfTest(_ controller: ProjectWindowController) {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: controller.root.path)) ?? []).sorted()
        check("project kind is \(controller.kind)", controller.kind == ProjectKind.detect(entryNames: names))
        check("the status text keeps 14 points or more from the window edge (\(controller.statusTextInset))", controller.statusTextInset >= 14)
        check("the explorer lists the folder (\(controller.explorerRowCount) rows)", controller.explorerRowCount > 0)
        let first = names.first { name in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: controller.root.appendingPathComponent(name).path, isDirectory: &isFolder) && !isFolder.boolValue && name.hasSuffix(".go")
        }
        let goFiles = names.filter { $0.hasSuffix(".go") }.prefix(2).map { controller.root.appendingPathComponent($0) }
        if let url = goFiles.first {
            check("opening \(url.lastPathComponent) shows an editor", controller.openFile(url) && controller.currentPane?.editor.document.fileURL == url)
            check("the same file opens again from its kept pane", controller.openFile(url))
            check("one tab for the file opened twice", controller.tabs.paths == [url.path] && controller.tabTitles == [url.lastPathComponent])
            if goFiles.count == 2 {
                check("opening several files at once gives each a tab", controller.openFiles(goFiles) == 2 && controller.tabs.paths.count == 2 && controller.tabs.active == goFiles[1].path)
                controller.closeTab(goFiles[1].path)
            }
            if goFiles.count == 2 {
                controller.openFile(goFiles[1])
                check("a second file adds a tab and activates it", controller.tabs.paths.count == 2 && controller.tabs.active == goFiles[1].path)
                controller.selectNextTab()
                check("next tab wraps to the first file", controller.tabs.active == url.path)
            }
            // Editing marks the tab; saving is only exercised with --allow-writes (it rewrites the file).
            if let pane = controller.currentPane, !pane.editor.document.isReadOnlyByLineLength {
                pane.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
                check("typing marks the tab unsaved", controller.tabs.isDirty(url.path))
                if CommandLine.arguments.contains("--allow-writes") {
                    check("saving writes the file and clears the mark", pane.save() && !controller.tabs.isDirty(url.path) && (try? String(contentsOf: url, encoding: .utf8)) == pane.textView.string)
                    pane.textView.insertText("", replacementRange: NSRange(location: 0, length: 1))
                    pane.save()
                } else {
                    pane.editor.document.isEdited = false   // leave the user's file alone
                }
            }
            check("closing a clean tab removes it", controller.closeTab(url.path) && !controller.tabs.paths.contains(url.path))
        } else {
            print("  note no .go file at the top of the folder; skipped the open-file checks")
        }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    @discardableResult
    private func open(_ url: URL, selfTest: Bool, snapshotPath: String?) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if selfTest {
                print("cannot read \(url.path)")   // a modal alert would hang a scripted run
                exit(1)
            } else {
                let alert = NSAlert()
                alert.messageText = "Cannot open \(url.lastPathComponent)"
                alert.informativeText = "The file is not readable as UTF-8 text."
                alert.runModal()
            }
            return false
        }
        let controller = EditorWindowController(fileURL: url, text: text)
        controllers.append(controller)
        if NSApp.activationPolicy() != .regular { controller.window?.alphaValue = 0; controller.window?.ignoresMouseEvents = true }
        controller.showWindow(nil)
        controller.connect()
        if selfTest {
            controller.runSelfTest(timeout: 90, snapshotPath: snapshotPath) { passed in
                print(passed ? "SELFTEST PASSED" : "SELFTEST FAILED")
                exit(passed ? 0 : 1)
            }
        }
        return true
    }

    // MARK: tabs and saving

    private var frontProject: ProjectWindowController? { NSApp.keyWindow?.windowController as? ProjectWindowController }

    @objc func saveFile(_ sender: Any?) {
        if let project = frontProject { project.saveCurrent() }
        else if let single = NSApp.keyWindow?.windowController as? EditorWindowController { single.pane.save() }
    }

    /// ⌘W closes the active tab of a project window; any other window closes itself.
    @objc func closeTab(_ sender: Any?) {
        if let project = frontProject, project.currentPane != nil { project.closeCurrentTab() }
        else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc func nextTab(_ sender: Any?) { frontProject?.selectNextTab() }
    @objc func previousTab(_ sender: Any?) { frontProject?.selectPreviousTab() }

    // MARK: find

    private var frontEditor: EditorView? {
        if let project = frontProject { return project.currentPane?.editor }
        return (NSApp.keyWindow?.windowController as? EditorWindowController)?.editor
    }

    @objc func showFind(_ sender: Any?) { frontEditor?.showFindBar() }
    @objc func findNext(_ sender: Any?) { frontEditor?.findNext() }
    @objc func findPrevious(_ sender: Any?) { frontEditor?.findPrevious() }
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let editor = frontEditor else { return }
        let text = editor.textView.string as NSString
        let selected = editor.textView.selectedRange()
        if selected.length > 0 { editor.setSearchString(text.substring(with: selected)) }
    }

    // MARK: menu

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Gobi", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gobi", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Gobi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New Project…", action: #selector(newProject(_:)), keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let cloneItem = fileMenu.addItem(withTitle: "Clone Repository…", action: #selector(cloneRepository(_:)), keyEquivalent: "k")
        cloneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Import Existing Code…", action: #selector(importCode(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Save", action: #selector(saveFile(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        let nextTab = fileMenu.addItem(withTitle: "Show Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let previousTab = fileMenu.addItem(withTitle: "Show Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(showFind(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNext(_:)), keyEquivalent: "g")
        let previous = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Use Selection for Find", action: #selector(useSelectionForFind(_:)), keyEquivalent: "e")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
