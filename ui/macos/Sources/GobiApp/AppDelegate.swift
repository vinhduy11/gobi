import AppKit
import GobiClient
import GobiModel
import GobiEditor

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [EditorWindowController] = []
    private var projects: [ProjectWindowController] = []
    private var welcome: WelcomeWindowController?
    private let dialogs = ProjectDialogs()
    private var pendingProjectSelfTest: ProjectWindowController?

    private let selfTest = CommandLine.arguments.contains("--selftest")
    private let snapshotPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        if let pending = pendingProjectSelfTest { runProjectSelfTest(pending) }
        // Paths on the command line reach us through application(_:openFile:), which AppKit calls for each one.
        if CommandLine.arguments.contains("--selftest-welcome") { runWelcomeSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-newproject") { runNewProjectSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-trust") { runTrustSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-terminal") { runTerminalSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-codehelp") { runCodeHelpSelfTest(); return }
        if controllers.isEmpty && projects.isEmpty && !selfTest { openLastProjectOrWelcome() }
        if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Several files at once (dropped on the Dock icon, or `open -a Gobi a.go b.go`) open as tabs of one project.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit also offers option values that look like paths (the --snapshot target); those are not documents.
        let urls = filenames.filter { $0 != snapshotPath }.map { URL(fileURLWithPath: $0) }
        openChosen(urls)
        sender.reply(toOpenOrPrint: .success)
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
        // A file goes to the front project when it is inside it, else to another open project or a recent one that holds it.
        while let file = rest.first(where: { ProjectFolder.projectRoot(for: $0) == nil }) {
            guard let project = projectHolding(file) else { break }
            let inside = rest.filter { ProjectFolder.projectRoot(for: $0) == nil && project.contains($0) }
            project.openFiles(inside)
            project.showWindow(nil)
            rest.removeAll { url in inside.contains(url) }
        }
        for url in rest { openChosen(url) }
    }

    private func projectHolding(_ file: URL) -> ProjectWindowController? {
        if let front = frontProject, front.contains(file) { return front }
        if let open = projects.first(where: { $0.contains(file) }) { return open }
        let recent = ProjectStore.shared.recents.items.first { file.path.hasPrefix($0.path + "/") && FileManager.default.fileExists(atPath: $0.path) }
        guard let recent, openProject(URL(fileURLWithPath: recent.path), askAboutTrust: false) else { return nil }
        return projects.first { $0.root.path == recent.path }
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

    /// At launch the newest recent project reopens; with none, or with Option held, the Welcome window shows.
    /// A project that is not trusted reopens in Restricted Mode without asking again.
    private func openLastProjectOrWelcome() {
        let skip = NSEvent.modifierFlags.contains(.option) || ProjectStore.shared.showWelcomeAtLaunch
        let last = ProjectStore.shared.recents.mostRecent { FileManager.default.fileExists(atPath: $0) }
        if !skip, let last, openProject(URL(fileURLWithPath: last.path), askAboutTrust: false) { return }
        showWelcome()
    }

    /// `GobiApp --selftest-welcome [--snapshot PNG]`: builds the Welcome window quietly, checks it and optionally paints it.
    private func runWelcomeSelfTest() {
        showWelcome()
        guard let welcome else { exit(1) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        let recents = ProjectStore.shared.recents.items
        check("every recent project has a row (\(welcome.visibleRowCount) of \(recents.count))", welcome.visibleRowCount == recents.count)
        check("the window has the mock's size", welcome.window?.frame.size == NSSize(width: 1100, height: 680))
        if let snapshotPath { welcome.snapshotWindow(to: snapshotPath) }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `GobiApp --selftest-newproject [--snapshot PNG]`: fills the New Project window, waits for gobid's preview and checks it.
    private func runNewProjectSelfTest() {
        let window = NewProjectWindowController()
        window.showWindow(nil)
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        check("Create is off until a name is typed", !window.isCreateEnabled)
        window.type(name: "hello")
        check("Create is on for a valid name", window.isCreateEnabled)
        settle { window.previewString.contains("main_test.go") }
        check("the preview lists the files gobid will write (\(window.previewString.split(separator: "\n").count) lines)", window.previewString.contains("hello/") && window.previewString.contains("go.mod") && window.previewString.contains("main_test.go") && window.previewString.contains(".env.example"))
        window.setSampleTest(false)
        settle { !window.previewString.contains("main_test.go") }
        check("turning the sample test off removes main_test.go from the preview", !window.previewString.contains("main_test.go"))
        window.setSampleTest(true)
        window.choose(templateTitled: "gRPC service")
        check("an unavailable template cannot be created", !window.isCreateEnabled)
        window.choose(templateTitled: "Workspace go.work (multi-module)")
        settle { window.previewString.contains("go.work") }
        check("the workspace preview has go.work and an app folder", window.previewString.contains("go.work") && window.previewString.contains("app/"))
        window.choose(templateTitled: "Command-line tool")
        settle { window.previewString.contains("main_test.go") && !window.previewString.contains("go.work") }
        check("choosing the command-line tool again lists main_test.go and no go.work", window.previewString.contains("main_test.go") && !window.previewString.contains("go.work"))
        if let snapshotPath { window.snapshotWindow(to: snapshotPath) }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `GobiApp --selftest-trust [--snapshot PNG]`: builds the trust window quietly and checks its wording.
    private func runTrustSelfTest() {
        let window = TrustWindowController(root: URL(fileURLWithPath: NSHomeDirectory() + "/Work/hello"))
        window.showWindow(nil)
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        check("the question names the project", window.headline == "Do you trust the authors of “hello”?")
        check("the parent option names the folder (\(window.parentName))", window.parentName == "~/Work")
        check("the window has the mock's size", window.window?.contentLayoutRect.size == NSSize(width: 560, height: 400))
        if let snapshotPath { window.snapshotWindow(to: snapshotPath) }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `GobiApp FOLDER --selftest-terminal [--snapshot PNG]`: opens the folder trusted, starts a shell in the Terminal tab,
    /// runs a command and checks what the terminal shows; also checks the Restricted notice for an untrusted project.
    private func runTerminalSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-terminal"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 12, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let restricted = ProjectWindowController(root: root, kind: .module, isTrusted: false)
        restricted.showWindow(nil)
        restricted.showTerminalTab()
        check("an untrusted project shows the Restricted notice and starts no shell", restricted.isTerminalNoticeShowing && restricted.terminalSessionCount == 0)
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.showTerminalTab()
        settle { controller.terminalSessionCount == 1 }
        check("opening the Terminal tab starts one shell (\(controller.terminalTitles))", controller.terminalSessionCount == 1 && !controller.isTerminalNoticeShowing)
        // The user's shell start-up files may read the terminal too, so type only once the screen has stopped changing.
        var lastText = "", stableSince = Date()
        settle(20) {
            let text = controller.terminalText
            if text != lastText { lastText = text; stableSince = Date() }
            return !text.isEmpty && Date().timeIntervalSince(stableSince) > 1.5
        }
        controller.typeInTerminal("echo result-$((1+2)); pwd\r")
        settle { controller.terminalText.contains("result-3") }
        check("a command typed into it runs and its output is on screen", controller.terminalText.contains("result-3"))
        check("the shell started in the project folder", controller.terminalText.contains(root.lastPathComponent))
        controller.runInTerminal("echo menu-ran-$((20+22))", inFolder: root)
        settle { controller.terminalText.contains("menu-ran-42") }
        check("a command from a menu (Go Mod Tidy and friends) runs in the terminal", controller.terminalText.contains("menu-ran-42"))
        controller.newTerminal()
        settle { controller.terminalSessionCount == 2 }
        check("New Terminal adds a second tab (\(controller.terminalTitles))", controller.terminalSessionCount == 2)
        controller.killTerminal()
        check("Kill Terminal removes it", controller.terminalSessionCount == 1)
        if let snapshotPath { controller.snapshotWindow(to: snapshotPath) }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `GobiApp FOLDER --selftest-codehelp`: right-click menus, Go to Definition and Format Document against a real gopls.
    /// The folder needs a.go (declares `helper`), b.go (calls it) and c.go (badly formatted). It rewrites c.go in memory only.
    private func runCodeHelpSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-codehelp"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 25, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        func perform(_ title: String, in menu: NSMenu) {
            guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else { return }
            menu.performActionForItem(at: index)
        }
        let root = URL(fileURLWithPath: path)
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.openFile(root.appendingPathComponent("b.go"))

        // Tab and explorer menus.
        let tabMenu = controller.tabMenu(path: root.appendingPathComponent("a.go").path)
        check("the tab menu has the mock's items, all live (\(tabMenu.items.filter { !$0.isSeparatorItem }.map { $0.title }))", tabMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Close", "Close Others", "Close Tabs to the Right", "Copy Path", "Reveal in Finder"] && tabMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
        perform("Copy Path", in: tabMenu)
        check("Copy Path puts the file's path on the pasteboard", NSPasteboard.general.string(forType: .string) == root.appendingPathComponent("a.go").path)
        let explorerMenu = controller.explorerMenu(row: 0)
        let copyPathMenu = explorerMenu?.items.first { $0.title == "Copy Path" }?.submenu
        perform("Path from Project Root", in: copyPathMenu ?? NSMenu())
        check("Copy Path > Path from Project Root gives a path inside the project", NSPasteboard.general.string(forType: .string) == "a.go")
        check("New, Cut, Copy, Paste and Delete are in the explorer menu but disabled until they exist", ["New", "Cut", "Copy", "Paste", "Delete…", "Refactor", "Find in Files…"].allSatisfy { title in explorerMenu?.items.first { $0.title == title }?.isEnabled == false })
        let modRow = (0 ..< controller.explorerRowCount).first { controller.explorerRowTitle($0) == "go.mod" }
        check("Go Mod Tidy and Download Go Modules are live on go.mod", modRow.flatMap { controller.explorerMenu(row: $0) }.map { menu in ["Go Mod Tidy", "Download Go Modules"].allSatisfy { title in menu.items.first { $0.title == title }?.isEnabled == true } } ?? false)
        check("and absent on a plain Go file", explorerMenu?.items.first { $0.title == "Go Mod Tidy" }?.isEnabled == false)

        // gopls.
        settle { controller.currentPane?.isConnected == true }
        check("gopls is connected", controller.currentPane?.isConnected == true)
        guard let pane = controller.currentPane else { print("SELFTEST FAILED"); exit(1) }
        let editorMenu = controller.editorMenu(for: pane)
        check("the editor menu enables Go to Definition, Format and the text commands, and disables Rename", ["Go to Definition", "Format Document", "Cut", "Copy", "Paste", "Select All", "Reveal in Finder", "Copy Path"].allSatisfy { title in editorMenu.items.first { $0.title == title }?.isEnabled == true } && editorMenu.items.first { $0.title == "Rename Symbol…" }?.isEnabled == false)

        let text = pane.textView.string as NSString
        let call = text.range(of: "helper")
        pane.textView.setSelectedRange(NSRange(location: call.location + 2, length: 0))
        settle(3) { false }   // let gopls finish indexing the open files
        controller.goToDefinition()
        settle { controller.currentPane?.editorFile.fileURL.lastPathComponent == "a.go" }
        check("Go to Definition opens the declaring file", controller.currentPane?.editorFile.fileURL.lastPathComponent == "a.go")
        let declared = controller.currentPane
        let declaration = (declared?.textView.string as NSString?)?.range(of: "func helper")
        check("the caret is on the declared name", declared != nil && declaration != nil && NSLocationInRange(declared!.textView.selectedRange().location, NSRange(location: declaration!.location, length: declaration!.length + 1)))

        controller.openFile(root.appendingPathComponent("c.go"))
        settle { controller.currentPane?.isConnected == true }
        let before = controller.currentPane?.textView.string ?? ""
        controller.formatDocument()
        settle { controller.currentPane?.textView.string != before }
        let after = controller.currentPane?.textView.string ?? ""
        check("Format Document rewrites badly formatted code (gofmt)", after != before && after.contains("func main() {"))
        controller.currentPane?.textView.undoManager?.undo()
        check("and it is one undo step", controller.currentPane?.textView.string == before)
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private func showWelcome() {
        let controller = welcome ?? WelcomeWindowController()
        controller.onOpenFolder = { [weak self] in self?.openDocument(nil) }
        controller.onNewProject = { [weak self] in self?.newProject(nil) }
        controller.onClone = { [weak self] in self?.cloneRepository(nil) }
        controller.onImport = { [weak self] in self?.importCode(nil) }
        controller.onDropFolder = { [weak self] url in self?.openChosen(url) }
        controller.onClearRecents = { [weak self] in self?.clearRecents(nil) }
        controller.onOpenRecent = { [weak self] project in self?.openProject(URL(fileURLWithPath: project.path)) }
        welcome = controller
        controller.reload()
        controller.showWindow(nil)
    }

    @discardableResult
    private func openProject(_ root: URL, askAboutTrust: Bool = true) -> Bool {
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
        if !trust.isTrusted(path: root.path), askAboutTrust, !selfTest, let answer = askTrust(root) {
            if answer.trusted { trust.trust(path: answer.parentToo ? root.deletingLastPathComponent().path : root.path) }
            ProjectStore.shared.trust = trust
        } else if !trust.isTrusted(path: root.path), askAboutTrust, !selfTest {
            return false   // Cancel
        }
        let kind = ProjectFolder.kind(of: root)
        let controller = ProjectWindowController(root: root, kind: kind, isTrusted: trust.isTrusted(path: root.path))
        projects.append(controller)
        ProjectStore.shared.recents.add(path: root.path, kind: kind)
        welcome?.close()
        if NSApp.activationPolicy() != .regular { controller.window?.alphaValue = 0; controller.window?.ignoresMouseEvents = true }
        controller.onTrustRequested = { [weak self, weak controller] in
            guard let self, let controller, let answer = self.askTrust(controller.root), answer.trusted else { return }
            var list = ProjectStore.shared.trust
            list.trust(path: answer.parentToo ? controller.root.deletingLastPathComponent().path : controller.root.path)
            ProjectStore.shared.trust = list
            // The terminal and gopls start restricted or not when the project opens, so open it again, now trusted.
            self.projects.removeAll { $0 === controller }
            controller.window?.close()
            self.openProject(controller.root, askAboutTrust: false)
        }
        controller.showWindow(nil)
        if selfTest {
            // AppKit hands over command-line files before the launch finishes, and the menu is built when it does.
            if NSApp.mainMenu != nil { runProjectSelfTest(controller) } else { pendingProjectSelfTest = controller }
        }
        return true
    }

    /// nil means Cancel; otherwise whether to trust, and whether to trust the whole parent folder.
    private func askTrust(_ root: URL) -> (trusted: Bool, parentToo: Bool)? {
        switch TrustWindowController(root: root).runModal() {
        case .trust(let parentToo): return (true, parentToo)
        case .restricted: return (false, false)
        case .cancel: return nil
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
        let titles = NSApp.mainMenu?.items.map { $0.submenu?.title ?? $0.title } ?? []
        check("the menu bar has the mock's menus (\(titles.joined(separator: ", ")))", titles == ["Gobi", "File", "Edit", "View", "Go", "Run", "Debug", "Window", "Help"])
        // Every live item with a shortcut in the spec has the matching key equivalent in the real menu bar.
        var mismatches: [String] = []
        for definition in MenuSpec.all {
            guard let menu = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { $0.title == (definition.title == "Gobi" ? "Gobi" : definition.title) }) else { continue }
            for entry in definition.entries where !entry.isSeparator && entry.action != nil && !entry.shortcut.isEmpty {
                if entry.action == "fullScreen" { continue }   // macOS assigns the system full-screen key itself
                guard let item = menu.items.first(where: { $0.title == entry.title }), let want = MainMenuBuilder.keyEquivalent(for: entry.shortcut) else { mismatches.append(entry.title); continue }
                if item.keyEquivalent != want.key || item.keyEquivalentModifierMask != want.modifiers { mismatches.append("\(entry.title) has \(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue), wants \(want.key.debugDescription) \(want.modifiers.rawValue)") }
            }
        }
        check("every live menu item has its shortcut (mismatches: \(mismatches))", mismatches.isEmpty)
        let recentMenu = NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.title == "Open Recent" }?.submenu
        recentMenu.map { menuNeedsUpdate($0) }
        check("Open Recent lists this project first", recentMenu?.items.first?.title == controller.root.lastPathComponent)
        check("Open Recent ends with Clear Menu", recentMenu?.items.last?.title == "Clear Menu")
        check("the status bar shows the project, not a stale line (\(controller.statusBarTexts.filter { !$0.isEmpty }))", controller.statusBarTexts.contains { $0.hasPrefix("gopls") })
        check("the bottom panel has the mock's seven tabs", controller.panelTabTitles.count == 7 && controller.panelTabTitles.last == "Output")
        check("the explorer lists the folder (\(controller.explorerRowCount) rows)", controller.explorerRowCount > 0)
        let first = names.first { name in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: controller.root.appendingPathComponent(name).path, isDirectory: &isFolder) && !isFolder.boolValue && name.hasSuffix(".go")
        }
        let goFiles = names.filter { $0.hasSuffix(".go") }.prefix(2).map { controller.root.appendingPathComponent($0) }
        if let url = goFiles.first {
            check("opening \(url.lastPathComponent) shows an editor", controller.openFile(url) && controller.currentPane?.editor.document.fileURL == url)
            check("the same file opens again from its kept pane", controller.openFile(url))
            check("the breadcrumb shows the project and the file (\(controller.breadcrumbText))", controller.breadcrumbText == "\(controller.root.lastPathComponent)  ›  \(url.lastPathComponent)")
            check("the status bar shows the caret and the line ending", controller.statusBarTexts.contains("Ln 1, Col 1") && controller.statusBarTexts.contains("LF"))
            controller.toggleBottomPanel()
            check("the bottom panel hides and shows again", !controller.isBottomPanelVisible)
            controller.toggleBottomPanel()
            check("the bottom panel is back", controller.isBottomPanelVisible)
            check("one tab for the file opened twice", controller.tabs.paths == [url.path] && controller.tabTitles == [url.lastPathComponent])
            if goFiles.count == 2 {
                check("opening several files at once gives each a tab", controller.openFiles(goFiles) == 2 && controller.tabs.paths.count == 2 && controller.tabs.active == goFiles[1].path)
                controller.closeTab(goFiles[1].path)
            }
            if goFiles.count == 2 {
                controller.openFile(goFiles[1])
                let projectCount = projects.count
                openChosen(goFiles)   // what dropping both files on the Dock icon does
                check("opening several files from outside opens tabs in the same project, not new windows", projects.count == projectCount && controller.tabs.paths.count == 2)
                let frames = controller.tabFrames
                check("every tab is drawn with a real size inside the bar (\(frames.map { "\(Int($0.width))x\(Int($0.height))" }))", frames.count == 2 && frames.allSatisfy { $0.width > 40 && $0.height > 12 && $0.maxX <= controller.tabBarSize.width + 1 })
                if let snapshotPath { controller.snapshotWindow(to: snapshotPath) }
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

    // MARK: open recent

    /// Rebuilt each time the submenu opens, so it always matches the stored list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let entries = ProjectStore.shared.recents.menuItems(limit: 10)
        for entry in entries {
            let item = menu.addItem(withTitle: entry.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = entry.path
            item.toolTip = (entry.path as NSString).abbreviatingWithTildeInPath
        }
        if entries.isEmpty { menu.addItem(withTitle: "No Recent Projects", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.isEnabled = !entries.isEmpty
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openProject(URL(fileURLWithPath: path))
    }

    @objc func clearRecents(_ sender: Any?) {
        var recents = ProjectStore.shared.recents
        recents.clear()
        ProjectStore.shared.recents = recents
        welcome?.reload()
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

    private var shortcuts: ShortcutsWindowController?

    @objc func showShortcuts(_ sender: Any?) {
        let controller = shortcuts ?? ShortcutsWindowController()
        shortcuts = controller
        controller.showWindow(nil)
    }

    @objc func goToDefinition(_ sender: Any?) { frontProject?.goToDefinition() }
    @objc func formatDocument(_ sender: Any?) { frontProject?.formatDocument() }
    @objc func closeProject(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }
    @objc func saveAll(_ sender: Any?) { frontProject?.saveAll() }
    @objc func toggleSidebar(_ sender: Any?) { frontProject?.toggleSidebar() }
    @objc func toggleBottomPanel(_ sender: Any?) { frontProject?.toggleBottomPanel() }

    @objc func revealInFinder(_ sender: Any?) {
        if let file = frontProject?.currentPane?.editorFile.fileURL ?? (NSApp.keyWindow?.windowController as? EditorWindowController)?.editor.document.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let root = frontProject?.root {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
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
        NSApp.mainMenu = MainMenuBuilder.build(target: self, recentDelegate: self)
    }
}
