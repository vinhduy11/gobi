import AppKit
import GobiClient
import GobiEditor

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [EditorWindowController] = []
    private var projects: [ProjectWindowController] = []
    private var welcome: WelcomeWindowController?

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
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder, a go.mod or go.work, or a single file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openChosen(url)
    }

    /// A folder, go.mod or go.work opens a project window; any other file opens on its own.
    @discardableResult
    private func openChosen(_ url: URL) -> Bool {
        if let root = ProjectFolder.projectRoot(for: url) { return openProject(root) }
        return open(url, selfTest: selfTest, snapshotPath: snapshotPath)
    }

    private func showWelcome() {
        let controller = welcome ?? WelcomeWindowController()
        controller.onOpenFolder = { [weak self] in self?.openDocument(nil) }
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
        check("the explorer lists the folder (\(controller.explorerRowCount) rows)", controller.explorerRowCount > 0)
        let first = names.first { name in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: controller.root.appendingPathComponent(name).path, isDirectory: &isFolder) && !isFolder.boolValue && name.hasSuffix(".go")
        }
        if let first {
            let url = controller.root.appendingPathComponent(first)
            check("opening \(first) shows an editor", controller.openFile(url) && controller.currentPane?.editor.document.fileURL == url)
            check("the same file opens again from its kept pane", controller.openFile(url))
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

    // MARK: find

    private var frontEditor: EditorView? { (NSApp.keyWindow?.windowController as? EditorWindowController)?.editor }

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
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
