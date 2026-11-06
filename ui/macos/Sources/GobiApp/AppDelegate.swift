import AppKit
import GobiClient
import GobiModel
import GobiEditor

/// What a self-test must put back (preferences, fixture files, helper processes) before it ends. `exit` skips `defer`, so the
/// tests register their clean-up here and leave through `selfTestExit`.
private var selfTestCleanups: [() -> Void] = []

private func selfTestExit(_ failures: Int) -> Never {
    selfTestCleanups.reversed().forEach { $0() }
    selfTestCleanups.removeAll()
    print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED")
    exit(failures == 0 ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [EditorWindowController] = []
    private(set) var projects: [ProjectWindowController] = []
    var welcome: WelcomeWindowController?
    private let dialogs = ProjectDialogs()
    private var pendingProjectSelfTest: ProjectWindowController?

    private let selfTest = CommandLine.arguments.contains("--selftest")
    private let snapshotPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let previousRunCrashed = LogSupport.start()
        AppPreferences.migrateKeymap()
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) { DispatchQueue.global(qos: .utility).async { RecoveryStore.prune() } }
        installMenu()
        NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in self?.installMenu() }   // a changed shortcut reaches the menu bar
        WindowSettings.applyAppearance()
        if let pending = pendingProjectSelfTest { runProjectSelfTest(pending) }
        // Paths on the command line reach us through application(_:openFile:), which AppKit calls for each one.
        if CommandLine.arguments.contains("--selftest-welcome") { runWelcomeSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-newproject") { runNewProjectSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-trust") { runTrustSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-terminal") { runTerminalSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-codehelp") { runCodeHelpSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-lang") { runLanguageSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-toolchain") { runToolchainSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-debug") { runDebugSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-profile") { runProfileSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-git") { runGitSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-env") { runEnvironmentSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-settings") { runSettingsSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-find") { runFindSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-session") { runSessionSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-setup") { runSetupSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-run") { runRunSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-crash") { runCrashSelfTest(); return }
        if controllers.isEmpty && projects.isEmpty && !selfTest { openLastProjectOrWelcome(); checkSetupAtLaunch() }
        if previousRunCrashed { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showCrashNotice() } }
        if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Settings > General > Confirm: ask before quitting while a file has unsaved changes or a run or debug session is going.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let message = quitMessage() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Gobi?"
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func quitMessage() -> String? {
        QuitConfirmation.message(unsavedFiles: projects.reduce(0) { $0 + $1.unsavedFileCount }, runningTasks: projects.reduce(0) { $0 + $1.runningTaskCount }, enabled: AppPreferences.general.confirmQuit)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogSupport.quit()
        for project in projects where project.persistsSession { project.saveSession(); project.saveRecoveries() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Several files at once (dropped on the Dock icon, or `open -a Gobi a.go b.go`) open as tabs of one project.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit also offers option values that look like paths (the --snapshot target); those are not documents.
        // A feature self-test (--selftest-NAME) builds its own window from the folder argument; opening it here as well would
        // restore a saved session, ask about trust and start the file watcher.
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest-") }) else { sender.reply(toOpenOrPrint: .success); return }
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
        selfTestExit(failures)
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
        selfTestExit(failures)
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
        selfTestExit(failures)
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
        let layout = controller.panelTabLayout
        let gaps = zip(layout, layout.dropFirst()).map { $1.frame.minX - $0.frame.maxX }
        check("the panel tabs are spaced apart and exactly one is current (gaps \(gaps.map { Int($0) }))", gaps.allSatisfy { $0 >= 2 } && layout.filter(\.isCurrent).count == 1 && layout.allSatisfy { $0.frame.width >= 40 })
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
        check("a command typed into it runs and its output is on screen (\(controller.terminalText.suffix(160).debugDescription))", controller.terminalText.contains("result-3"))
        check("the shell started in the project folder", controller.terminalText.contains(root.lastPathComponent))
        let palette = TerminalPalette.forAppearance(isDark: controller.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        check("the terminal uses the palette's background (\(controller.terminalBackground.map(String.init(describing:)) ?? "none"))", controller.terminalBackground == [Int(palette.background.red), Int(palette.background.green), Int(palette.background.blue)])
        controller.runInTerminal("echo menu-ran-$((20+22))", inFolder: root)
        settle { controller.terminalText.contains("menu-ran-42") }
        check("a command from a menu (Go Mod Tidy and friends) runs in the terminal", controller.terminalText.contains("menu-ran-42"))
        controller.newTerminal()
        settle { controller.terminalSessionCount == 2 }
        check("New Terminal adds a second tab (\(controller.terminalTitles))", controller.terminalSessionCount == 2)
        controller.killTerminal()
        check("Kill Terminal removes it", controller.terminalSessionCount == 1)

        // Find, split, shell choice, View > New Terminal.
        controller.findInTerminal("result-3")
        check("Find in Terminal counts the matches (\(controller.terminalFindStatus))", controller.terminalFindStatus.contains(" of "))
        controller.findInTerminal("zzzz-not-there")
        check("and says when there are none (\(controller.terminalFindStatus))", controller.terminalFindStatus == "No matches")
        controller.splitTerminal()
        check("Split Terminal puts a second shell beside the first", controller.terminalIsSplit && controller.terminalSessionCount == 1)
        settle(10) { !controller.terminalShellList.isEmpty }
        let menu = controller.terminalMenuItems
        check("the terminal menu lists the mock's actions and the shells (\(menu.map(\.title)))", ["New Terminal", "Split Terminal", "Kill Terminal", "Clear", "Find in Terminal", "Terminal settings…"].allSatisfy { title in menu.contains { $0.title == title } } && menu.contains { $0.title.hasSuffix("(login shell)") && $0.checked })
        let savedShell = WindowSettings.terminalShell
        selfTestCleanups.append { WindowSettings.terminalShell = savedShell }
        if controller.terminalShellList.contains("/bin/bash") {
            WindowSettings.terminalShell = "/bin/bash"
            controller.openNewTerminal()
            settle { controller.terminalSessionCount == 2 }
            settle(10) { controller.terminalText.contains("bash") || !controller.terminalText.isEmpty }
            var quiet = Date()
            var previous = ""
            settle(15) { let t = controller.terminalText; if t != previous { previous = t; quiet = Date() }; return !t.isEmpty && Date().timeIntervalSince(quiet) > 1.5 }
            controller.typeInTerminal("echo version-$BASH_VERSION-end\r")
            settle { controller.terminalText.contains("version-") && !controller.terminalText.contains("version-$BASH_VERSION") }
            let line = controller.terminalText.split(separator: "\n").first { $0.hasPrefix("version-") } ?? ""
            check("a chosen shell is the one that starts: bash reports its version (\(line))", line.hasPrefix("version-") && line != "version--end" && line.hasSuffix("-end"))
        }
        if let snapshotPath { controller.snapshotWindow(to: snapshotPath) }
        selfTestExit(failures)
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
        // The test edits files in memory; automatic saving would write those edits into the fixture.
        let originalPreferences = EditorPreferences.current
        EditorPreferences.update { $0.autoSave = .off }
        selfTestCleanups.append { EditorPreferences.current = originalPreferences }
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
        check("Cut, Copy, Delete and Refactor are live on a file row", ["Cut", "Copy", "Delete…", "Refactor"].allSatisfy { title in explorerMenu?.items.first { $0.title == title }?.isEnabled == true })
        check("Rename and Move are live in Refactor", explorerMenu?.items.first { $0.title == "Refactor" }?.submenu?.items.map(\.isEnabled) == [true, true])
        let modRow = (0 ..< controller.explorerRowCount).first { controller.explorerRowTitle($0) == "go.mod" }
        check("Go Mod Tidy and Download Go Modules are live on go.mod", modRow.flatMap { controller.explorerMenu(row: $0) }.map { menu in ["Go Mod Tidy", "Download Go Modules"].allSatisfy { title in menu.items.first { $0.title == title }?.isEnabled == true } } ?? false)

        // The bottom panel is not locked to one height: its divider moves it, and it keeps a few rows.
        let panelHeight = controller.bottomPanelHeight
        check("the bottom panel starts about 210 pt tall (\(Int(panelHeight)) pt)", panelHeight >= 190 && panelHeight <= 230)
        controller.moveCentreDivider(toBottomHeight: 340)
        check("dragging its divider makes it taller (\(Int(panelHeight)) to \(Int(controller.bottomPanelHeight)) pt)", controller.bottomPanelHeight >= 320)
        controller.moveCentreDivider(toBottomHeight: 20)
        check("and it cannot be dragged smaller than a few rows (\(Int(controller.bottomPanelHeight)) pt)", controller.bottomPanelHeight >= 90)
        controller.moveCentreDivider(toBottomHeight: panelHeight)

        // A project with no files: the explorer has no rows, but a right click on the empty space still gives the project's menu,
        // and New makes files (a Go file takes the package of the folder).
        let emptyRoot = root.appendingPathComponent("gobi-empty-project")
        try? FileManager.default.removeItem(at: emptyRoot)
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        selfTestCleanups.append { try? FileManager.default.removeItem(at: emptyRoot) }
        let emptyController = ProjectWindowController(root: emptyRoot, kind: .folder, isTrusted: true)
        emptyController.showWindow(nil)
        let blankMenu = emptyController.explorerMenu(row: -1)
        check("right-clicking the empty space of an empty project gives the project's menu (\(blankMenu?.items.map(\.title).prefix(4).joined(separator: ", ") ?? "none"))", blankMenu != nil && blankMenu?.items.first { $0.title == "New" }?.isEnabled == true)
        let newItems = blankMenu?.items.first { $0.title == "New" }?.submenu?.items.map { $0.isEnabled } ?? []
        check("every New entry is live (\(newItems))", !newItems.isEmpty && newItems.filter { $0 }.count == 4)
        let goFile = emptyController.newEntry(.goFile, in: emptyRoot, name: "cart")
        check("New > Go File makes cart.go with the folder's package", goFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "package gobi_empty_project\n")
        let testFile = emptyController.newEntry(.goTestFile, in: emptyRoot, name: "cart")
        check("New > Go Test File takes the package of the Go file next to it", testFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "package gobi_empty_project\n\nimport \"testing\"\n")
        check("New > Folder and New > File work, and a name that exists is refused", emptyController.newEntry(.folder, in: emptyRoot, name: "internal") != nil && emptyController.newEntry(.file, in: emptyRoot, name: "notes.md") != nil && emptyController.newEntry(.file, in: emptyRoot, name: "notes.md") == nil)
        check("the explorer lists what was made (\(emptyController.explorerNames))", Set(emptyController.explorerNames) == ["cart.go", "cart_test.go", "internal", "notes.md"])

        // Typing: brackets and quotes close themselves, a closer is skipped over, Backspace takes a pair, Return keeps the indentation.
        if let typingURL = emptyController.newEntry(.file, in: emptyRoot, name: "typing.go"), let view = emptyController.currentPane?.textView {
            func reset() { view.insertText("", replacementRange: NSRange(location: 0, length: (view.string as NSString).length)) }
            func type(_ text: String) { for character in text { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
            reset(); type("{")
            check("typing { also types } and keeps the caret between (\(view.string.debugDescription), \(view.selectedRange().location))", view.string == "{}" && view.selectedRange().location == 1)
            type("}")
            check("typing } before a } moves over it", view.string == "{}" && view.selectedRange().location == 2)
            reset(); type("{"); view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check("Return between { and } opens an indented block (\(view.string.debugDescription))", view.string == "{\n\t\n}" && view.selectedRange().location == 3)
            reset(); type("\tx := f("); view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check("Return keeps the line's indentation (\(view.string.debugDescription))", view.string == "\tx := f(\n\t\t\n\t)" || view.string == "\tx := f()\n\t\t")
            reset(); type("("); view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            check("Backspace between a pair removes both (\(view.string.debugDescription))", view.string.isEmpty)
            reset(); type("\"a\"")
            check("a quote pairs, and the closing quote is skipped (\(view.string.debugDescription))", view.string == "\"a\"" && view.selectedRange().location == 3)
            reset(); type("don'")
            check("an apostrophe after a word is just a character (\(view.string.debugDescription))", view.string == "don'")
            reset(); type("ab"); view.setSelectedRange(NSRange(location: 0, length: 2)); type("(")
            check("an opener over a selection wraps it (\(view.string.debugDescription))", view.string == "(ab)" && view.selectedRange() == NSRange(location: 1, length: 2))
            let before = EditorPreferences.current
            selfTestCleanups.append { EditorPreferences.current = before }
            EditorPreferences.update { $0.autoClosePairs = false; $0.autoIndent = false }
            reset(); type("{")
            check("with the setting off a { stays alone", view.string == "{")
            EditorPreferences.current = before
            // Leave the folder as it was for the checks that follow: no open tab, no file.
            emptyController.closeTab(typingURL.path, force: true)
            try? FileManager.default.removeItem(at: typingURL)
            emptyController.reloadExplorer()
        }
        runFileOperationChecks(emptyController, root: emptyRoot, scratch: root.appendingPathComponent("gobi-scratch-trash"), check: check, addCleanup: { selfTestCleanups.append($0) })
        // Drag and drop in the explorer: a file dropped on a folder moves into it; never into itself or where it already is.
        if let source = emptyController.newEntry(.file, in: emptyRoot, name: "drop.txt"), let target = emptyController.newEntry(.folder, in: emptyRoot, name: "dropdst") {
            check("a file may be dropped on another folder", emptyController.explorerDropAllowed([source], onto: target))
            check("but not on the folder it is already in", !emptyController.explorerDropAllowed([source], onto: emptyRoot))
            check("and a folder may not be dropped on itself", !emptyController.explorerDropAllowed([target], onto: target))
            check("or on something outside the project", !emptyController.explorerDropAllowed([source], onto: root.deletingLastPathComponent()))
            check("a drop moves the file", emptyController.performExplorerDrop([source], onto: target) && FileManager.default.fileExists(atPath: target.appendingPathComponent("drop.txt").path) && !FileManager.default.fileExists(atPath: source.path))
        }

        // A double click on a folder opens it (and again closes it).
        if let folder = emptyController.newEntry(.folder, in: emptyRoot, name: "dblclick") {
            try? "package dblclick\n".write(to: folder.appendingPathComponent("x.go"), atomically: true, encoding: .utf8)
            emptyController.reloadExplorer()
            let row = emptyController.explorerRow(named: "dblclick") ?? -1
            emptyController.activateExplorerRow(row)
            check("a double click on a folder opens it (row \(row))", row >= 0 && emptyController.isExplorerRowExpanded(row))
            emptyController.activateExplorerRow(row)
            check("and a second one closes it again", row >= 0 && !emptyController.isExplorerRowExpanded(row))
        }
        emptyController.window?.close()
        check("and absent on a plain Go file", explorerMenu?.items.first { $0.title == "Go Mod Tidy" }?.isEnabled == false)

        // gopls.
        settle { controller.currentPane?.isConnected == true }
        check("gopls is connected", controller.currentPane?.isConnected == true)
        guard let pane = controller.currentPane else { print("SELFTEST FAILED"); exit(1) }
        let editorMenu = controller.editorMenu(for: pane)
        check("the editor menu enables Go to Definition, Find References, Rename, Code Actions, Format, Go to Implementation and the text commands", ["Go to Definition", "Find References", "Rename Symbol…", "Code Actions…", "Format Document", "Cut", "Copy", "Paste", "Select All", "Reveal in Finder", "Copy Path", "Go to Implementation"].allSatisfy { title in editorMenu.items.first { $0.title == title }?.isEnabled == true })

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
        check("revealing a caret near the left edge does not scroll sideways (the first character stays visible, offset \(declared?.textView.enclosingScrollView?.contentView.bounds.origin.x ?? -1))", declared?.textView.enclosingScrollView?.contentView.bounds.origin.x == 0)

        // Go to Implementation: from the interface method to the method of the type that implements it (shapes.go).
        controller.openFile(root.appendingPathComponent("shapes.go"))
        if let shapes = controller.currentPane {
            let interfaceMethod = (shapes.textView.string as NSString).range(of: "Speak()")
            shapes.textView.setSelectedRange(NSRange(location: interfaceMethod.location + 1, length: 0))
            settle(3) { false }
            controller.goToImplementation()
            settle { controller.currentCaretLine == 8 }
            check("Go to Implementation moves to the implementing method (line \(controller.currentCaretLine ?? -1))", controller.currentCaretLine == 8)
        }

        // Code lens: counts from gopls above declarations, and what a click does.
        controller.presentsLocationMenus = false
        selfTestCleanups.append { controller.presentsLocationMenus = true }
        func lensLine(_ pane: EditorPane, containing marker: String) -> Int {
            ((pane.textView.string.components(separatedBy: "\n").firstIndex { $0.contains(marker) }) ?? -2) + 1
        }
        controller.openFile(root.appendingPathComponent("a.go"))
        if let lensPane = controller.currentPane {
            let helperLine = lensLine(lensPane, containing: "func helper")
            lensPane.lens.refresh()
            settle { lensPane.editor.codeLenses[helperLine] != nil }
            check("the lens on helper says \"1 reference\" (\(lensPane.editor.codeLenses[helperLine]?.map(\.text) ?? []))", lensPane.editor.codeLenses[helperLine]?.map(\.text) == ["1 reference"])
            check("and main, which nothing calls, says 0 references", lensPane.editor.codeLenses[lensLine(lensPane, containing: "func main")]?.map(\.text) == ["0 references"])
            check("the lens leaves the text and its line count alone", !lensPane.textView.string.contains("reference") && lensPane.editorFile.lineIndex.lineCount == lensPane.textView.string.components(separatedBy: "\n").count)
            let requestsBefore = lensPane.lens.requestsSent
            lensPane.lens.refresh()
            settle(0.6) { false }
            check("a second refresh of the same text asks gopls for nothing (\(requestsBefore) requests so far)", lensPane.lens.requestsSent == requestsBefore)
            var hitAction: LensAction?
            for y in stride(from: 0.0, to: 120.0, by: 3.0) { for x in stride(from: 0.0, to: 900.0, by: 4.0) where hitAction == nil { hitAction = lensPane.editor.lensAction(at: NSPoint(x: x, y: y)) } }
            check("a point on the grey text of the lens hits \"references\" (\(String(describing: hitAction)))", hitAction == .references)
            controller.lastListedLocations = 0
            lensPane.editor.clickLens(line: helperLine, action: .references)
            settle { controller.lastListedLocations > 0 }
            check("clicking \"1 reference\" runs Find References (\(controller.lastListedLocations) places listed, caret line \(controller.currentCaretLine ?? -1))", controller.lastLensAction == .references && controller.lastListedLocations == 2 && controller.currentCaretLine == helperLine - 1)
            EditorPreferences.update { $0.showCodeLens = false }
            settle { lensPane.editor.codeLenses.isEmpty }
            check("turning Show code lens off removes the lenses", lensPane.editor.codeLenses.isEmpty)
            EditorPreferences.update { $0.showCodeLens = true }
            settle { lensPane.editor.codeLenses[helperLine] != nil }
            check("and on brings them back", lensPane.editor.codeLenses[helperLine] != nil)
        }
        controller.openFile(root.appendingPathComponent("shapes.go"))
        if let shapesPane = controller.currentPane {
            let speakLine = lensLine(shapesPane, containing: "Speak() string")
            shapesPane.lens.refresh()
            settle { (shapesPane.editor.codeLenses[speakLine]?.count ?? 0) == 2 }
            check("the lens on the interface method names its implementation (\(shapesPane.editor.codeLenses[speakLine]?.map(\.text) ?? []))", shapesPane.editor.codeLenses[speakLine]?.last?.text == "1 implementation")
            controller.lastListedLocations = 0
            shapesPane.editor.clickLens(line: speakLine, action: .implementations)
            settle { controller.lastLensAction == .implementations && controller.currentCaretLine == 8 }
            check("clicking it runs Go to Implementation", controller.lastLensAction == .implementations && controller.currentCaretLine == 8)
        }

        // Settings window and the save options.
        let settings = SettingsWindowController()
        settings.select(pane: 2)
        check("the Settings window opens on Languages when asked and back on Editor", settings.selectedPane == 2 && { settings.select(pane: 1); return settings.selectedPane == 1 }())
        let savedTrim = WindowSettings.trimTrailingWhitespace, savedNewline = WindowSettings.finalNewline
        selfTestCleanups.append { WindowSettings.trimTrailingWhitespace = savedTrim; WindowSettings.finalNewline = savedNewline }
        settings.trimWhitespace.state = .off
        settings.trimWhitespace.sendAction(settings.trimWhitespace.action, to: settings.trimWhitespace.target)
        check("a Settings checkbox changes the stored option", WindowSettings.trimTrailingWhitespace == false)
        WindowSettings.trimTrailingWhitespace = true
        WindowSettings.finalNewline = true
        controller.openFile(root.appendingPathComponent("e.go"))
        if let pane = controller.currentPane {
            let original = pane.textView.string
            pane.textView.insertText("   \n\n\n", replacementRange: NSRange(location: (original as NSString).length, length: 0))
            _ = controller.saveCurrent()
            let onDisk = (try? String(contentsOf: root.appendingPathComponent("e.go"), encoding: .utf8)) ?? ""
            check("saving trims trailing whitespace and ends with one newline", onDisk.hasSuffix("\n") && !onDisk.hasSuffix("\n\n") && !onDisk.contains("   \n"))
            try? original.write(to: root.appendingPathComponent("e.go"), atomically: true, encoding: .utf8)
            pane.checkDisk()   // the pane has no unsaved edits, so it takes the restored text quietly
        }

        // Go Toolchains window.
        let toolchains = ToolchainsWindowController()
        toolchains.reload(projectRoot: root)
        settle(10) { !toolchains.installs.isEmpty }
        check("the Toolchains window lists the installed Go (\(toolchains.installs.map(\.version)))", !toolchains.installs.isEmpty)
        check("and shows what go.mod asks for (\(toolchains.noteText))", toolchains.noteText.hasPrefix("go.mod: go ") || toolchains.noteText == "No go.mod")
        toolchains.show(update: GoUpdate(installed: "1.26.5", available: "1.26.6"))
        check("an update notice names the newer release", toolchains.updateText.hasPrefix("go1.26.6 is available"))
        toolchains.show(update: nil)
        check("and says so when Go is up to date", toolchains.updateText == "Go is up to date.")
        let sheet = InstallVersionSheet(installed: toolchains.installs)
        sheet.show(available: ["99.0.1", "1.25.10", toolchains.installs.first?.version ?? "1.0"])
        check("the Install Version sheet marks the latest, the available and the installed (\(sheet.rows.map(\.state)))", sheet.rows.map(\.state) == [.latest, .available, .installed] || sheet.rows.map(\.state) == [.latest, .installed, .installed])

        // Editor options.
        EditorPreferences.update { $0.showLineNumbers = false; $0.rulerColumn = 80; $0.autoSave = .afterDelay }
        check("turning line numbers off hides the gutter and the ruler setting reaches the editor", controller.currentPane?.editor.isLineNumbersVisible == false && controller.currentPane?.editor.rulerColumn == 80)
        EditorPreferences.update { $0.fontSize = 16; $0.indentWithTabs = false; $0.tabWidth = 2 }
        check("font size and indent reach the editor (\(controller.currentPane?.editor.fontPointSize ?? 0) pt)", controller.currentPane?.editor.fontPointSize == 16 && controller.currentPane?.editor.indentUnit == "\t")
        EditorPreferences.update { $0.wrapLines = true }
        let wrapped = controller.currentPane?.editor.textViewWidth ?? 0
        EditorPreferences.update { $0.wrapLines = false }
        let unwrapped = controller.currentPane?.editor.textViewWidth ?? 0
        check("Wrap long lines fits the text to the window and off restores the wide container (\(Int(wrapped)) and \(Int(unwrapped)) pt)", wrapped > 0 && wrapped < unwrapped)
        EditorPreferences.update { $0.showLineNumbers = true; $0.rulerColumn = 0 }
        check("and back on", controller.currentPane?.editor.isLineNumbersVisible == true && controller.currentPane?.editor.rulerColumn == 0)
        controller.openFile(root.appendingPathComponent("e.go"))
        if let pane = controller.currentPane {
            let original = pane.textView.string
            pane.textView.insertText("// auto\n", replacementRange: NSRange(location: (original as NSString).length, length: 0))
            check("an edit leaves the file unsaved", controller.isDirty(root.appendingPathComponent("e.go")))
            settle(5) { !controller.isDirty(root.appendingPathComponent("e.go")) }
            let onDisk = (try? String(contentsOf: root.appendingPathComponent("e.go"), encoding: .utf8)) ?? ""
            check("auto save after a delay writes it", !controller.isDirty(root.appendingPathComponent("e.go")) && onDisk.contains("// auto"))
            try? original.write(to: root.appendingPathComponent("e.go"), atomically: true, encoding: .utf8)
        }
        EditorPreferences.update { $0.autoSave = .off }

        // Git marks: the self-test folder is a plain folder, so make it a repository with one edited and one new file.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            settle(10) { controller.gitStatus != nil }
            let marks = (0 ..< controller.explorerRowCount).reduce(into: [String: GitMark]()) { result, row in
                if let mark = controller.gitMark(ofRow: row), let title = controller.explorerRowTitle(row) { result[title] = mark }
            }
            check("the explorer rows carry git marks (\(marks); status \(String(describing: controller.gitStatus)); rows \(controller.explorerRowCount))", !marks.isEmpty)
        }
        // Inspector and sidebar tabs.
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.refreshOutline()
        settle(15) { controller.outlineTitles.contains { $0.hasSuffix("helper") } }
        check("the inspector outline lists the file's symbols (\(controller.outlineTitles))", controller.outlineTitles.contains { $0.hasSuffix("helper") })
        controller.selectSidebarTab(1)
        check("the Symbols tab shows the same list", controller.sidebarTabIndex == 1 && controller.sidebarSymbolTitles == controller.outlineTitles)
        controller.selectSidebarTab(2)
        check("the Tests tab can be selected", controller.sidebarTabIndex == 2)
        controller.selectSidebarTab(0)
        let wasVisible = controller.isInspectorVisible
        controller.toggleInspector()
        check("Toggle Inspector hides and shows the inspector", controller.isInspectorVisible != wasVisible)
        controller.toggleInspector()
        check("the toolbar names the run target (\(controller.toolbarTargetText))", controller.toolbarTargetText.hasPrefix("go run"))
        settle(10) { controller.toolbarStatusText.contains("Go ") && controller.toolbarStatusText.contains("gopls ready") }
        check("the toolbar status shows gopls, Go and platform (\(controller.toolbarStatusText))", controller.toolbarStatusText.hasPrefix("gopls ready · Go ") && controller.toolbarStatusText.contains("darwin/"))
        check("Run shows as Run when idle", controller.toolbarRunTitle == "Run")

        controller.openFile(root.appendingPathComponent("c.go"))
        settle { controller.currentPane?.isConnected == true }
        let before = controller.currentPane?.textView.string ?? ""
        controller.formatDocument()
        settle { controller.currentPane?.textView.string != before }
        let after = controller.currentPane?.textView.string ?? ""
        check("Format Document rewrites badly formatted code (gofmt)", after != before && after.contains("func main() {"))
        controller.currentPane?.textView.undoManager?.undo()
        check("and it is one undo step", controller.currentPane?.textView.string == before)
        let saveBefore = (try? String(contentsOf: root.appendingPathComponent("c.go"), encoding: .utf8)) ?? ""
        _ = controller.saveCurrent()
        settle(10) { ((try? String(contentsOf: root.appendingPathComponent("c.go"), encoding: .utf8)) ?? "") != saveBefore }
        let saved = (try? String(contentsOf: root.appendingPathComponent("c.go"), encoding: .utf8)) ?? ""
        check("Format on save leaves the file gofmt-formatted on disk", saved != saveBefore && saved.contains("func main() {"))
        try? saveBefore.write(to: root.appendingPathComponent("c.go"), atomically: true, encoding: .utf8)
        // Completion: needs d.go with `fmt.` on its own line inside a function.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("d.go").path) {
            controller.openFile(root.appendingPathComponent("d.go"))
            settle { controller.currentPane?.isConnected == true }
            settle(4) { false }
            if let pane = controller.currentPane, let completion = pane.editor.completion {
                let source = pane.textView.string as NSString
                let dot = source.range(of: "fmt.")
                pane.textView.setSelectedRange(NSRange(location: dot.location + dot.length, length: 0))
                completion.trigger()
                settle(20) { completion.isOpen }
                check("Ctrl-Space opens completions after a dot (\(completion.visibleLabels.count) items)", completion.isOpen && completion.visibleLabels.contains("Println"))
                for letter in ["P", "r", "i"] { pane.textView.insertText(letter, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                check("typing narrows the list to what starts with Pri (\(completion.visibleLabels.prefix(3)))", completion.isOpen && completion.visibleLabels.first?.hasPrefix("Pri") == true)
                let chosen = completion.selectedLabel ?? ""
                completion.accept()
                check("accepting puts the choice in after the dot (\(chosen))", (pane.textView.string as NSString).contains("fmt." + chosen) && !completion.isOpen)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // closes the undo group, so the next undo takes back only the reverse
                pane.textView.undoManager?.undo()
                completion.trigger()
                settle(20) { completion.isOpen }
                completion.dismiss()
                check("Escape closes the list", !completion.isOpen)
                // Snippets: a real function completes with its parentheses and the caret inside them.
                let beforeSnippet = pane.textView.string
                let textLength = (beforeSnippet as NSString).length
                let afterDot = (beforeSnippet as NSString).range(of: "fmt.").upperBound
                pane.textView.setSelectedRange(NSRange(location: afterDot, length: 0))
                completion.trigger()
                settle(20) { completion.isOpen }
                pane.textView.insertText("Println", replacementRange: NSRange(location: NSNotFound, length: 0))
                completion.accept()
                let afterAccept = pane.textView.string as NSString, caretAt = pane.textView.selectedRange().location
                check("accepting a function inserts its call with the caret inside the parentheses", afterAccept.contains("fmt.Println(") && caretAt > 0 && afterAccept.substring(with: NSRange(location: caretAt - 1, length: 1)) == "(")
                // Tab stops, with a provider that answers one snippet with two placeholders.
                let realProvider = completion.provider
                completion.provider = { _, done in done([CompletionItem(label: "pair", kind: .function, detail: "", insertText: "pair(${1:left}, ${2:right})$0", replaces: nil, sortText: "0", isSnippet: true)]) }
                pane.textView.insertText("\n\tp", replacementRange: NSRange(location: NSNotFound, length: 0))
                completion.trigger()
                settle(5) { completion.isOpen }
                completion.accept()
                let snippets = pane.editor.snippets
                var selected: String { let range = pane.textView.selectedRange(); return (pane.textView.string as NSString).substring(with: range) }
                check("a snippet inserts its text and selects the first placeholder (\(selected))", (pane.textView.string as NSString).contains("pair(left, right)") && selected == "left" && snippets?.isActive == true)
                pane.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                completion.dismiss()  // typing a letter opens the list again; Tab would accept it
                pane.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
                check("Tab moves to the next placeholder after typing in the first (\(selected))", selected == "right" && (pane.textView.string as NSString).contains("pair(a, right)"))
                pane.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
                let finalCaret = pane.textView.selectedRange()
                check("Tab again leaves the snippet with the caret after it", snippets?.isActive == false && finalCaret.length == 0 && (pane.textView.string as NSString).substring(to: finalCaret.location).hasSuffix("pair(a, right)"))
                completion.provider = realProvider
                // Signature help.
                var signatureOpen: Bool { pane.editor.signature?.isOpen == true }
                if let signature = pane.editor.signature {
                    pane.textView.insertText("\nfmt.Sprintf", replacementRange: NSRange(location: NSNotFound, length: 0))
                    completion.dismiss()
                    pane.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
                    settle(20) { signatureOpen }
                    check("typing ( in a call shows the signature with the first parameter bold (\(signature.currentText?.label ?? "nothing"))", signature.currentText?.label.contains("Sprintf") == true && signature.currentText?.parts.active.hasPrefix("format") == true)
                    pane.textView.insertText("\"a\"", replacementRange: NSRange(location: NSNotFound, length: 0))
                    pane.textView.insertText(",", replacementRange: NSRange(location: NSNotFound, length: 0))
                    settle(20) { signature.currentText?.parts.active.hasPrefix("a") == true }
                    check("typing , moves the bold to the next parameter (\(signature.currentText?.parts.active ?? "nothing"))", signature.currentText?.parts.active.hasPrefix("a") == true)
                    pane.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                    check("Escape closes the signature", !signatureOpen)
                    signature.trigger()
                    settle(20) { signatureOpen }
                    check("Parameter Info asks on demand", signatureOpen)
                    pane.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
                    check("typing ) closes the signature", !signatureOpen)
                } else {
                    check("d.go has a signature controller", false)
                }
                pane.textView.insertText(beforeSnippet, replacementRange: NSRange(location: 0, length: (pane.textView.string as NSString).length))
                completion.dismiss()
                check("the document is back to its text (\(textLength) units)", pane.textView.string == beforeSnippet)
                // Signature of a function from another file (b.go calls helper from a.go).
                controller.openFile(root.appendingPathComponent("b.go"))
                settle { controller.currentPane?.isConnected == true }
                settle(3) { false }
                if let other = controller.currentPane, let signature = other.editor.signature {
                    let call = (other.textView.string as NSString).range(of: "helper(")
                    other.textView.setSelectedRange(NSRange(location: call.upperBound, length: 0))
                    signature.trigger()
                    settle(20) { signature.isOpen }
                    check("Parameter Info on helper( shows its signature (\(signature.currentText?.label ?? "nothing"))", signature.currentText?.label.contains("helper") == true)
                    signature.dismiss()
                }
                controller.openFile(root.appendingPathComponent("d.go"))
            } else {
                check("d.go has a completion controller", false)
            }
        }
        // Hover on a call of a function with documentation.
        controller.openFile(root.appendingPathComponent("b.go"))
        settle { controller.currentPane?.isConnected == true }
        settle(3) { false }
        if let pane = controller.currentPane, let hover = pane.editor.hover {
            let source = pane.textView.string as NSString
            hover.ask(at: source.range(of: "helper").location + 2)
            settle(20) { hover.currentText != nil }
            check("hover on a function shows its signature (\(hover.currentText?.prefix(40) ?? "nothing"))", hover.currentText?.contains("helper") == true)
            hover.hide()
            check("and closes", hover.currentText == nil)
        }
        // Quick open: files, commands, symbols.
        controller.goToFile()
        controller.quickOpenType("b.go")
        settle(5) { controller.quickOpenTitles.first == "b.go" }
        check("Go to File finds a file by name (\(controller.quickOpenTitles.prefix(3)))", controller.quickOpenTitles.first == "b.go")
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.quickOpenChoose()
        check("choosing it opens the file", controller.currentPane?.editorFile.fileURL.lastPathComponent == "b.go")
        controller.commandPalette { _ in }
        controller.quickOpenType("format")
        settle(5) { controller.quickOpenTitles.first == "Format Document" }
        check("the Command Palette finds a command (\(controller.quickOpenTitles.prefix(3)))", controller.quickOpenTitles.first == "Format Document")
        controller.quickOpenChoose()
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.goToFileSymbol()
        settle(20) { controller.isQuickOpenVisible }
        controller.quickOpenType("help")
        settle(5) { controller.quickOpenTitles.contains("helper") }
        check("Go to Symbol in File lists the file's symbols (\(controller.quickOpenTitles.prefix(3)))", controller.quickOpenTitles.contains("helper"))
        controller.quickOpenChoose()
        controller.goToWorkspaceSymbol()
        settle(5) { controller.isQuickOpenVisible }
        controller.quickOpenType("helper")
        settle(20) { controller.quickOpenTitles.contains("helper") }
        check("Go to Symbol in Workspace searches the project (\(controller.quickOpenTitles.prefix(3)))", controller.quickOpenTitles.contains("helper"))
        controller.quickOpenChoose()
        // References, rename and organize imports.
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.openFile(root.appendingPathComponent("b.go"))
        settle { controller.currentPane?.isConnected == true }
        controller.openFile(root.appendingPathComponent("a.go"))
        settle(4) { false }
        if let declaring = controller.currentPane {
            let source = declaring.textView.string as NSString
            declaring.textView.setSelectedRange(NSRange(location: source.range(of: "helper").location + 2, length: 0))
            var references: [SourceLocation] = []
            var answered = false
            declaring.editorFile.client?.references(uri: declaring.editorFile.uri, at: declaring.editorFile.lineIndex.position(at: declaring.textView.selectedRange().location)) { found in references = found; answered = true }
            settle(30) { answered }
            check("Find References lists the declaration and the use (\(references.map { URL(string: $0.uri)?.lastPathComponent ?? "?" }))", references.count >= 2 && references.contains { $0.uri.hasSuffix("b.go") })
            controller.performRename(from: "helper", to: "helperRenamed")
            settle(30) { (controller.paneIfOpen(root.appendingPathComponent("b.go"))?.textView.string ?? "").contains("helperRenamed") }
            check("Rename changes the declaration and the use in both open files", declaring.textView.string.contains("func helperRenamed") && (controller.paneIfOpen(root.appendingPathComponent("b.go"))?.textView.string ?? "").contains("helperRenamed()"))
            declaring.textView.undoManager?.undo()
            controller.paneIfOpen(root.appendingPathComponent("b.go"))?.textView.undoManager?.undo()
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("e.go").path) {
            controller.openFile(root.appendingPathComponent("e.go"))
            settle { controller.currentPane?.isConnected == true }
            settle(4) { false }
            controller.organizeImports()
            settle(30) { !(controller.currentPane?.textView.string.contains("\"os\"") ?? true) }
            check("Organize Imports removes the unused import", !(controller.currentPane?.textView.string.contains("\"os\"") ?? true) && (controller.currentPane?.textView.string.contains("\"fmt\"") ?? false))
        }
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-lang`: the built-in JSON and Markdown services. The folder needs bad.json (a trailing comma),
    /// ugly.json (valid but unformatted) and notes.md (headings Title, Section A, Deep, Section B).
    private func runLanguageSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-lang"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 20, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let controller = ProjectWindowController(root: root, kind: .folder, isTrusted: true)
        controller.showWindow(nil)

        controller.openFile(root.appendingPathComponent("bad.json"))
        settle { controller.currentPane?.isConnected == true }
        settle { controller.problemCount > 0 }
        check("a JSON syntax error is reported as a problem (\(controller.problemCount))", controller.problemCount > 0)
        controller.openFile(root.appendingPathComponent("ugly.json"))
        settle { controller.currentPane?.isConnected == true }
        settle(3) { controller.problemCount != 1 }
        check("a valid JSON file adds no problem (the panel still lists only bad.json's)", controller.problemCount == 1)
        let before = controller.currentPane?.textView.string ?? ""
        controller.formatDocument()
        settle { controller.currentPane?.textView.string != before }
        let after = controller.currentPane?.textView.string ?? ""
        check("Format Document pretty-prints JSON", after != before && after.contains("\n"))
        controller.refreshOutline()
        settle { !controller.outlineTitles.isEmpty }
        check("the outline of a JSON file lists its keys (\(controller.outlineTitles))", controller.outlineTitles.contains { $0.hasSuffix("a") || $0 == "a" })

        controller.openFile(root.appendingPathComponent("notes.md"))
        settle { controller.currentPane?.isConnected == true }
        controller.refreshOutline()
        settle { controller.outlineTitles.contains { $0.hasSuffix("Section B") } }
        check("the outline of a Markdown file lists its headings (\(controller.outlineTitles))", ["Title", "Section A", "Deep", "Section B"].allSatisfy { name in controller.outlineTitles.contains { $0.hasSuffix(name) } })

        // JSON and Markdown in the window: status bar, Explorer marker, inspector, preview, settings.
        controller.openFile(root.appendingPathComponent("bad.json"))
        settle { controller.currentPane?.isConnected == true }
        settle { controller.statusBarTexts.contains("JSON · 1 problem") }
        check("the status bar names the JSON service and its problems (\(controller.statusBarTexts.filter { !$0.isEmpty }))", controller.statusBarTexts.contains("JSON · built-in language service") && controller.statusBarTexts.contains("JSON · 1 problem"))
        check("the Explorer marks the file that has an error", controller.explorerErrorFiles.contains(root.appendingPathComponent("bad.json").path))
        controller.refreshOutline()
        settle { controller.inspectorFileSummary.first == "JSON" }
        check("This file shows the language, the indent and format on save (\(controller.inspectorFileSummary))", controller.inspectorFileSummary == ["JSON", "Indent 2 spaces", "format on"])
        let savedSwitches = (WindowSettings.reportJSONErrors, WindowSettings.formatJSONOnSave, WindowSettings.markdownPreviewMode)
        selfTestCleanups.append { WindowSettings.reportJSONErrors = savedSwitches.0; WindowSettings.formatJSONOnSave = savedSwitches.1; WindowSettings.markdownPreviewMode = savedSwitches.2 }
        WindowSettings.reportJSONErrors = false
        controller.currentPane?.editorFile.onTextChanged?()
        controller.openFile(root.appendingPathComponent("ugly.json"))
        controller.openFile(root.appendingPathComponent("bad.json"))
        WindowSettings.reportJSONErrors = true

        // Format on save for JSON.
        let uglyURL = root.appendingPathComponent("ugly.json")
        let uglyOriginal = (try? String(contentsOf: uglyURL, encoding: .utf8)) ?? ""
        selfTestCleanups.append { try? uglyOriginal.write(to: uglyURL, atomically: true, encoding: .utf8) }
        controller.openFile(uglyURL)
        settle { controller.currentPane?.isConnected == true }
        WindowSettings.formatJSONOnSave = true
        let saved = controller.saveCurrent()
        _ = saved
        settle { ((try? String(contentsOf: uglyURL, encoding: .utf8)) ?? "").contains("\n  \"") }
        let onDisk = (try? String(contentsOf: uglyURL, encoding: .utf8)) ?? ""
        check("Format on save pretty-prints a JSON file on disk (\(onDisk.debugDescription.prefix(60)))", onDisk.contains("\n  \""))
        try? uglyOriginal.write(to: uglyURL, atomically: true, encoding: .utf8)

        // Markdown preview.
        WindowSettings.markdownPreviewMode = .split
        controller.openFile(root.appendingPathComponent("notes.md"))
        settle { controller.currentPane?.isConnected == true }
        let host = controller.currentPane?.markdownHost
        check("a Markdown file opens with the Source | Split | Preview switch in Split mode", host != nil && host?.mode == .split)
        controller.currentPane?.refreshPreview()
        var previewText = ""
        settle(20) {
            host?.preview.text { previewText = $0 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            return previewText.contains("Section A")
        }
        check("the preview shows the rendered headings (\(previewText.replacingOccurrences(of: "\n", with: " | ").prefix(60)))", previewText.contains("Title") && previewText.contains("Section A") && previewText.contains("Deep"))
        host?.apply(.source)
        check("Source hides the preview and Preview hides the editor", host?.preview.isHidden == true) 
        host?.apply(.preview)
        check("Preview mode shows only the preview", host?.preview.isHidden == false)
        controller.refreshOutline()
        settle { controller.inspectorFileSummary.first == "Markdown" }
        check("This file shows the headings and the preview mode (\(controller.inspectorFileSummary))", controller.inspectorFileSummary.first == "Markdown" && controller.inspectorFileSummary[1] == "Headings 4")
        let languages = SettingsWindowController()
        languages.select(pane: 2)
        languages.showLanguage(1)
        check("Settings > Languages has JSON and Markdown (\(languages.shownLanguage))", languages.shownLanguage == "JSON")
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-toolchain`: pins another installed Go and checks that Run uses it. The folder needs a main.go that
    /// prints runtime.Version(); at least two Go versions must be installed (system plus one under ~/sdk).
    private func runToolchainSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-toolchain"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 60, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let original = UserDefaults.standard.string(forKey: "gobi.toolchain." + root.path)
        selfTestCleanups.append { if let original { UserDefaults.standard.set(original, forKey: "gobi.toolchain." + root.path) } else { UserDefaults.standard.removeObject(forKey: "gobi.toolchain." + root.path) } }
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("main.go"))
        settle(15) { controller.goInstalls.count >= 2 }
        check("two or more Go versions are installed (\(controller.goInstalls.map(\.version)))", controller.goInstalls.count >= 2)
        guard controller.goInstalls.count >= 2 else { print("SELFTEST FAILED"); exit(1) }
        let other = controller.goInstalls.last!
        controller.selectToolchain(version: other.version)
        check("the toolbar names the pinned version (\(controller.toolbarToolchainText))", controller.toolbarToolchainText.hasPrefix("Go " + other.version))
        check("the menu checks it", controller.toolchainMenu().items.first { $0.state == .on }?.title == "go" + other.version)
        controller.runProject()
        settle { !controller.isRunning && controller.runOutputText.contains("go1.") }
        check("Run used the pinned Go (\(controller.runOutputText.split(separator: "\n").first(where: { $0.hasPrefix("go1") }) ?? ""))", controller.runOutputText.contains("go" + other.version))
        controller.selectToolchain(version: nil)
        check("Auto goes back to following go.mod", controller.toolchainSelection.mode == .auto)

        // Run on multiple versions: vet and test once per Go version, one after the other.
        let multi = MultiVersionWindowController(project: controller)
        check("the multi-version window offers one version per minor (\(multi.checkedVersions))", multi.checkedVersions.count >= 2)
        multi.run(versions: controller.goInstalls)
        settle(120) { !multi.isRunning && multi.rows.count == controller.goInstalls.count }
        check("every version finished vet and test (\(multi.rows.map { "go\($0.version): \($0.vetText) / \($0.testText)" }))", multi.rows.count == controller.goInstalls.count && multi.rows.allSatisfy { $0.vetText == "Passed" && $0.testText.hasPrefix("Passed") })

        // The last result is kept per project and shown again; Clear removes it.
        let savedKey = MultiVersionWindowController.defaultsKey(root: root.path)
        let savedLast = UserDefaults.standard.string(forKey: savedKey)
        selfTestCleanups.append { if let savedLast { UserDefaults.standard.set(savedLast, forKey: savedKey) } else { UserDefaults.standard.removeObject(forKey: savedKey) } }
        let stored = UserDefaults.standard.string(forKey: savedKey).flatMap(MultiVersionSnapshot.decode)
        check("the finished run was saved for the project (\(stored?.rows.count ?? 0) rows)", stored?.rows == multi.rows)
        let reopened = MultiVersionWindowController(project: controller, now: { (stored?.finishedAt ?? 0) + 300 })
        check("reopening shows the saved results (\(reopened.rows.count) rows) and when they ran (\(reopened.lastRunText))", reopened.rows == multi.rows && reopened.lastRunText == "last run: 5 min ago")
        reopened.clearPressed()
        check("Clear empties the table, the text and the saved result", reopened.rows.isEmpty && reopened.lastRunText.isEmpty && UserDefaults.standard.string(forKey: savedKey) == nil)
        check("and a window opened afterwards starts empty", MultiVersionWindowController(project: controller).rows.isEmpty)

        // The Install Version sheet attaches to the Toolchains window and Cancel closes it.
        let toolchains = ToolchainsWindowController()
        toolchains.showWindow(nil)
        toolchains.installVersion()
        check("Install version opens as a sheet on the Toolchains window", toolchains.window?.attachedSheet != nil && toolchains.installSheet?.isSheetOpen == true)
        toolchains.installSheet?.finish()
        settle(5) { toolchains.window?.attachedSheet == nil }
        check("and Cancel closes it", toolchains.window?.attachedSheet == nil)
        toolchains.close()

        // gopls follows the choice: a module that needs a newer Go than the pinned one gets a problem, and loses it again on Auto.
        if let newerIndex = CommandLine.arguments.firstIndex(of: "--newer"), newerIndex + 1 < CommandLine.arguments.count {
            let newer = URL(fileURLWithPath: CommandLine.arguments[newerIndex + 1])
            let key = "gobi.toolchain." + newer.path
            defer { UserDefaults.standard.removeObject(forKey: key) }
            let second = ProjectWindowController(root: newer, kind: .module, isTrusted: true)
            second.showWindow(nil)
            second.openFile(newer.appendingPathComponent("main.go"))
            settle(20) { second.goInstalls.count >= 2 && second.currentPane?.isConnected == true }
            settle(10) { second.problemCount == 0 }
            check("with Auto (the newer Go) the module that needs it has no problems (\(second.problemCount))", second.problemCount == 0)
            second.selectToolchain(version: other.version)
            settle(30) { second.problemCount > 0 }
            check("pinning an older Go restarts gopls and it reports the module needs a newer Go (\(second.problemCount))", second.problemCount > 0)
            second.selectToolchain(version: nil)
            settle(30) { second.problemCount == 0 }
            check("going back to Auto clears it (\(second.problemCount))", second.problemCount == 0)
        }
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-debug`: a real Delve session on a program whose main.go has `sum := a + b` on line 6 (inside
    /// add) and prints "total 42". Needs dlv installed.
    private func runDebugSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-debug"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 90, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let file = root.appendingPathComponent("main.go").path
        let session = DebugSession(root: root)
        var marks = Breakpoints()
        marks.toggle(path: file, line: 8)
        session.breakpoints = { marks }
        session.start(programDir: root.path)
        settle { if case .stopped = session.state { return true } else if case .ended = session.state { return true } else { return false } }
        check("the program stops at the breakpoint (\(session.state))", { if case .stopped = session.state { return true } else { return false } }())
        check("the top frame is add on line 8 (\(session.frames.first.map { "\($0.title) \($0.location)" } ?? "none"))", session.frames.first?.title == "main.add" && session.frames.first?.line == 8)
        check("the call stack includes main.main", session.frames.contains { $0.title == "main.main" })
        settle(10) { session.variables.contains { $0.name == "a" } }
        check("the locals show the arguments (\(session.variables.map { "\($0.name)=\($0.value)" }))", session.variables.contains { $0.name == "a" && $0.value == "20" } && session.variables.contains { $0.name == "b" && $0.value == "22" })
        session.select(frame: session.frames.firstIndex { $0.title == "main.main" } ?? 0)
        settle(10) { session.variables.contains { $0.name == "x" } }
        check("selecting main.main shows its variables (\(session.variables.map(\.name)))", session.variables.contains { $0.name == "x" })
        session.select(frame: 0)
        session.stepOver()
        settle(30) { if case .stopped(let reason, _) = session.state { return reason == "step" } else { return false } }
        check("Step Over moves to line 9 (\(session.frames.first?.location ?? "none"))", session.frames.first?.line == 9)
        session.resume()
        settle { if case .ended = session.state { return true } else { return false } }
        check("Continue runs to the end (\(session.state))", session.state == .ended("exit 0"))
        settle(5) { session.output.contains("total 42") }
        check("the program's output reached the console", session.output.contains("total 42"))

        // A condition that is false never stops; a true one does. Locals with parts can be opened. Watches and goroutines work.
        var never = Breakpoints()
        never.setCondition("a == 99", path: file, line: 8)
        let skipping = DebugSession(root: root)
        skipping.breakpoints = { never }
        skipping.start(programDir: root.path)
        settle { if case .ended = skipping.state { return true } else { return false } }
        check("a false condition does not stop the program (\(skipping.state))", skipping.state == .ended("exit 0"))
        var cond = Breakpoints()
        cond.setCondition("a == 20", path: file, line: 8)
        cond.toggle(path: file, line: 16)
        let conditional = DebugSession(root: root)
        conditional.breakpoints = { cond }
        conditional.watches.add("x + y")
        conditional.watches.add("nope(")
        conditional.start(programDir: root.path)
        settle { conditional.state.canStep }
        check("the first stop is main.main on line 16 (\(conditional.frames.first?.location ?? "none"))", conditional.frames.first?.title == "main.main" && conditional.frames.first?.line == 16)
        settle(10) { conditional.variables.contains { $0.name == "p" } }
        let point = conditional.variables.first { $0.name == "p" }
        check("a struct local has parts to open (\(point.map { "\($0.value) ref \($0.reference)" } ?? "none"))", (point?.reference ?? 0) > 0)
        var parts: [DebugVariable] = []
        conditional.children(of: point?.reference ?? 0) { parts = $0 }
        settle(10) { !parts.isEmpty }
        check("opening it shows X and Y (\(parts.map { "\($0.name)=\($0.value)" }))", parts.map(\.name) == ["X", "Y"] && parts.map(\.value) == ["20", "22"])
        conditional.evaluateWatches()
        settle(10) { conditional.watchResults["x + y"] != nil && conditional.watchResults["nope("] != nil }
        check("a watch is evaluated and a bad one reports an error (\(conditional.watchResults))", conditional.watchResults["x + y"] == "42" && conditional.watchResults["nope("]?.hasPrefix("error") == true)
        check("the goroutine list names main.main (\(conditional.threads.map(\.title)))", conditional.threads.contains { $0.title == "main.main" })
        conditional.resume()
        settle { conditional.state.canStep && conditional.frames.first?.title == "main.add" }
        check("a true condition then stops inside add (\(conditional.frames.first?.location ?? "none"))", conditional.frames.first?.title == "main.add" && conditional.frames.first?.line == 8)
        conditional.stop()
        settle { if case .ended = conditional.state { return true } else { return false } }

        // The same through the project window: gutter breakpoint, Debug panel, highlighted line.
        let key = "gobi.breakpoints." + root.path
        let savedMarks = UserDefaults.standard.string(forKey: key)
        selfTestCleanups.append { if let savedMarks { UserDefaults.standard.set(savedMarks, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("main.go"))
        controller.toggleBreakpoint(path: file, line: 8)
        check("a breakpoint shows as a dot in the editor and is kept", controller.currentPane?.editor.breakpointLines == [8] && controller.breakpoints.lines(in: file) == [8])
        controller.startDebugging()
        settle { controller.debugState.canStep }
        check("the Debug panel lists the stack and the locals (\(controller.debugFrameTitles.first ?? "none"))", controller.debugFrameTitles.first?.hasPrefix("main.add") == true)
        settle(10) { controller.debugVariableNames.contains("a") }
        check("and the variables (\(controller.debugVariableNames))", controller.debugVariableNames.contains("a"))
        if let snapshotPath { RunLoop.current.run(until: Date().addingTimeInterval(0.5)); WindowSnapshot.write(controller.window, to: snapshotPath) }
        check("the paused line is highlighted in the editor (\(controller.currentPane?.editor.debugLine ?? 0))", controller.currentPane?.editor.debugLine == 8)
        check("Step Over and Continue are enabled while paused, and the status says where (\(controller.debugStatusText))", controller.debugEnabledActions.isSuperset(of: ["over", "into", "out", "continue", "stop"]) && controller.debugStatusText.hasPrefix("Paused at breakpoint"))
        check("Run > Stop and Evaluate Expression are enabled while paused", MenuAvailability.isEnabled("stop", in: controller.menuContext) == true && MenuAvailability.isEnabled("evaluateExpression", in: controller.menuContext) == true)
        controller.viewBreakpoints()
        check("View Breakpoints opens the Debug tab and the navigator (\(controller.selectedPanelTab))", controller.selectedPanelTab == 3 && controller.sidebarTabIndex == 3)
        check("the navigator lists the stack, the goroutines and the breakpoint (\(controller.debugFrameTitles.count) frames, \(controller.debugGoroutinesHeader), \(controller.debugNavigatorBreakpoints.count) breakpoint)", controller.debugFrameTitles.first?.hasPrefix("main.add") == true && controller.debugGoroutinesHeader.hasPrefix("GOROUTINES (") && controller.debugNavigatorBreakpoints.map(\.line) == [8])
        check("the paused line shows its values inline (\(controller.currentPane?.editor.inlineValues ?? [:]))", controller.currentPane?.editor.inlineValues[8]?.contains("a = 20") == true)
        controller.addWatch("a * b")
        settle(10) { controller.debugWatchRows.first?.value == "440" }
        check("a watch added in the panel is evaluated (\(controller.debugWatchRows))", controller.debugWatchRows.first?.value == "440")
        controller.removeWatch(at: 0)
        check("and can be removed", controller.debugWatchRows.isEmpty && controller.watches.expressions.isEmpty)
        controller.setCondition("a == 20", path: file, line: 8)
        check("a condition turns the dot orange and shows in the list", controller.currentPane?.editor.conditionalBreakpointLines == [8] && controller.debugNavigatorBreakpoints.first?.condition == "a == 20")
        controller.debugAction("continue")
        settle { if case .ended = controller.debugState { return true } else { return false } }
        check("the session ends and the highlight goes away (\(controller.debugState))", controller.debugState == .ended("exit 0") && controller.currentPane?.editor.debugLine == nil)
        // Attach to a process that is already running.
        let loopBinary = root.deletingLastPathComponent().appendingPathComponent("loopbin").path
        if FileManager.default.isExecutableFile(atPath: loopBinary) {
            let victim = Process()
            victim.executableURL = URL(fileURLWithPath: loopBinary)
            try? victim.run()
            let attachController = ProjectWindowController(root: root.deletingLastPathComponent().appendingPathComponent("loopproj"), kind: .module, isTrusted: true)
            attachController.showWindow(nil)
            attachController.startAttach(pid: Int(victim.processIdentifier))
            settle(60) { attachController.debugState == .running || attachController.debugState.canStep }
            check("attaching to a running process works (\(attachController.debugState))", attachController.debugState == .running || attachController.debugState.canStep)
            attachController.debugAction("stop")
            settle(15) { if case .ended = attachController.debugState { return true } else { return false } }
            check("detaching leaves the process running (\(victim.isRunning))", victim.isRunning)
            victim.terminate()
        }
        controller.toggleBreakpointAtCaret()
        check("Toggle Breakpoint at the caret adds one (line 1)", controller.breakpoints.lines(in: file).contains(1))
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-profile`: a CPU profile made by `go test -cpuprofile` in a folder whose test calls burn, and a heap
    /// profile captured from a program serving net/http/pprof on 127.0.0.1:16060 (its binary is `profsrvbin` next to the folder).
    private func runProfileSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-profile"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 60, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".gobi"))
        selfTestCleanups.append { try? FileManager.default.removeItem(at: root.appendingPathComponent(".gobi")) }
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        make.arguments = ["go", "test", "-count=1", "-cpuprofile", root.appendingPathComponent("cpu.pprof").path, "-o", root.appendingPathComponent("prof.test").path, "."]
        make.currentDirectoryURL = root
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        try? make.run()
        make.waitUntilExit()
        selfTestCleanups.append { try? FileManager.default.removeItem(at: root.appendingPathComponent("cpu.pprof")); try? FileManager.default.removeItem(at: root.appendingPathComponent("prof.test")) }
        check("go test -cpuprofile made a profile", FileManager.default.fileExists(atPath: root.appendingPathComponent("cpu.pprof").path))

        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.loadProfile(root.appendingPathComponent("cpu.pprof"))
        settle { controller.profilerTopNames.contains { $0.hasSuffix("burn") } }
        check("the Top table lists burn first or near the top (\(controller.profilerTopNames.prefix(3)))", controller.profilerTopNames.prefix(3).contains { $0.hasSuffix("burn") })
        check("the flame graph has frames (\(controller.profilerFlameCount))", controller.profilerFlameCount > 3)
        controller.selectProfilerFrame(named: controller.profilerTopNames.first { $0.hasSuffix("burn") } ?? "")
        check("selecting a frame shows its cost and its callers (\(controller.profilerInspector.split(separator: "\n").prefix(3).joined(separator: " | ")))", controller.profilerInspector.contains("Flat:") && controller.profilerInspector.contains("Called by"))
        check("the status names the profile and its total (\(controller.profilerStatus))", controller.profilerStatus.hasPrefix("cpu.pprof") && controller.profilerStatus.contains(" ms"))
        // Filter box: the Top table and the flame graph narrow to the matching function.
        let allFrames = controller.profilerFlameCount
        controller.setProfilerFilter("BURN")
        check("the filter narrows Top to matching names (\(controller.profilerTopNames))", !controller.profilerTopNames.isEmpty && controller.profilerTopNames.allSatisfy { $0.lowercased().contains("burn") })
        let kept = controller.profilerFlameCount
        controller.setProfilerFilter("no-such-function")
        check("and the flame graph (\(kept) of \(allFrames) kept, none when nothing matches: \(controller.profilerFlameCount), Top \(controller.profilerTopNames.count))", kept > 0 && controller.profilerFlameCount == 0 && controller.profilerTopNames.isEmpty)
        controller.setProfilerFilter("")
        check("clearing the filter restores both", controller.profilerFlameCount == allFrames)

        // Source view: per-line cost of burn, double click opens the file at that line.
        let burnName = controller.profilerTopNames.first { $0.hasSuffix("burn") } ?? ""
        controller.showProfilerSource(of: burnName)
        settle(15) { !controller.profilerSourceCostLines.isEmpty }
        check("the Source view lists the file with costed lines (\(controller.profilerSourceCostLines), \(controller.profilerSourceRowCount) rows)", !controller.profilerSourceCostLines.isEmpty && controller.profilerSourceRowCount > 3)
        check("the Source view shows only the function (lines \(controller.profilerSourceFirstLine ?? 0)-\(controller.profilerSourceLastLine ?? 0))", controller.profilerSourceFirstLine == 5 && controller.profilerSourceLastLine == 11)
        controller.setProfilerWholeFile(true)
        check("Show whole file lists the file (\(controller.profilerSourceRowCount) rows from line \(controller.profilerSourceFirstLine ?? 0))", controller.profilerSourceFirstLine == 1 && controller.profilerSourceRowCount > 11)
        controller.setProfilerWholeFile(false)
        controller.openProfilerSourceLine(controller.profilerSourceCostLines.first ?? 1)
        settle(5) { controller.currentPane != nil }
        check("opening a source line opens the file", controller.currentPane != nil)

        // Compare with a second CPU profile of the same program.
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        again.arguments = ["go", "test", "-count=1", "-cpuprofile", root.appendingPathComponent("cpu2.pprof").path, "-o", root.appendingPathComponent("prof2.test").path, "."]
        again.currentDirectoryURL = root
        again.standardOutput = FileHandle.nullDevice
        again.standardError = FileHandle.nullDevice
        try? again.run()
        again.waitUntilExit()
        selfTestCleanups.append { try? FileManager.default.removeItem(at: root.appendingPathComponent("cpu2.pprof")); try? FileManager.default.removeItem(at: root.appendingPathComponent("prof2.test")) }
        controller.compareProfile(with: root.appendingPathComponent("cpu2.pprof"))
        settle(20) { !controller.profilerDiffNames.isEmpty }
        let deltas = controller.profilerDiffDeltas.map { $0 < 0 ? -$0 : $0 }
        check("Compare lists functions by absolute change (\(controller.profilerDiffNames.prefix(3)))", !deltas.isEmpty && deltas == deltas.sorted(by: >) && controller.profilerStatus.hasPrefix("cpu2.pprof"))
        if let snapshotPath { controller.showProfiler(); RunLoop.current.run(until: Date().addingTimeInterval(0.6)); WindowSnapshot.write(controller.window, to: snapshotPath) }
        controller.loadProfile(root.appendingPathComponent("cpu.pprof"))
        settle { controller.profilerDiffNames.isEmpty && controller.profilerTopNames.contains { $0.hasSuffix("burn") } }
        check("opening a profile leaves the comparison", controller.profilerDiffNames.isEmpty)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: root.deletingLastPathComponent().appendingPathComponent("profsrvbin").path)
        try? server.run()
        selfTestCleanups.append { server.terminate() }
        Thread.sleep(forTimeInterval: 1)
        controller.captureProfile(address: "localhost:16060", kind: "heap", seconds: 0)
        settle(30) { controller.profilerStatus.hasPrefix("heap-") && controller.profilerStatus.contains("B") }
        check("a heap profile captured from a running program is shown (\(controller.profilerStatus))", controller.profilerStatus.hasPrefix("heap-"))
        for kind in ["goroutine", "mutex"] {
            controller.captureProfile(address: "localhost:16060", kind: kind, seconds: 0)
            settle(30) { controller.profilerStatus.hasPrefix("\(kind)-") }
            check("a \(kind) profile is captured with its own preset (\(controller.profilerStatus))", controller.profilerStatus.hasPrefix("\(kind)-"))
            settle(1.5) { false }   // let the capture's own follow-up loads finish before the next capture starts
        }
        controller.captureProfile(address: "example.com:6060", kind: "heap", seconds: 0)
        settle(10) { controller.profilerStatus.hasPrefix("Capture failed") }
        check("a remote address is refused (\(controller.profilerStatus))", controller.profilerStatus.hasPrefix("Capture failed") && controller.profilerStatus.contains("this machine"))
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-git`: a repository with one commit that has a.go (5 lines), then a.go edited (line 2 changed,
    /// line 4 removed, two lines added at the end) and an untracked fresh.go. The repository needs a local user.name and user.email.
    private func runGitSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-git"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 30, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let original = EditorPreferences.current
        EditorPreferences.update { $0.autoSave = .off }
        selfTestCleanups.append { EditorPreferences.current = original }
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("a.go"))
        settle { controller.gitStatus != nil && !controller.sourceControlRows.isEmpty }
        check("Source control shows the branch (\(controller.sourceControlBranch))", controller.sourceControlBranch.hasPrefix("main"))
        let blockHeight = controller.sourceControlHeight
        check("the Source control block is tall enough to read (\(Int(blockHeight)) pt)", blockHeight >= 150)
        controller.moveFilesDivider(toBlockHeight: blockHeight + 120)
        check("dragging the divider makes the Source control block taller (\(Int(blockHeight)) to \(Int(controller.sourceControlHeight)) pt)", controller.sourceControlHeight > blockHeight + 60)
        check("and the changed files with their letters (\(controller.sourceControlRows))", controller.sourceControlRows.contains("M a.go") && controller.sourceControlRows.contains("? fresh.go"))
        settle(15) { !(controller.currentPane?.editor.gitMarks.modified.isEmpty ?? true) }
        let marks = controller.currentPane?.editor.gitMarks
        check("the gutter marks the changed, added and removed lines (\(String(describing: marks)))", marks?.modified == [2] && marks?.added == [5, 6] && marks?.deletedAfter == [3])
        controller.showDiff(path: "a.go")
        settle(10) { controller.gitPanelDiff.contains("+") }
        check("the bottom Diff tab shows the diff of the selected file (\(controller.panelTabTitles[controller.selectedPanelTab]))", controller.selectedPanelTab == 5 && controller.panelTabTitles[5] == "Diff" && controller.gitPanelDiff.contains("-line2") && controller.gitPanelDiff.contains("+line2 edited") && controller.gitPanelDiffTitle.hasPrefix("a.go"))
        check("the Commit tab lists the changes in Changes and Unversioned Files (\(controller.gitPanelSections), \(controller.gitPanelFiles))", controller.gitPanelSections == ["Changes", "Unversioned Files"] && controller.gitPanelFiles.contains("a.go") && controller.gitPanelFiles.contains("fresh.go") && controller.commitPanelView.checkState(of: "a.go") == .unchecked)
        controller.commitPanelView.toggleFile("a.go")
        settle(10) { controller.commitPanelView.checkState(of: "a.go") == .checked }
        check("ticking a file stages it", controller.commitPanelView.checkState(of: "a.go") == .checked && controller.gitStatus?.stagedFiles.map(\.path) == ["a.go"])
        controller.commitPanelView.toggleFile("a.go")
        settle(10) { controller.commitPanelView.checkState(of: "a.go") == .unchecked }
        check("unticking it unstages it", controller.commitPanelView.checkState(of: "a.go") == .unchecked && controller.gitStatus?.stagedFiles.isEmpty == true)
        controller.commitPanelView.toggleFile("a.go")
        settle(10) { controller.commitPanelView.checkState(of: "a.go") == .checked }
        controller.commitChanges()
        check("Commit… selects the Commit tab and puts the cursor in the message (\(controller.sidebarTabIndex))", controller.sidebarTabIndex == 4 && controller.commitPanelView.mode == .commit && controller.commitPanelView.messageHasFocus)
        check("the five sidebar tabs fit the sidebar (\(controller.sidebarTabsWidths))", controller.sidebarTabsFit)
        check("Commit stays off while the message is empty", !controller.commitPanelView.commitEnabled && !controller.commitPanelView.commitAndPushEnabled)
        controller.commitPanelView.setMessage(String(repeating: "x", count: 60))
        check("a long first line shows the warning from Settings > Git (\(controller.commitPanelView.warningText))", controller.commitPanelView.commitEnabled && controller.commitPanelView.warningText.contains("60"))
        controller.commitPanelView.setMessage("")
        controller.commit(message: "edit a", stageAll: false)
        settle(15) { !controller.sourceControlRows.contains { $0.hasSuffix("a.go") } }
        check("committing removes it from the changes (\(controller.sourceControlRows))", !controller.sourceControlRows.contains { $0.hasSuffix("a.go") } && controller.sourceControlRows.contains("? fresh.go"))
        check("a committed file leaves the Diff tab empty again (\(controller.gitPanelDiff))", controller.gitPanelDiff == DiffPanelView.emptyText)
        settle(10) { controller.gitPanelCommits.count >= 2 }
        check("the Log lists the new commit first (\(controller.gitPanelCommits.map(\.subject)))", controller.gitPanelCommits.first?.subject == "edit a" && controller.gitPanelCommits.count == 2)
        settle(10) { controller.currentPane?.editor.gitMarks.modified.isEmpty == true }
        check("the gutter clears once the change is committed", controller.currentPane?.editor.gitMarks.modified.isEmpty == true)
        if let snapshotPath { controller.showDiff(path: "fresh.go"); RunLoop.current.run(until: Date().addingTimeInterval(0.8)); WindowSnapshot.write(controller.window, to: snapshotPath) }
        controller.gitAction(.checkout("topic", create: true))
        settle(10) { controller.sourceControlBranch.hasPrefix("topic") }
        check("a new branch is created and switched to (\(controller.sourceControlBranch), \(controller.gitBranches.map(\.name)))", controller.sourceControlBranch.hasPrefix("topic") && controller.gitBranches.map(\.name).sorted() == ["main", "topic"])
        check("the branch menu lists both with the current one checked", controller.branchMenu()?.items.filter { $0.state == .on }.map(\.title) == ["topic"] && (controller.branchMenu()?.items.count ?? 0) == 5)
        controller.switchBranch("main")
        settle(10) { controller.sourceControlBranch.hasPrefix("main") }
        check("switching back works (\(controller.sourceControlBranch))", controller.sourceControlBranch.hasPrefix("main"))
        check("the branch menu ends with Merge into Current Branch… (\(controller.branchMenu()?.items.last?.title ?? "none"))", controller.branchMenu()?.items.last?.title == "Merge into Current Branch…")

        // Merge: a branch with its own commit comes into main as a merge commit; a conflicting one is undone.
        let topicFile = root.appendingPathComponent("t.go"), mergeB = root.appendingPathComponent("b.go")
        let mergeBText = (try? String(contentsOf: mergeB, encoding: .utf8)) ?? ""
        selfTestCleanups.append { try? FileManager.default.removeItem(at: topicFile); try? mergeBText.write(to: mergeB, atomically: true, encoding: .utf8) }
        func onBranch(_ name: String) {
            controller.switchBranch(name)
            settle(10) { controller.sourceControlBranch.hasPrefix(name) }
        }
        func commitFile(_ url: URL, _ text: String, _ message: String) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            controller.refreshGit()
            settle(10) { controller.gitPanelFiles.contains(url.lastPathComponent) }
            controller.gitAction(.stage([url.lastPathComponent]))
            settle(10) { controller.gitStatus?.stagedFiles.contains { $0.path == url.lastPathComponent } == true }   // the commit must not overtake the stage
            controller.commit(message: message, stageAll: false)
            settle(15) { controller.gitPanelCommits.first?.subject == message }
        }
        onBranch("topic")
        commitFile(topicFile, "package main\n// topic\n", "topic work")
        onBranch("main")
        check("the topic file is not on main yet", !FileManager.default.fileExists(atPath: topicFile.path))
        controller.merge("topic")
        settle(15) { controller.gitPanelCommits.first?.subject.hasPrefix("Merge") == true }
        check("Merge brings the branch in as a merge commit (\(controller.gitPanelCommits.first?.subject ?? "none"))", FileManager.default.fileExists(atPath: topicFile.path) && controller.gitPanelCommits.first?.subject.hasPrefix("Merge") == true)
        commitFile(mergeB, mergeBText + "// main side\n", "main edit b")
        onBranch("topic")
        commitFile(mergeB, mergeBText + "// topic side\n", "topic edit b")
        onBranch("main")
        controller.merge("topic")
        settle(15) { controller.statusNote.contains("conflict") }
        let afterConflict = (try? String(contentsOf: mergeB, encoding: .utf8)) ?? ""
        check("a conflicting merge is undone and says so (\(controller.statusNote))", controller.statusNote.contains("conflict") && controller.statusNote.contains("aborted") && afterConflict == mergeBText + "// main side\n" && !controller.gitPanelFiles.contains("b.go"))

        // Discard Changes: a tracked file goes back to the last commit, an untracked file is deleted.
        let b = root.appendingPathComponent("b.go"), scratch = root.appendingPathComponent("scratch.go")
        let bText = (try? String(contentsOf: b, encoding: .utf8)) ?? ""
        selfTestCleanups.append { try? bText.write(to: b, atomically: true, encoding: .utf8); try? FileManager.default.removeItem(at: scratch) }
        try? (bText + "// edited\n").write(to: b, atomically: true, encoding: .utf8)
        try? "package main\n".write(to: scratch, atomically: true, encoding: .utf8)
        controller.refreshGit()
        settle(10) { controller.gitPanelFiles.contains("b.go") && controller.gitPanelFiles.contains("scratch.go") }
        check("both appear as changes (\(controller.gitPanelFiles))", controller.gitPanelFiles.contains("b.go") && controller.gitPanelFiles.contains("scratch.go"))
        controller.discardChanges("b.go", confirm: false)
        controller.discardChanges("scratch.go", confirm: false)
        settle(10) { !controller.gitPanelFiles.contains("b.go") && !controller.gitPanelFiles.contains("scratch.go") && !FileManager.default.fileExists(atPath: scratch.path) && (try? String(contentsOf: b, encoding: .utf8)) == bText }
        check("Discard puts the tracked file back and deletes the untracked one (\(controller.gitPanelFiles), \((try? String(contentsOf: b, encoding: .utf8))?.suffix(20) ?? "nil"))", (try? String(contentsOf: b, encoding: .utf8)) == bText && !FileManager.default.fileExists(atPath: scratch.path) && !controller.gitPanelFiles.contains("b.go"))

        // The operations behind the Git menu (tag, stash, patch, reset, rebase, merge/cherry-pick/revert control, remotes, worktrees),
        // through the window's own entry points; the dialogs around them are not exercised.
        func gitOut(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root.path, "-c", "user.email=t@example.test", "-c", "user.name=t"] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        func waitForGit(_ seconds: Double = 15, _ condition: @escaping () -> Bool) {
            controller.refreshGit()
            settle(seconds, until: condition)
        }
        let scratchFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gobi-gitmenu-\(getpid())")
        try? FileManager.default.createDirectory(at: scratchFolder, withIntermediateDirectories: true)
        selfTestCleanups.append { try? FileManager.default.removeItem(at: scratchFolder) }

        controller.tagHead("selftest-tag")
        settle(10) { gitOut(["tag", "--list"]).contains("selftest-tag") }
        check("New Tag marks the commit", gitOut(["tag", "--list"]).contains("selftest-tag"))

        let before = (try? String(contentsOf: b, encoding: .utf8)) ?? ""
        try? (before + "// stashed\n").write(to: b, atomically: true, encoding: .utf8)
        waitForGit { controller.gitPanelFiles.contains("b.go") }
        controller.stashChanges(message: "selftest stash")
        settle(15) { gitOut(["stash", "list"]).contains("selftest stash") }
        check("Stash Changes saves the edit and cleans the file (\(gitOut(["stash", "list"])))", gitOut(["stash", "list"]).contains("selftest stash") && (try? String(contentsOf: b, encoding: .utf8)) == before)
        controller.unstashChanges()
        settle(15) { ((try? String(contentsOf: b, encoding: .utf8)) ?? "").hasSuffix("// stashed\n") && gitOut(["stash", "list"]).isEmpty }
        check("Unstash Changes brings it back", ((try? String(contentsOf: b, encoding: .utf8)) ?? "").hasSuffix("// stashed\n") && gitOut(["stash", "list"]).isEmpty)

        // Patch: the changes since HEAD go to a file, are rolled back, and come back from the file.
        let patchFile = scratchFolder.appendingPathComponent("changes.patch")
        var patchText = ""
        controller.git({ try $0.patch() }) { if case .success(let text) = $0 { patchText = text } }
        settle(10) { !patchText.isEmpty }
        check("Create Patch has the change (\(patchText.count) bytes)", patchText.contains("+// stashed") && controller.writePatch(patchText, to: patchFile))
        controller.discardChanges("b.go", confirm: false)
        settle(10) { (try? String(contentsOf: b, encoding: .utf8)) == before }
        controller.applyPatch(file: patchFile.path)
        settle(10) { ((try? String(contentsOf: b, encoding: .utf8)) ?? "").hasSuffix("// stashed\n") }
        check("Apply Patch puts the change back", ((try? String(contentsOf: b, encoding: .utf8)) ?? "").hasSuffix("// stashed\n"))
        waitForGit { controller.gitPanelFiles.contains("b.go") }
        controller.rollBackAll(confirmFirst: false)
        settle(10) { (try? String(contentsOf: b, encoding: .utf8)) == before }
        check("Roll Back All throws every change away", (try? String(contentsOf: b, encoding: .utf8)) == before)

        // Reset HEAD: a throwaway commit is dropped by a hard reset.
        let headBefore = gitOut(["rev-parse", "HEAD"])
        commitFile(b, before + "// to reset\n", "to reset")
        check("the throwaway commit is HEAD", gitOut(["log", "-1", "--format=%s"]).hasPrefix("to reset"))
        controller.resetHead(mode: "hard", target: "HEAD~1")
        settle(15) { gitOut(["rev-parse", "HEAD"]) == headBefore }
        check("Reset HEAD (hard) goes back one commit and restores the file", gitOut(["rev-parse", "HEAD"]) == headBefore && (try? String(contentsOf: b, encoding: .utf8)) == before)

        // Rebase: topic and main both changed b.go, so the rebase stops on a conflict and stays in progress.
        onBranch("topic")
        controller.rebase(onto: "main")
        waitForGit { controller.gitStatus?.operation == .rebase }
        check("a conflicting rebase stays in progress (\(String(describing: controller.gitStatus?.operation)))", controller.gitStatus?.operation == .rebase)
        check("the menu enables the rebase items and not Abort Merge", ["gitAbortRebase", "gitContinueRebase", "gitSkipCommit"].allSatisfy { MenuAvailability.isEnabled($0, in: controller.menuContext) == true } && MenuAvailability.isEnabled("gitAbortMerge", in: controller.menuContext) == false)
        check("Resolve Conflicts lists the file and opens it (\(controller.resolveConflicts()))", controller.resolveConflicts() == ["b.go"] && controller.currentPane?.editorFile.fileURL.lastPathComponent == "b.go")
        controller.gitOperation(.abortRebase, title: "Rebase aborted", reloadFiles: true)
        waitForGit { controller.gitStatus?.operation == nil }
        check("Abort Rebase ends it", controller.gitStatus?.operation == nil && gitOut(["rev-parse", "--abbrev-ref", "HEAD"]).hasPrefix("topic"))
        controller.rebase(onto: "main")
        waitForGit { controller.gitStatus?.operation == .rebase }
        controller.skipRebaseCommit()
        waitForGit { controller.gitStatus?.operation == nil }
        check("Skip Commit drops the conflicting commit and finishes the rebase", controller.gitStatus?.operation == nil && !gitOut(["log", "--format=%s"]).contains("topic edit b"))
        onBranch("main")

        // Merge, cherry-pick and revert left stopped on a conflict show up and can be aborted. Two branches add the same file differently.
        let conflictFile = root.appendingPathComponent("conf.go")
        func commitByHand(_ text: String, _ message: String) {
            try? text.write(to: conflictFile, atomically: true, encoding: .utf8)
            _ = gitOut(["add", "conf.go"])
            _ = gitOut(["commit", "-q", "-m", message])
        }
        let mainTip = gitOut(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = gitOut(["switch", "-q", "-c", "ops-x"])
        commitByHand("package main // x\n", "ops x")
        let opsX = gitOut(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = gitOut(["switch", "-q", "main"])
        commitByHand("package main // y\n", "ops y")
        commitByHand("package main // z\n", "ops z")
        selfTestCleanups.append { try? FileManager.default.removeItem(at: conflictFile) }
        controller.refreshGit()
        let gitMenu = NSApp.mainMenu?.items.compactMap { $0.submenu }.first { $0.title == "Git" }
        func enabledInMenu(_ action: String) -> Bool { MenuAvailability.isEnabled(action, in: controller.menuContext) ?? false }
        _ = gitOut(["merge", "--no-edit", "ops-x"])
        waitForGit { controller.gitStatus?.operation == .merge }
        check("a stopped merge is reported (\(String(describing: controller.gitStatus?.operation)))", controller.gitStatus?.operation == .merge)
        check("Abort Merge is enabled and the rebase items are not", enabledInMenu("gitAbortMerge") && !enabledInMenu("gitAbortRebase") && !enabledInMenu("gitMerge") && gitMenu?.items.first { $0.title == "Abort Merge" }?.action != nil)
        controller.gitOperation(.abortMerge, title: "Merge aborted", reloadFiles: true)
        waitForGit { controller.gitStatus?.operation == nil }
        check("Abort Merge ends it", controller.gitStatus?.operation == nil)
        _ = gitOut(["cherry-pick", opsX])
        waitForGit { controller.gitStatus?.operation == .cherryPick }
        check("a stopped cherry-pick is reported and its items enabled (\(String(describing: controller.gitStatus?.operation)))", controller.gitStatus?.operation == .cherryPick && enabledInMenu("gitAbortCherryPick") && enabledInMenu("gitContinueCherryPick") && !enabledInMenu("gitAbortRevert"))
        controller.gitOperation(.abortCherryPick, title: "Cherry-pick aborted", reloadFiles: true)
        waitForGit { controller.gitStatus?.operation == nil }
        check("Abort Cherry-Pick ends it", controller.gitStatus?.operation == nil)
        _ = gitOut(["revert", "--no-edit", "HEAD~1"])
        waitForGit { controller.gitStatus?.operation == .revert }
        check("a stopped revert is reported (\(String(describing: controller.gitStatus?.operation)))", controller.gitStatus?.operation == .revert && enabledInMenu("gitAbortRevert"))
        controller.gitOperation(.abortRevert, title: "Revert aborted", reloadFiles: true)
        waitForGit { controller.gitStatus?.operation == nil }
        check("Abort Revert ends it", controller.gitStatus?.operation == nil)
        _ = gitOut(["reset", "-q", "--hard", mainTip])
        _ = gitOut(["branch", "-q", "-D", "ops-x"])
        controller.refreshGit()

        // Remotes and worktrees.
        var remotes: [GitRemote] = []
        controller.addRemote(name: "selftest", url: "https://example.test/x.git")
        controller.git({ try $0.remotes() }) { _ in }
        settle(10) { gitOut(["remote"]).contains("selftest") }
        controller.git({ try $0.remotes() }) { if case .success(let list) = $0 { remotes = list } }
        settle(10) { !remotes.isEmpty }
        check("Manage Remotes adds a remote and lists it (\(remotes))", remotes.contains(GitRemote(name: "selftest", url: "https://example.test/x.git")))
        controller.removeRemote("selftest")
        settle(10) { !gitOut(["remote"]).contains("selftest") }
        check("and removes it", !gitOut(["remote"]).contains("selftest"))
        let worktreeFolder = scratchFolder.appendingPathComponent("wt").path
        controller.addWorktree(path: worktreeFolder, branch: "selftest-wt", create: true)
        settle(15) { FileManager.default.fileExists(atPath: worktreeFolder) }
        var worktrees: [GitWorktree] = []
        controller.git({ try $0.worktrees() }) { if case .success(let list) = $0 { worktrees = list } }
        settle(10) { !worktrees.isEmpty }
        check("New Worktree checks the branch out in a second folder (\(worktrees.map(\.title)))", worktrees.count == 2 && worktrees.contains { $0.branch == "selftest-wt" })
        controller.removeWorktree(worktreeFolder)
        settle(15) { !FileManager.default.fileExists(atPath: worktreeFolder) }
        check("Worktrees removes it again", !FileManager.default.fileExists(atPath: worktreeFolder))
        _ = gitOut(["branch", "-D", "selftest-wt"])
        _ = gitOut(["tag", "-d", "selftest-tag"])

        // The Commit tab end to end: the message field commits, Amend rewords, Commit and Push reaches a bare remote, and a stash
        // shows in the Stash segment and pops from it.
        let panelFile = root.appendingPathComponent("panel.go")
        selfTestCleanups.append { try? FileManager.default.removeItem(at: panelFile) }
        let panel = controller.commitPanelView
        controller.selectSidebarTab(0)
        controller.showGitLog()
        check("Show Git Log opens the Commit tab on the Log segment", controller.sidebarTabIndex == 4 && panel.mode == .log)
        try? "package main\n// panel\n".write(to: panelFile, atomically: true, encoding: .utf8)
        waitForGit { controller.gitPanelFiles.contains("panel.go") }
        panel.toggleFile("panel.go")
        settle(10) { panel.checkState(of: "panel.go") == .checked }
        panel.setMessage("panel commit")
        check("with a message the Commit buttons turn on", panel.commitEnabled && panel.commitAndPushEnabled)
        panel.commitPressed()
        settle(15) { controller.gitPanelCommits.first?.subject == "panel commit" && panel.messageText.isEmpty && !controller.gitPanelFiles.contains("panel.go") }
        check("Commit commits the ticked file and clears the field (\(controller.gitPanelCommits.map(\.subject).prefix(2)))", controller.gitPanelCommits.first?.subject == "panel commit" && panel.messageText.isEmpty && !controller.gitPanelFiles.contains("panel.go"))
        let commitCount = controller.gitPanelCommits.count
        try? "package main\n// panel amended\n".write(to: panelFile, atomically: true, encoding: .utf8)
        waitForGit { controller.gitPanelFiles.contains("panel.go") }
        panel.toggleFile("panel.go")
        settle(10) { panel.checkState(of: "panel.go") == .checked }
        panel.toggleAmend(true)
        settle(10) { panel.messageText == "panel commit" }
        check("Amend fills the empty field with the last message (\(panel.messageText))", panel.messageText == "panel commit" && panel.isAmending)
        panel.setMessage("panel reworded")
        panel.commitPressed()
        settle(15) { controller.gitPanelCommits.first?.subject == "panel reworded" }
        check("Commit with Amend replaces the last commit (\(controller.gitPanelCommits.map(\.subject).prefix(2)))", controller.gitPanelCommits.first?.subject == "panel reworded" && controller.gitPanelCommits.count == commitCount && !panel.isAmending && gitOut(["show", "--stat", "--format=", "HEAD"]).contains("panel.go"))

        let bareRemote = scratchFolder.appendingPathComponent("remote.git").path
        _ = gitOut(["init", "-q", "--bare", bareRemote])
        _ = gitOut(["remote", "add", "selftest-origin", bareRemote])
        _ = gitOut(["push", "-q", "-u", "selftest-origin", "main"])
        try? "package main\n// panel pushed\n".write(to: panelFile, atomically: true, encoding: .utf8)
        waitForGit { controller.gitPanelFiles.contains("panel.go") }
        panel.toggleFile("panel.go")
        settle(10) { panel.checkState(of: "panel.go") == .checked }
        panel.setMessage("panel pushed")
        panel.commitAndPushPressed()
        func remoteSubject() -> String { gitOut(["--git-dir", bareRemote, "log", "-1", "--format=%s", "main"]).trimmingCharacters(in: .whitespacesAndNewlines) }
        settle(20) { remoteSubject() == "panel pushed" }
        check("Commit and Push puts the commit on the remote (\(remoteSubject()))", remoteSubject() == "panel pushed" && panel.messageText.isEmpty)
        _ = gitOut(["remote", "remove", "selftest-origin"])

        try? "package main\n// panel stash\n".write(to: panelFile, atomically: true, encoding: .utf8)
        waitForGit { controller.gitPanelFiles.contains("panel.go") }
        controller.stashChanges(message: "panel stash")
        panel.mode = .stash
        func panelText() -> String { (try? String(contentsOf: panelFile, encoding: .utf8)) ?? "" }
        settle(15) { panel.stashTitles.contains { $0.contains("panel stash") } }
        check("the Stash segment lists the stash (\(panel.stashTitles))", panel.stashTitles.count == 1 && panel.stashTitles[0].hasPrefix("stash@{0}:") && panel.stashTitles[0].contains("panel stash") && !panelText().contains("panel stash"))
        panel.selectStash(at: 0)
        panel.stashApplyPressed()
        settle(15) { panelText().contains("panel stash") }
        check("Apply brings the edit back and keeps the stash", panelText().contains("panel stash") && panel.stashTitles.count == 1)
        controller.discardChanges("panel.go", confirm: false)
        settle(10) { !panelText().contains("panel stash") }
        panel.selectStash(at: 0)
        panel.stashPopPressed()
        settle(15) { panelText().contains("panel stash") && panel.stashTitles.isEmpty }
        check("Pop brings it back and removes the stash", panelText().contains("panel stash") && panel.stashTitles.isEmpty)
        controller.discardChanges("panel.go", confirm: false)
        settle(10) { !panelText().contains("panel stash") }
        controller.selectSidebarTab(0)
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-env`: environment profiles. The folder needs a main.go that prints GOBI_FILE, GOBI_VAR,
    /// GOBI_OVERRIDDEN, GOBI_SECRET and GOFLAGS, and a `.env.shared` file with GOBI_FILE=from-file and GOBI_OVERRIDDEN=file.
    private func runEnvironmentSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-env"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 60, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".gobi"))
        selfTestCleanups.append {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".gobi"))
            Keychain.delete("GOBI_SECRET", root: root.path)
            UserDefaults.standard.removeObject(forKey: "gobi.activeEnvironment." + root.path)
        }
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("main.go"))
        check("a project without a profile file has no profiles", !controller.environments.hasProfiles)

        // Build two profiles through the window and save.
        var staging = EnvProfile(name: "staging")
        staging.isRemote = true
        staging.envFiles = [".env.shared"]
        staging.vars = [EnvVar(name: "GOBI_VAR", value: "from-var"), EnvVar(name: "GOBI_OVERRIDDEN", value: "var"), EnvVar(name: "DB_HOST", value: "postgres.staging.example")]
        staging.goflags = "-mod=mod"
        staging.tags = "staging"
        var local = EnvProfile(name: "local")
        local.isDefault = true
        local.envFiles = [".env.shared"]
        try? controller.environments.save(EnvironmentFile(profiles: [local, staging]))
        let window = EnvironmentsWindowController(store: controller.environments)
        check("the Environments window lists the profiles (\(window.profileNames))", window.profileNames == ["local", "staging"])
        window.add(variable: "GOBI_EXTRA", value: "x")
        window.setSecret("GOBI_SECRET", value: "s3cret-value")
        window.add(file: root.appendingPathComponent(".env.shared").path)
        check("a variable, a secret and a file can be added", window.save() == nil)
        let toml = (try? String(contentsOf: controller.environments.fileURL, encoding: .utf8)) ?? ""
        check("the file names the secret but never holds its value", toml.contains("GOBI_SECRET = true") && !toml.contains("s3cret-value"))
        check("the secret is in the Keychain", Keychain.get("GOBI_SECRET", root: root.path) == "s3cret-value")

        // Run with the local profile.
        controller.reloadEnvironments()
        controller.selectEnvironment("local")
        check("the Environment menu lists both with the active one checked", controller.environmentMenu().items.filter { $0.state == .on }.map(\.title) == ["local"] && controller.environmentMenu().items.count == 4)
        controller.runProject()
        settle { !controller.isRunning && controller.runOutputText.contains("file=") }
        check("a run sees the env file and the Keychain secret (\(controller.runOutputText.split(separator: "\n").first { $0.hasPrefix("file=") } ?? ""))", controller.runOutputText.contains("file=from-file") && controller.runOutputText.contains("secret=s3cret-value") && controller.runOutputText.contains("over=file"))

        // The remote profile: variables override files, Go settings reach GOFLAGS, and the run asks first.
        controller.selectEnvironment("staging")
        var asked: [EnvTarget] = []
        controller.confirmNonLocal = { asked = $0; return false }
        controller.runProject()
        check("a profile with non-local targets asks first and Cancel stops the run (\(asked.map(\.address)))", asked.first?.address == "postgres.staging.example:5432" && !controller.isRunning)
        controller.confirmNonLocal = { _ in true }
        controller.runProject()
        settle { !controller.isRunning && controller.runOutputText.contains("goflags=") }
        let line = controller.runOutputText.split(separator: "\n").first { $0.hasPrefix("file=") } ?? ""
        check("after Run Anyway the variables override the file and the Go settings apply (\(line))", line.contains("var=from-var") && line.contains("over=var") && line.contains("goflags=-mod=mod -tags=staging"))
        print("")
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-settings`: the General, Keymap, Terminal, Git and Advanced tabs and what they change. The folder is
    /// a git repository with a.go edited (as for --selftest-git).
    private func runSettingsSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-settings"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 30, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let defaults = UserDefaults.standard
        let savedKeys = Dictionary(uniqueKeysWithValues: (AppPreferences.keys + ["gobi.terminalShell", "gobi.editorSettings"]).map { ($0, defaults.object(forKey: $0)) })
        let savedTrust = ProjectStore.shared.trust, savedRecents = ProjectStore.shared.recents
        selfTestCleanups.append {
            for (key, value) in savedKeys { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            ProjectStore.shared.trust = savedTrust
            ProjectStore.shared.recents = savedRecents
        }
        EditorPreferences.update { $0.autoSave = .off }
        let settings = SettingsWindowController()

        // General.
        AppPreferences.update(\.general) { $0.onLaunch = .welcome; $0.recentLimit = 5 }
        settings.general.sync()
        check("General follows the stored launch behaviour and recent limit", ProjectStore.shared.showWelcomeAtLaunch && settings.general.launch.indexOfSelectedItem == 1 && settings.general.recents.titleOfSelectedItem == "5")
        var trust = ProjectStore.shared.trust
        trust.trust(path: "/selftest/trusted-folder")
        ProjectStore.shared.trust = trust
        settings.general.sync()
        check("the trusted folders are listed (\(settings.general.trustedPaths.suffix(1)))", settings.general.trustedPaths.contains("/selftest/trusted-folder"))
        settings.general.removeTrusted(path: "/selftest/trusted-folder")
        check("Remove takes a folder off the list", !ProjectStore.shared.trust.isTrusted(path: "/selftest/trusted-folder/x") && !settings.general.trustedPaths.contains("/selftest/trusted-folder"))

        // Keymap.
        settings.keymap.search("run tests")
        check("the Keymap list filters by name (\(settings.keymap.rowTitles))", settings.keymap.rowTitles.contains("Run Tests"))
        settings.keymap.search("")
        guard let run = KeymapItems.all.first(where: { $0.id == "Run ▸ Run" }), let back = KeymapItems.all.first(where: { $0.id == "Go ▸ Back" }) else { print("missing items"); selfTestExit(1) }
        check("a shortcut already in use is refused (\(String(describing: settings.keymap.assign("⌘U", to: back))))", settings.keymap.assign("⌘U", to: back) == "Run ▸ Run Tests" && !AppPreferences.keymap.isCustom(back.id))
        check("a free shortcut is accepted", settings.keymap.assign("⌥⌘R", to: run) == nil && AppPreferences.keymap.shortcut(for: run.id, default: run.defaultShortcut) == "⌥⌘R")
        settle(3) { NSApp.mainMenu?.items.first { $0.submenu?.title == "Run" }?.submenu?.items.first { $0.title == "Run" }?.keyEquivalent == "r" && NSApp.mainMenu?.items.first { $0.submenu?.title == "Run" }?.submenu?.items.first { $0.title == "Run" }?.keyEquivalentModifierMask == [.command, .option] }
        let runItem = NSApp.mainMenu?.items.first { $0.submenu?.title == "Run" }?.submenu?.items.first { $0.title == "Run" }
        check("the new shortcut reaches the menu bar (\(runItem?.keyEquivalent ?? "?"))", runItem?.keyEquivalent == "r" && runItem?.keyEquivalentModifierMask == [.command, .option])
        check("and the Keyboard Shortcuts list", ShortcutList.rows(overrides: AppPreferences.keymap).first { $0.menu == "Run" && $0.title == "Run" }?.shortcut == "⌥⌘R")
        AppPreferences.update(\.keymap) { $0.resetAll() }
        check("Reset to Default brings it back", AppPreferences.keymap.shortcut(for: run.id, default: run.defaultShortcut) == "⌘R")

        // Terminal and Git need a project window.
        let root = URL(fileURLWithPath: path)
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("a.go"))
        controller.showTerminalTab()
        settle { controller.terminalSessionCount == 1 }
        AppPreferences.update(\.terminal) { $0.fontSize = 16; $0.optionAsMeta = true; $0.cursor = .bar }
        check("Terminal settings reach the open terminal (\(String(describing: controller.terminalAppearance)))", controller.terminalAppearance?.fontSize == 16 && controller.terminalAppearance?.optionAsMeta == true)

        let installedIcons = TerminalFont.iconChain()
        AppPreferences.update(\.terminal) { $0.fontName = "Menlo" }
        let fontInfo = controller.terminalFontInfo
        check("the terminal font family follows Settings (\(fontInfo?.family ?? "none"))", fontInfo?.family == "Menlo")
        check("icon fonts found on this machine are its fallbacks (\(installedIcons.count) installed, \(fontInfo?.fallbacks ?? -1) in the font)", fontInfo?.fallbacks == installedIcons.count)
        AppPreferences.update(\.terminal) { $0.fontName = "SF Mono" }
        settle(10) { !settings.terminal.shellTitles.isEmpty && settings.terminal.shellTitles.count > 1 }
        check("the Terminal tab lists the shells (\(settings.terminal.shellTitles))", settings.terminal.shellTitles.contains { $0.hasSuffix("(login shell)") })

        settle(20) { !(controller.currentPane?.editor.gitMarks.modified.isEmpty ?? true) }
        check("the gutter shows git marks", !(controller.currentPane?.editor.gitMarks.modified.isEmpty ?? true))
        AppPreferences.update(\.git) { $0.showGutterMarks = false }
        settle(5) { controller.currentPane?.editor.gitMarks.modified.isEmpty == true }
        check("turning gutter marks off clears them", controller.currentPane?.editor.gitMarks.modified.isEmpty == true)
        AppPreferences.update(\.git) { $0.showGutterMarks = true }
        settle(10) { !(controller.currentPane?.editor.gitMarks.modified.isEmpty ?? true) }
        check("and on brings them back", !(controller.currentPane?.editor.gitMarks.modified.isEmpty ?? true))

        // Quit confirmation, and the update check that stays off.
        check("the update check is drawn disabled (no update server)", !settings.general.updates.isEnabled)
        check("quit confirmation is on by default", AppPreferences.general.confirmQuit && settings.general.confirmQuit.state == .on)
        controller.currentPane?.textView.insertText("// unsaved\n", replacementRange: NSRange(location: 0, length: 0))
        check("an edited file counts as unsaved (\(controller.unsavedFileCount))", controller.unsavedFileCount == 1)
        check("quitting then names it (\(QuitConfirmation.message(unsavedFiles: controller.unsavedFileCount, runningTasks: controller.runningTaskCount, enabled: AppPreferences.general.confirmQuit) ?? "nil"))", QuitConfirmation.message(unsavedFiles: controller.unsavedFileCount, runningTasks: controller.runningTaskCount, enabled: AppPreferences.general.confirmQuit) == "1 file has unsaved changes.")
        settings.general.confirmQuit.performClick(nil)
        check("turning the switch off stores it and stops the question", !AppPreferences.general.confirmQuit && QuitConfirmation.message(unsavedFiles: 1, runningTasks: 0, enabled: AppPreferences.general.confirmQuit) == nil)
        settings.general.confirmQuit.performClick(nil)
        controller.currentPane?.editorFile.isEdited = false

        // Terminal: scrollback and start folder for new terminals, copy on select.
        let savedPasteboard = NSPasteboard.general.string(forType: .string)
        selfTestCleanups.append { NSPasteboard.general.clearContents(); if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) } }
        check("the terminal in use has the default scrollback (\(controller.terminalScrollback ?? -1))", controller.terminalScrollback == 10_000)
        AppPreferences.update(\.terminal) { $0.scrollback = 1_000; $0.startIn = .home }
        settings.terminal.sync()
        check("the Terminal tab shows the stored scrollback and start folder", settings.terminal.scrollback.titleOfSelectedItem == "1,000 lines" && settings.terminal.startIn.indexOfSelectedItem == 1)
        controller.newTerminalForTest()
        settle(5) { controller.terminalScrollback == 1_000 }
        check("a new terminal gets the new scrollback (\(controller.terminalScrollback ?? -1))", controller.terminalScrollback == 1_000)
        check("and starts in the home folder (\(controller.terminalStartFolder))", controller.terminalStartFolder == NSHomeDirectory())
        AppPreferences.update(\.terminal) { $0.startIn = .project }
        controller.newTerminalForTest()
        check("Project folder starts it in the project (\(controller.terminalStartFolder))", controller.terminalStartFolder == root.path)
        check("without Copy on select nothing is copied", controller.terminalCopyOnSelect?.enabled == false && !controller.terminalCopySelection("copy-me-not") && NSPasteboard.general.string(forType: .string) != "copy-me-not")
        AppPreferences.update(\.terminal) { $0.copyOnSelect = true }
        check("Copy on select reaches the open terminal", controller.terminalCopyOnSelect?.enabled == true)
        let eventsBefore = controller.terminalCopyOnSelect?.selectionEvents ?? 0
        controller.terminalSelectAll()
        check("SwiftTerm announces a selection to the terminal view (\(controller.terminalCopyOnSelect?.selectionEvents ?? -1))", (controller.terminalCopyOnSelect?.selectionEvents ?? 0) > eventsBefore)
        check("a selected text goes to the pasteboard", controller.terminalCopySelection("copy-me-yes") && NSPasteboard.general.string(forType: .string) == "copy-me-yes")
        check("the same text is not copied twice", !controller.terminalCopySelection("copy-me-yes"))

        // Git path, fetch, and the large-file limit.
        let toolDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gobi-settings-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        selfTestCleanups.append { try? FileManager.default.removeItem(at: toolDirectory) }
        func runTool(_ program: String, _ arguments: [String], in directory: URL) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        let gitLog = toolDirectory.appendingPathComponent("git.log"), fakeGit = toolDirectory.appendingPathComponent("fakegit")
        try? "#!/bin/sh\necho \"$@\" >> '\(gitLog.path)'\nexec /usr/bin/git \"$@\"\n".write(to: fakeGit, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)
        let remote = toolDirectory.appendingPathComponent("remote.git")
        runTool("/usr/bin/git", ["init", "-q", "--bare", remote.path], in: toolDirectory)
        runTool("/usr/bin/git", ["remote", "add", "origin", remote.path], in: root)
        selfTestCleanups.append { runTool("/usr/bin/git", ["remote", "remove", "origin"], in: root) }
        check("a missing program is refused as the git path", !settings.git.gitPath.choose("/nonexistent/git") && AppPreferences.git.gitPath == "")
        check("a folder is refused too", !settings.git.gitPath.choose(toolDirectory.path))
        check("an executable is taken and stored", settings.git.gitPath.choose(fakeGit.path) && AppPreferences.git.gitPath == fakeGit.path)
        settings.git.sync()
        check("the Git tab lists the chosen path (\(settings.git.gitPath.itemTitles))", settings.git.gitPath.itemTitles.count == 3 && settings.git.gitPath.path == fakeGit.path)
        let other = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        other.showWindow(nil)
        settle(15) { (try? String(contentsOf: gitLog, encoding: .utf8))?.contains("status") == true }
        check("a window opened now runs git through the chosen program", (try? String(contentsOf: gitLog, encoding: .utf8))?.contains("status") == true)
        AppPreferences.update(\.git) { $0.fetchMinutes = 5 }
        other.lastFetch = Date()
        other.fetchIfDue()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("auto fetch waits for the interval", !((try? String(contentsOf: gitLog, encoding: .utf8)) ?? "").contains("fetch"))
        other.lastFetch = Date().addingTimeInterval(-301)
        other.fetchIfDue()
        settle(15) { ((try? String(contentsOf: gitLog, encoding: .utf8)) ?? "").contains("fetch") }
        check("and fetches once it is due", ((try? String(contentsOf: gitLog, encoding: .utf8)) ?? "").contains("fetch"))
        AppPreferences.update(\.git) { $0.fetchMinutes = 0 }
        other.lastFetch = Date().addingTimeInterval(-10_000)
        let fetchesBefore = ((try? String(contentsOf: gitLog, encoding: .utf8)) ?? "").components(separatedBy: "fetch").count
        other.fetchIfDue()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("Never fetches nothing", ((try? String(contentsOf: gitLog, encoding: .utf8)) ?? "").components(separatedBy: "fetch").count == fetchesBefore)
        other.window?.close()
        settings.git.gitPath.choose("")
        settings.git.gitPath.show("")
        AppPreferences.update(\.git) { $0.gitPath = "" }
        check("Automatic goes back to git on PATH", AppPreferences.git.gitPath == "")

        let goplsLog = toolDirectory.appendingPathComponent("gopls.log"), fakeGopls = toolDirectory.appendingPathComponent("fakegopls")
        let realGopls = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gopls" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? NSHomeDirectory() + "/go/bin/gopls"
        if FileManager.default.isExecutableFile(atPath: realGopls) {
            try? "#!/bin/sh\necho started >> '\(goplsLog.path)'\nexec '\(realGopls)' \"$@\"\n".write(to: fakeGopls, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGopls.path)
            controller.openFile(root.appendingPathComponent("c.go"))
            let paneC = controller.openPane(for: root.appendingPathComponent("c.go").path)
            settle(30) { paneC?.isConnected == true }
            check("c.go is open and connected before the gopls path changes", paneC?.isConnected == true && !FileManager.default.fileExists(atPath: goplsLog.path))
            check("a missing gopls is refused", !settings.advanced.goplsPath.choose("/nonexistent/gopls") && AppPreferences.advanced.goplsPath == "")
            check("an executable gopls is taken and stored", settings.advanced.goplsPath.choose(fakeGopls.path) && AppPreferences.advanced.goplsPath == fakeGopls.path)
            settle(30) { FileManager.default.fileExists(atPath: goplsLog.path) }
            check("an open Go file reconnects at once, through the chosen program", FileManager.default.fileExists(atPath: goplsLog.path))
            settle(30) { paneC?.isConnected == true }
            check("and is connected again", paneC?.isConnected == true)
            AppPreferences.update(\.advanced) { $0.goplsPath = "" }
        } else {
            check("gopls is not installed here, so the gopls path is not checked (skipped)", true)
        }

        let longFile = root.appendingPathComponent("long.go")
        selfTestCleanups.append { try? FileManager.default.removeItem(at: longFile) }
        try? ("package main\n// " + String(repeating: "x", count: 150_000) + "\n").write(to: longFile, atomically: true, encoding: .utf8)
        controller.openFile(longFile)
        check("a 150,000-character line is editable under the default limit", controller.currentPane?.editor.document.isReadOnlyByLineLength == false)
        let paneLong = controller.currentPane
        settings.advanced.lineLimit.selectItem(at: 0)
        settings.advanced.lineLimit.sendAction(settings.advanced.lineLimit.action, to: settings.advanced.lineLimit.target)
        check("the Large files choice is stored (\(AppPreferences.advanced.lineLimit))", AppPreferences.advanced.lineLimit == 100_000)
        let lengthOpen = (paneLong?.textView.string as NSString?)?.length ?? 0
        paneLong?.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        check("a lower limit makes the open file read-only at once, with the notice", paneLong?.editor.document.isReadOnlyByLineLength == true && paneLong?.textView.isEditable == false && (paneLong?.textView.string as NSString?)?.length == lengthOpen && paneLong?.statusText.contains("read-only") == true)
        AppPreferences.update(\.advanced) { $0.lineLimit = 550_000 }
        paneLong?.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        check("a higher limit makes it editable again, without the notice", paneLong?.editor.document.isReadOnlyByLineLength == false && paneLong?.textView.isEditable == true && (paneLong?.textView.string as NSString?)?.length == lengthOpen + 1 && paneLong?.statusText.contains("read-only") == false)
        settle(30) { paneLong?.isConnected == true }
        check("and it keeps its language server connection (diagnostics)", paneLong?.isConnected == true || FileManager.default.isExecutableFile(atPath: realGopls) == false)
        controller.closeTab(longFile.path, force: true)
        settings.advanced.lineLimit.selectItem(at: 0)
        settings.advanced.lineLimit.sendAction(settings.advanced.lineLimit.action, to: settings.advanced.lineLimit.target)
        controller.openFile(longFile)
        check("and a file opened now is read-only above it", controller.currentPane?.editor.document.isReadOnlyByLineLength == true)
        controller.closeTab(longFile.path, force: true)
        AppPreferences.update(\.advanced) { $0.lineLimit = 550_000 }

        // Advanced.
        settle(10) { settings.advanced.daemonStatus != nil }
        let before = settings.advanced.daemonStatus
        check("Advanced shows the daemon (\(before.map { "pid \($0.pid)" } ?? "none"))", before != nil)
        var restarted = false
        settings.advanced.restartDaemon { restarted = true }
        settle(20) { restarted }
        settings.advanced.refreshStatus()
        settle(20) { settings.advanced.daemonStatus != nil && settings.advanced.daemonStatus?.pid != before?.pid }
        check("Restart starts a fresh daemon (\(before.map { String($0.pid) } ?? "?") then \(settings.advanced.daemonStatus.map { String($0.pid) } ?? "none"))", settings.advanced.daemonStatus != nil && settings.advanced.daemonStatus?.pid != before?.pid)
        AppPreferences.update(\.general) { $0.recentLimit = 20 }
        AppPreferences.resetAll()
        check("Reset All Settings brings the defaults back", AppPreferences.general == GeneralSettings() && AppPreferences.terminal == TerminalSettings() && EditorPreferences.current == EditorSettings())
        if let snapshotPath {
            settings.showWindow(nil)
            settings.select(pane: 3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            WindowSnapshot.write(settings.window, to: snapshotPath)
        }
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-session`: session restore and changes made on disk by something else. The folder needs a.go,
    /// b.go and c.go (any Go source with a few lines).
    private func runSessionSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-session"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 10, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let a = root.appendingPathComponent("a.go"), b = root.appendingPathComponent("b.go"), c = root.appendingPathComponent("c.go")
        let originals = [a, b, c].map { (url: $0, text: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
        let original = EditorPreferences.current
        EditorPreferences.update { $0.autoSave = .off }
        selfTestCleanups.append {
            EditorPreferences.current = original
            SessionStore.clear(for: root)
            for item in originals { try? item.text.write(to: item.url, atomically: true, encoding: .utf8) }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("new.go"))
        }
        SessionStore.clear(for: root)

        // Restore: two tabs, a caret in the first, a changed layout; a second window gets it back.
        let first = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        first.showWindow(nil)
        first.openFile(a)
        first.currentPane?.reveal(line: 3, character: 2)
        first.openFile(b)
        first.setBottomPanel(hidden: true, tab: 3)
        first.selectSidebarTab(1)
        first.saveSession()
        first.window?.close()
        let second = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        second.showWindow(nil)
        second.restoreSession()
        check("a reopened project has the same tabs and the same one active (\(second.tabs.paths.map { URL(fileURLWithPath: $0).lastPathComponent }))", second.tabs.paths == [a.path, b.path] && second.tabs.active == b.path)
        let caret = second.openPane(for: a.path).map { $0.editorFile.lineIndex.position(at: $0.textView.selectedRange().location) }
        check("each tab keeps its caret (\(caret.map { "\($0.line):\($0.character)" } ?? "none"))", caret?.line == 3 && caret?.character == 2)
        check("the panel and sidebar layout come back", second.isBottomPanelHidden && second.selectedPanelTab == 3 && second.sidebarTabIndex == 1)
        second.window?.close()
        try? FileManager.default.removeItem(at: b)
        let third = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        third.showWindow(nil)
        third.restoreSession()
        check("a file deleted since is left out of the restored tabs", third.tabs.paths == [a.path] && third.tabs.active == a.path)
        try? originals[1].text.write(to: b, atomically: true, encoding: .utf8)

        // Changed on disk: a clean tab reloads, an edited one asks, a deleted one asks.
        third.openFile(c)
        let paneC = third.openPane(for: c.path)
        let newText = "package main\n\nfunc c() int {\n\treturn 2\n}\n"
        try? newText.write(to: c, atomically: true, encoding: .utf8)
        // Force a different signature even when the write lands in the same clock tick.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: c.path)
        third.checkDisk()
        check("a file nobody edited here is reloaded without asking", paneC?.textView.string == newText && paneC?.editor.noticeText == "")

        let paneA = third.openPane(for: a.path)
        third.openFile(a)
        paneA?.textView.insertText("// mine\n", replacementRange: NSRange(location: 0, length: 0))
        let mine = paneA?.textView.string ?? ""
        try? "package main\n// theirs\n".write(to: a, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(8)], ofItemAtPath: a.path)
        third.checkDisk()
        check("an edited file shows a notice with Reload and Keep Mine (\(paneA?.editor.noticeActionTitles ?? []))", paneA?.editor.noticeActionTitles == ["Reload from Disk", "Keep Mine"] && paneA?.textView.string == mine)
        paneA?.editor.pressNotice("Keep Mine")
        third.checkDisk()
        check("Keep Mine leaves the text and the notice does not come back", paneA?.textView.string == mine && paneA?.editor.noticeText == "")
        try? "package main\n// theirs again\n".write(to: a, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(11)], ofItemAtPath: a.path)
        third.checkDisk()
        paneA?.editor.pressNotice("Reload from Disk")
        check("Reload from Disk takes the file's text and clears the edit mark", paneA?.textView.string == "package main\n// theirs again\n" && paneA?.editorFile.isEdited == false)

        try? FileManager.default.removeItem(at: c)
        third.checkDisk()
        check("a deleted file shows a notice with Close Tab and Keep Open (\(paneC?.editor.noticeActionTitles ?? []))", paneC?.editor.noticeActionTitles == ["Close Tab", "Keep Open"])
        paneC?.editor.pressNotice("Close Tab")
        check("Close Tab closes it", !third.tabs.paths.contains(c.path))

        // A file created outside shows up in the explorer.
        let expected = try? "package main\n".write(to: root.appendingPathComponent("new.go"), atomically: true, encoding: .utf8)
        _ = expected
        third.checkDisk()
        check("a new file appears in the explorer", third.explorerNames.contains("new.go"))

        // The event path: an external write is noticed without calling checkDisk() or waiting for the 10 s poll.
        third.openFile(b)
        let paneB = third.openPane(for: b.path)
        third.startWatchingDisk()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let viaEvents = "package main\n// written by someone else, through events\n"
        try? viaEvents.write(to: b, atomically: true, encoding: .utf8)
        settle(5) { paneB?.textView.string == viaEvents }
        check("an external write is noticed through file-system events", paneB?.textView.string == viaEvents)
        third.stopWatchingDisk()
        third.window?.close()

        // Unsaved edits are kept aside and come back: unchanged file (Keep / Discard), then changed file (Keep Mine / Reload).
        func reopen(_ edit: String?, afterClose: () -> Void = {}) -> (ProjectWindowController, EditorPane?) {
            let window = ProjectWindowController(root: root, kind: .module, isTrusted: true)
            window.showWindow(nil)
            window.openFile(a)
            if let edit { window.openPane(for: a.path)?.textView.insertText(edit, replacementRange: NSRange(location: 0, length: 0)) }
            window.saveSession()
            window.saveRecoveries()
            window.window?.close()
            afterClose()
            let next = ProjectWindowController(root: root, kind: .module, isTrusted: true)
            next.showWindow(nil)
            next.restoreSession()
            return (next, next.openPane(for: a.path))
        }
        let diskA = (try? String(contentsOf: a, encoding: .utf8)) ?? ""
        let (fourth, paneKeep) = reopen("// unsaved\n")
        check("kept edits come back marked as edited (\(paneKeep?.editor.noticeText ?? ""))", paneKeep?.textView.string == "// unsaved\n" + diskA && paneKeep?.editorFile.isEdited == true && fourth.isDirty(a))
        check("with a Keep / Discard notice", paneKeep?.editor.noticeActionTitles == ["Keep", "Discard"])
        paneKeep?.editor.pressNotice("Discard")
        check("Discard goes back to the disk text and deletes the kept buffer", paneKeep?.textView.string == diskA && paneKeep?.editorFile.isEdited == false && RecoveryStore.load(root: root, path: a.path) == nil)
        fourth.window?.close()
        let (fifth, paneChanged) = reopen("// unsaved two\n") {
            try? "package main\n// changed meanwhile\n".write(to: a, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: a.path)
        }
        check("a file changed on disk since offers Keep Mine / Reload from Disk (\(paneChanged?.editor.noticeText ?? ""))", paneChanged?.editor.noticeActionTitles == ["Keep Mine", "Reload from Disk"] && paneChanged?.textView.string.hasPrefix("// unsaved two\n") == true)
        paneChanged?.editor.pressNotice("Keep Mine")
        check("Keep Mine keeps the text edited and the buffer file", paneChanged?.editorFile.isEdited == true && paneChanged?.editor.noticeText == "" && RecoveryStore.load(root: root, path: a.path) != nil)
        paneChanged?.save()
        check("saving deletes the kept buffer", RecoveryStore.load(root: root, path: a.path) == nil)
        fifth.window?.close()

        // Edited buffers are also written on a timer (crash safety), and only when their text changed since the last write.
        ProjectWindowController.recoveryInterval = 0.3
        selfTestCleanups.append { ProjectWindowController.recoveryInterval = 20; RecoveryStore.clear(root: root) }
        RecoveryStore.clear(root: root)
        let sixth = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        sixth.showWindow(nil)
        sixth.openFile(a)
        let paneTimed = sixth.openPane(for: a.path)
        paneTimed?.textView.insertText("// periodic\n", replacementRange: NSRange(location: 0, length: 0))
        check("no buffer is written before the timer runs", RecoveryStore.load(root: root, path: a.path) == nil)
        sixth.startWatchingDisk()
        settle(5) { RecoveryStore.load(root: root, path: a.path) != nil }
        check("an edited tab is written by the timer", RecoveryStore.load(root: root, path: a.path)?.text == paneTimed?.textView.string && paneTimed?.textView.string.hasPrefix("// periodic\n") == true)
        RecoveryStore.delete(root: root, path: a.path)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        check("an unchanged buffer is not written again", RecoveryStore.load(root: root, path: a.path) == nil)
        paneTimed?.textView.insertText("// more\n", replacementRange: NSRange(location: 0, length: 0))
        settle(5) { RecoveryStore.load(root: root, path: a.path) != nil }
        check("a changed buffer is written again", RecoveryStore.load(root: root, path: a.path)?.text.hasPrefix("// more\n// periodic\n") == true)
        paneTimed?.save()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        check("saving deletes it and the timer does not bring it back", RecoveryStore.load(root: root, path: a.path) == nil)
        sixth.stopWatchingDisk()
        sixth.window?.close()
        RecoveryStore.clear(root: root)
        fifth.window?.close()
        runSessionSafetyChecks(root: root, first: a, second: b, check: check, addCleanup: { selfTestCleanups.append($0) })
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-find`: Find and Replace in Files. The folder needs closed.go and open.go with the word `sum` on
    /// several lines each (open.go is opened in the editor by the test), and sub/deep.go with one.
    private func runFindSelfTest() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) else { print("usage: GobiApp FOLDER --selftest-find"); exit(2) }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 30, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)
        let original = EditorPreferences.current
        EditorPreferences.update { $0.autoSave = .off }
        selfTestCleanups.append { EditorPreferences.current = original }
        let savedHistory = UserDefaults.standard.stringArray(forKey: ProjectWindowController.findHistoryKey)
        selfTestCleanups.append { if let savedHistory { UserDefaults.standard.set(savedHistory, forKey: ProjectWindowController.findHistoryKey) } else { UserDefaults.standard.removeObject(forKey: ProjectWindowController.findHistoryKey) } }
        UserDefaults.standard.removeObject(forKey: ProjectWindowController.findHistoryKey)
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.openFile(root.appendingPathComponent("open.go"))
        controller.findInFiles()
        controller.setSearch("sum")
        controller.runSearch()
        settle { controller.findResultCount > 0 }
        check("a search lists the files that have the word (\(controller.findResultPaths), \(controller.findSummary))", controller.findResultPaths == ["closed.go", "open.go", "sub/deep.go"] && controller.findResultCount == 7)
        controller.setSearch("sum", include: "*.go")
        controller.runSearch()
        settle { controller.findSummary.contains("7 results") }
        controller.setSearch("SUM", regex: false)
        controller.runSearch()
        settle { controller.findResultCount == 7 }
        check("the search ignores case by default", controller.findResultCount == 7)
        controller.setSearch("total", include: "sub/*")
        controller.runSearch()
        settle { controller.findSummary == "No results" }
        check("a file filter narrows the search (no results for \"total\" in sub/)", controller.findSummary == "No results")

        check("the query field remembers the searches, newest first (\(controller.findHistory))", controller.findHistory == ["total", "SUM", "sum"])

        // Replace: closed.go on disk, open.go in the editor.
        controller.setSearch("sum", replacement: "total")
        controller.runSearch()
        settle { controller.findResultCount == 7 && controller.findHits.first?.replacement == "total" }
        let closedBefore = (try? String(contentsOf: root.appendingPathComponent("closed.go"), encoding: .utf8)) ?? ""
        let openText = controller.currentPane?.textView.string ?? ""
        selfTestCleanups.append { try? closedBefore.write(to: root.appendingPathComponent("closed.go"), atomically: true, encoding: .utf8) }
        let deepBefore = (try? String(contentsOf: root.appendingPathComponent("sub/deep.go"), encoding: .utf8)) ?? ""
        selfTestCleanups.append { try? deepBefore.write(to: root.appendingPathComponent("sub/deep.go"), atomically: true, encoding: .utf8) }
        // One match only: the first hit in closed.go.
        if let one = controller.findHits.first(where: { $0.path == "closed.go" }) {
            controller.replace(hits: [one], exact: true)
            settle(30) { controller.findSummary.hasPrefix("Replaced") }
            let onceText = (try? String(contentsOf: root.appendingPathComponent("closed.go"), encoding: .utf8)) ?? ""
            check("Replace on one match changes only that match (\(controller.findSummary))", controller.findSummary.hasPrefix("Replaced 1 in 1 file") && onceText == closedBefore.replacingOccurrences(of: "sum", with: "total", options: [], range: closedBefore.range(of: "sum")))
            try? closedBefore.write(to: root.appendingPathComponent("closed.go"), atomically: true, encoding: .utf8)
        }
        // A file left out of Replace All stays as it was.
        controller.runSearch()
        settle { controller.findResultCount == 7 && controller.findHits.first?.replacement == "total" }
        controller.setFindIncluded("closed.go", false)
        check("an excluded file's hits are not part of Replace All", !controller.findIncludedHits.contains { $0.path == "closed.go" } && controller.findIncludedHits.count < controller.findHits.count)
        controller.replace(hits: controller.findIncludedHits)
        settle(30) { controller.findSummary.hasPrefix("Replaced") }
        let closedExcluded = (try? String(contentsOf: root.appendingPathComponent("closed.go"), encoding: .utf8)) ?? ""
        check("Replace All skips the excluded file (\(controller.findSummary))", closedExcluded == closedBefore && controller.currentPane?.textView.string != openText)
        controller.currentPane?.textView.undoManager?.undo()
        try? deepBefore.write(to: root.appendingPathComponent("sub/deep.go"), atomically: true, encoding: .utf8)
        controller.setFindIncluded("closed.go", true)
        controller.runSearch()
        settle { controller.findResultCount == 7 && controller.findHits.first?.replacement == "total" }
        controller.replace(hits: controller.findIncludedHits)
        settle(30) { controller.findSummary.hasPrefix("Replaced") }
        let closedAfter = (try? String(contentsOf: root.appendingPathComponent("closed.go"), encoding: .utf8)) ?? ""
        check("Replace All rewrites a file that is not open (\(controller.findSummary))", closedAfter == closedBefore.replacingOccurrences(of: "sum", with: "total") && !closedAfter.contains("sum"))
        let openAfter = controller.currentPane?.textView.string ?? ""
        check("and changes an open file in the editor, leaving it unsaved", openAfter == openText.replacingOccurrences(of: "sum", with: "total") && controller.isDirty(root.appendingPathComponent("open.go")))
        controller.currentPane?.textView.undoManager?.undo()
        check("one undo takes the whole replacement back", controller.currentPane?.textView.string == openText)
        selfTestExit(failures)
    }

    /// `GobiApp --selftest-setup`: the Setup window against the real gobid (read-only: nothing is installed).
    private func runSetupSelfTest() {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        let window = SetupWindowController()
        window.reload()
        let deadline = Date().addingTimeInterval(20)
        while window.tools.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        check("gobid reports go, gopls, dlv and git (\(window.tools.map(\.name)))", Set(window.tools.map(\.name)) == ["go", "gopls", "dlv", "git"])
        check("go is found on this machine", window.tools.first { $0.name == "go" }?.found == true)
        window.show([ToolStatus(name: "go", required: true, found: true, version: "go1.26.5"), ToolStatus(name: "gopls", required: true, found: false, installable: true),
                     ToolStatus(name: "dlv", required: false, found: false, installable: true), ToolStatus(name: "git", required: false, found: false, hint: "xcode-select --install")])
        check("Install is offered for the missing tools go install can fetch, not for git", window.installButtonTools == ["gopls", "dlv"] && window.installAllEnabled)
        window.show([ToolStatus(name: "go", required: true, found: true), ToolStatus(name: "gopls", required: true, found: true)])
        check("with everything installed there is nothing to install", !window.installAllEnabled && window.statusText == "Everything is installed.")

        // Logging: the start line is in gobi.log under GOBI_LOG_DIR, the daemon wrote its own private log, and Copy Diagnostics has no full path.
        let appLogText = (try? String(contentsOfFile: AppLog.path, encoding: .utf8)) ?? ""
        check("gobi.log has the start line with the version", appLogText.contains("Gobi starting: version \(AppInfo.version)"))
        let daemonLogMode = (try? FileManager.default.attributesOfItem(atPath: AppLog.daemonLogPath)[.posixPermissions] as? Int) ?? 0
        check("gobid wrote gobid.log with mode 0600 (\(String(daemonLogMode, radix: 8)))", daemonLogMode == 0o600)
        let diagnostics = LogSupport.diagnosticsText()
        check("Copy Diagnostics has the version, gobid and the log sections", diagnostics.contains("Gobi \(AppInfo.version)") && diagnostics.contains("gobid ") && diagnostics.contains("--- gobi.log") && diagnostics.contains("Gobi starting"))
        check("Copy Diagnostics has no full path", !diagnostics.contains(NSHomeDirectory()) && !diagnostics.contains(AppLog.directory) && !diagnostics.contains("/private/") && !diagnostics.contains("/usr/"))
        check("a self-test leaves no running marker", !AppLog.markerExists)
        selfTestExit(failures)
    }

    /// `GobiApp --selftest-crash`: a child process (this executable) installs the crash handlers and raises SIGABRT; its log must
    /// hold the FATAL line and it must still die by that signal. macOS may write a crash report for the child.
    private func runCrashSelfTest() {
        let childDirectory = AppLog.directory + "/crash-child"
        try? FileManager.default.removeItem(atPath: childDirectory)
        selfTestCleanups.append { try? FileManager.default.removeItem(atPath: childDirectory) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--selftest-crash-child"]
        child.environment = ProcessInfo.processInfo.environment.merging(["GOBI_LOG_DIR": childDirectory]) { $1 }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        try? child.run()
        child.waitUntilExit()
        let childLog = (try? String(contentsOfFile: childDirectory + "/gobi.log", encoding: .utf8)) ?? ""
        check("the child died by SIGABRT, so the default crash path still runs (\(child.terminationReason == .uncaughtSignal ? "signal" : "exit") \(child.terminationStatus))", child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGABRT)
        check("its log holds the FATAL line (\(childLog.split(separator: "\n").last.map(String.init) ?? "empty"))", childLog.contains("FATAL signal 6 Gobi crashtest"))
        selfTestExit(failures)
    }

    /// `GobiApp FOLDER --selftest-run`: Run, Run Tests, Run Test at Cursor, Run Failed and Stop against the real `go`. The folder
    /// needs main.go (prints "hello from main") and main_test.go with TestOK, TestBad (fails) and TestSkipped; `--slow FOLDER2`
    /// names a program that prints "started" and then sleeps, for Stop.
    private func runRunSelfTest() {
        let arguments = CommandLine.arguments
        guard let path = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else { print("usage: GobiApp FOLDER --selftest-run [--slow FOLDER2]"); exit(2) }
        let slowPath = arguments.firstIndex(of: "--slow").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 90, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let root = URL(fileURLWithPath: path)

        let restricted = ProjectWindowController(root: root, kind: .module, isTrusted: false)
        restricted.showWindow(nil)
        restricted.runTests()
        check("an untrusted project does not run code (\(restricted.runStateText))", restricted.runStateText.contains("Restricted") && !restricted.isRunning)

        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.showWindow(nil)
        controller.runTests()
        settle { !controller.isRunning && controller.testCounts.passed + controller.testCounts.failed + controller.testCounts.skipped > 0 }
        settle(5) { false }
        check("Run Tests counts one passed, one failed, one skipped (\(controller.testCounts))", controller.testCounts == (1, 1, 1))
        check("it opens the Tests tab and lists the tests (\(controller.testRowTitles))", controller.selectedPanelTab == 1 && ["TestOK", "TestBad", "TestSkipped"].allSatisfy(controller.testRowTitles.contains))
        check("the failure's message shows under the failed test", controller.testFailureLines.contains { $0.contains("broken on purpose") })
        controller.testFilterText = "testbad"
        check("the filter box narrows the tree to the matching test and its package (\(controller.testRowTitles))", controller.testRowTitles.count == 2 && controller.testRowTitles.last == "TestBad" && controller.testFailureLines.contains { $0.contains("broken on purpose") })
        controller.testFilterText = "nosuchtest"
        check("a filter that matches nothing leaves no rows", controller.testRowTitles.isEmpty)
        controller.testFilterText = ""
        check("clearing the filter brings every test back", ["TestOK", "TestBad", "TestSkipped"].allSatisfy(controller.testRowTitles.contains))
        if let snapshotPath { controller.snapshotWindow(to: snapshotPath) }
        check("Run Failed is available", controller.isRunFailedEnabled)
        check("the Output panel holds the transcript and the exit state (\(controller.runStateText))", controller.runOutputText.contains("broken on purpose") && controller.runStateText == "exit 1")

        // Mentions of file.go:line in the output are links; a failed test row opens the line that failed.
        check("the failure's file:line in the Output is a link (\(controller.runOutputLinks))", controller.runOutputLinks.contains { $0.hasPrefix("main_test.go:") })
        controller.openFile(root.appendingPathComponent("main.go"))
        if let range = controller.runOutputText.range(of: "main_test.go:") { controller.clickRunOutputLink(at: controller.runOutputText.distance(from: controller.runOutputText.startIndex, to: range.lowerBound)) }
        check("clicking it opens that file at that line (\(controller.currentFileName ?? "none") \(controller.currentCaretLine ?? -1))", controller.currentFileName == "main_test.go" && controller.currentCaretLine == 8)
        controller.openFile(root.appendingPathComponent("main.go"))
        controller.selectTestRow(titled: "TestBad")
        check("picking the failed test in the Tests tab opens the failing line", controller.currentFileName == "main_test.go" && controller.currentCaretLine == 8)

        controller.rerunFailed()
        settle { !controller.isRunning && controller.testCounts.failed + controller.testCounts.passed > 0 }
        settle(3) { false }
        check("Run Failed runs only the failed test (\(controller.testCounts))", controller.testCounts == (0, 1, 0))

        // The gutter's Run button on a test function runs just that test.
        controller.openFile(root.appendingPathComponent("main_test.go"))
        let testPane = controller.currentPane
        check("test functions get a Run button in the gutter (\(testPane?.editor.runnableLines.sorted() ?? []))", testPane?.editor.runnableLines == [5, 9, 11])
        testPane?.editor.clickRunButton(line: 5)
        settle { !controller.isRunning && controller.testCounts == (1, 0, 0) }
        check("clicking it runs only that test (\(controller.testCounts))", controller.testCounts == (1, 0, 0))

        controller.openFile(root.appendingPathComponent("main_test.go"))
        if let pane = controller.currentPane {
            let text = pane.textView.string as NSString
            pane.textView.setSelectedRange(NSRange(location: text.range(of: "func TestOK").location + 5, length: 0))
        }
        controller.runTestAtCursor()
        settle { !controller.isRunning && controller.testCounts.passed > 0 }
        settle(3) { false }
        check("Run Test at Cursor runs only that test (\(controller.testCounts), \(controller.runCommandText))", controller.testCounts == (1, 0, 0) && controller.runCommandText.contains("-run ^TestOK$"))

        controller.openFile(root.appendingPathComponent("main.go"))
        controller.runProject()
        settle { !controller.isRunning && controller.runOutputText.contains("hello from main") }
        settle(3) { false }
        check("Run runs the open main package and shows its output (\(controller.runCommandText))", controller.runOutputText.contains("hello from main") && controller.selectedPanelTab == 6 && controller.runStateText == "exit 0")

        // Build menu: go build through the run channel, output in the Output tab.
        controller.buildProject()
        settle { !controller.isRunning && controller.runStateText.hasPrefix("exit") }
        check("Build Project runs go build ./... and ends with exit 0 (\(controller.runCommandText), \(controller.runStateText))", controller.runCommandText == "go build ./..." && controller.runStateText == "exit 0" && controller.selectedPanelTab == 6)
        controller.openFile(root.appendingPathComponent("main.go"))
        controller.buildModule()
        settle { !controller.isRunning && controller.runCommandText.hasPrefix("go build .") }
        settle(3) { false }
        check("Build Module builds the package of the open file (\(controller.runCommandText), \(controller.runStateText))", controller.runCommandText == "go build ." && controller.runStateText == "exit 0")
        controller.rebuildProject()
        settle { !controller.isRunning && controller.runCommandText == "go build -a ./..." }
        settle(60) { controller.runStateText == "exit 0" }
        check("Rebuild Project forces a full build with -a (\(controller.runCommandText), \(controller.runStateText))", controller.runCommandText == "go build -a ./..." && controller.runStateText == "exit 0")

        if let slowPath {
            let slow = ProjectWindowController(root: URL(fileURLWithPath: slowPath), kind: .module, isTrusted: true)
            slow.showWindow(nil)
            slow.openFile(URL(fileURLWithPath: slowPath).appendingPathComponent("main.go"))
            slow.runProject()
            settle(60) { slow.runOutputText.contains("started") }
            check("a long run streams its output while it runs", slow.isRunning && slow.runOutputText.contains("started"))
            slow.stopEverything()
            settle(30) { !slow.isRunning }
            check("Stop ends it (\(slow.runStateText))", !slow.isRunning)
        }
        if let nomodPath = arguments.firstIndex(of: "--nomod").flatMap({ $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }) {
            let bare = URL(fileURLWithPath: nomodPath)
            let noticeKey = GoModule.noticeKey(project: bare.path)
            UserDefaults.standard.removeObject(forKey: noticeKey)
            selfTestCleanups.append { UserDefaults.standard.removeObject(forKey: noticeKey) }
            let plain = FileManager.default
            check("the fixture has no go.mod", !plain.fileExists(atPath: bare.appendingPathComponent("go.mod").path))
            let restrictedBare = ProjectWindowController(root: bare, kind: .folder, isTrusted: false)
            restrictedBare.showWindow(nil)
            restrictedBare.openFile(bare.appendingPathComponent("main.go"))
            check("Restricted Mode shows the notice text without a Create button", restrictedBare.currentPane?.editor.noticeText.contains("no go.mod") == true && restrictedBare.currentPane?.editor.noticeActionTitles == ["Not Now"])
            let bareWindow = ProjectWindowController(root: bare, kind: .folder, isTrusted: true)
            bareWindow.showWindow(nil)
            bareWindow.openFile(bare.appendingPathComponent("main.go"))
            bareWindow.runProject()
            settle { !bareWindow.isRunning && bareWindow.runStateText.hasPrefix("exit") }
            settle(2) { false }
            check("Run without a go.mod runs the file (\(bareWindow.runCommandText), \(bareWindow.runStateText))", bareWindow.runCommandText == "go run main.go" && bareWindow.runStateText == "exit 0" && bareWindow.runOutputText.contains("hello from main"))
            check("the notice shows with its two buttons", bareWindow.currentPane?.editor.noticeActionTitles == ["Create go.mod", "Not Now"])
            bareWindow.createGoMod()
            let written = (try? String(contentsOf: bare.appendingPathComponent("go.mod"), encoding: .utf8)) ?? ""
            check("Create go.mod writes a valid go.mod (\(written.replacingOccurrences(of: "\n", with: "|")))", written.hasPrefix("module ") && written.contains("\n\ngo 1.") && written.hasSuffix("\n"))
            check("the notice is gone and the explorer lists go.mod", bareWindow.currentPane?.editor.noticeText.isEmpty == true && bareWindow.explorerNames.contains("go.mod"))
            check("the inspector shows the module (\(bareWindow.inspectorModuleText))", bareWindow.inspectorModuleText.contains { $0.contains(GoModule.moduleName(fromFolder: bare.lastPathComponent)) })
            settle(60) { bareWindow.currentPane?.isConnected == true }
            check("gopls reconnects for the open Go file", bareWindow.currentPane?.isConnected == true)
            bareWindow.runProject()
            settle { !bareWindow.isRunning && bareWindow.runStateText.hasPrefix("exit") }
            settle(2) { false }
            check("go run . works afterwards (\(bareWindow.runCommandText), \(bareWindow.runStateText))", bareWindow.runCommandText == "go run ." && bareWindow.runStateText == "exit 0")
            let package = bareWindow.newGoPackage(in: bare, name: "pkg")
            check("New > Go Package makes pkg/pkg.go", package?.lastPathComponent == "pkg.go" && (try? String(contentsOf: bare.appendingPathComponent("pkg/pkg.go"), encoding: .utf8)) == "package pkg\n" && bareWindow.currentFileName == "pkg.go")
            check("a Go package name that exists or is not an identifier is refused", bareWindow.newGoPackage(in: bare, name: "pkg") == nil && bareWindow.newGoPackage(in: bare, name: "my-pkg") == nil)
        }
        selfTestExit(failures)
    }

    func showWelcome() {
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
    func openProject(_ root: URL, askAboutTrust: Bool = true) -> Bool {
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
        if !selfTest {
            controller.persistsSession = true
            controller.restoreSession()
            controller.startWatchingDisk()
        }
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
        check("the menu bar has the mock's menus (\(titles.joined(separator: ", ")))", titles == ["Gobi", "File", "Edit", "View", "Go", "Build", "Run", "Git", "Window", "Help"])
        // Live items of the new menus are wired: each has an action and its id, and the not-built ones stay disabled.
        func menuItem(_ menuTitle: String, _ itemTitle: String) -> NSMenuItem? { NSApp.mainMenu?.items.compactMap { $0.submenu }.first { $0.title == menuTitle }?.items.first { $0.title == itemTitle } }
        let wired = [("Git", "Commit…"), ("Git", "Push…"), ("Git", "Rebase…"), ("Git", "New Tag…"), ("Build", "Build Project"), ("Build", "Rebuild Project"), ("Run", "Debug"), ("Run", "Stop"), ("Run", "Attach to Process…"),
                     ("Run", "Resume Program"), ("Run", "View Breakpoints…"), ("Help", "Open Logs Folder"), ("Help", "Copy Diagnostics"), ("Edit", "Sort Lines"), ("Edit", "Paste as Plain Text"), ("Edit", "Start Dictation…"), ("View", "Reset Font Size in All Editors"), ("Window", "Next Project Window")]
        let unwired = wired.filter { menuItem($0.0, $0.1)?.action == nil }.map { "\($0.0) ▸ \($0.1)" }
        check("the new menu items have actions (missing: \(unwired))", unwired.isEmpty)
        let disabled = [("Edit", "Column Selection Mode"), ("View", "Notifications"), ("View", "Quick Definition"), ("Build", "Build Artifacts"), ("Run", "Run with Coverage")]
        let stillEnabled = disabled.filter { menuItem($0.0, $0.1)?.action != nil }.map { "\($0.0) ▸ \($0.1)" }
        check("the items without a feature behind them have no action (\(stillEnabled))", stillEnabled.isEmpty)
        check("Run has no separate Debug menu and Git has the Patch, Uncommitted Changes and Current File submenus", menuItem("Git", "Patch")?.submenu?.items.count == 2 && menuItem("Git", "Uncommitted Changes")?.submenu?.items.count == 3 && menuItem("Git", "Current File")?.submenu?.items.count == 5)
        let recentFilesMenu = menuItem("View", "Recent Files")?.submenu
        recentFilesMenu.map { menuNeedsUpdate($0) }
        check("View > Recent Files lists the open file or says there are none", recentFilesMenu?.items.isEmpty == false)
        // Every live item with a shortcut in the spec has the matching key equivalent in the real menu bar.
        var mismatches: [String] = []
        for definition in MenuSpec.all {
            guard let menu = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { $0.title == (definition.title == "Gobi" ? "Gobi" : definition.title) }) else { continue }
            var seen = Set<String>()
            for entry in definition.entries where !entry.isSeparator && entry.action != nil && !entry.shortcut.isEmpty {
                if entry.action == "fullScreen" { continue }
                // Start Debugging and Continue share F5; the menu gives the key to the first and the app picks by state.
                if !seen.insert(entry.shortcut).inserted { continue }   // macOS assigns the system full-screen key itself
                guard let item = menu.items.first(where: { $0.title == entry.title }), let want = MainMenuBuilder.keyEquivalent(for: entry.shortcut) else { mismatches.append(entry.title); continue }
                if item.keyEquivalent != want.key || item.keyEquivalentModifierMask != want.modifiers { mismatches.append("\(entry.title) has \(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue), wants \(want.key.debugDescription) \(want.modifiers.rawValue)") }
            }
        }
        check("every live menu item has its shortcut (mismatches: \(mismatches))", mismatches.isEmpty)
        let recentMenu = NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.title == "Open Recent" }?.submenu
        recentMenu.map { menuNeedsUpdate($0) }
        check("Open Recent lists this project first (\(recentMenu?.items.prefix(3).map(\.title) ?? []))", recentMenu?.items.first?.title.hasPrefix(controller.root.lastPathComponent) == true)   // a second project with the same folder name makes the menu add its location
        check("Open Recent ends with Clear Menu", recentMenu?.items.last?.title == "Clear Menu")
        check("the status bar shows the project, not a stale line (\(controller.statusBarTexts.filter { !$0.isEmpty }))", controller.statusBarTexts.contains { $0.hasPrefix("gopls") })
        check("the bottom panel has the mock's eight tabs", controller.panelTabTitles.count == 8 && controller.panelTabTitles.last == "Find")
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
            // Edit > Sort Lines, Reverse Lines and Paste as Plain Text act on the editor as single, undoable edits.
            if let pane = controller.currentPane, !pane.editor.document.isReadOnlyByLineLength {
                let original = pane.textView.string
                let unsorted = "pear\napple\nfig\n"
                let undoer = pane.textView.undoManager
                undoer?.groupsByEvent = false   // the menu actions are separate events in the app; here each step is its own group
                func step<Value>(_ work: () -> Value) -> Value {
                    undoer?.beginUndoGrouping()
                    defer { undoer?.endUndoGrouping() }
                    return work()
                }
                step { pane.textView.insertText(unsorted, replacementRange: NSRange(location: 0, length: 0)) }
                pane.textView.setSelectedRange(NSRange(location: 0, length: (unsorted as NSString).length))
                let sorted = step { controller.reorderSelectedLines(LineOrder.sorted) }
                check("Sort Lines orders the selected lines (\(pane.textView.string.prefix(20)))", sorted && pane.textView.string.hasPrefix("apple\nfig\npear\n"))
                check("and the selection still covers them", pane.textView.selectedRange().length == (unsorted as NSString).length)
                let reversed = step { controller.reorderSelectedLines(LineOrder.reversed) }
                check("Reverse Lines flips them", reversed && pane.textView.string.hasPrefix("pear\nfig\napple\n"))
                undoer?.undo()
                check("one undo takes back one Reverse Lines (\(pane.textView.string.prefix(20)))", pane.textView.string.hasPrefix("apple\nfig\npear\n"))
                pane.textView.setSelectedRange(NSRange(location: 0, length: 0))
                check("Sort Lines needs a selection", !controller.reorderSelectedLines(LineOrder.sorted))
                let pasteboard = NSPasteboard.general
                let savedClipboard = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                pasteboard.setString("PLAIN", forType: .string)
                pane.textView.setSelectedRange(NSRange(location: 0, length: 0))
                let pasted = step { controller.pastePlainText() }
                check("Paste as Plain Text inserts the pasteboard text", pasted && pane.textView.string.hasPrefix("PLAINapple"))
                pasteboard.clearContents()
                if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }
                undoer?.removeAllActions()
                undoer?.groupsByEvent = true
                pane.textView.string = original
                pane.editor.document.isEdited = false
            }
            check("Recent Files remembers the opened file", controller.recentFiles.contains(url.path))
            controller.forgetRecentFiles()
            check("and Clear Menu forgets it", controller.recentFiles.isEmpty)
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
        selfTestExit(failures)
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
        if menu.title == "Go Toolchain" || menu.title == "Environment" {
            menu.removeAllItems()
            let live = menu.title == "Environment" ? frontProject?.environmentMenu() : frontProject?.toolchainMenu()
            for item in live?.items ?? [] { live?.removeItem(item); menu.addItem(item) }
            if live == nil { menu.addItem(withTitle: "No Project Open", action: nil, keyEquivalent: "").isEnabled = false }
            return
        }
        if menu.title == "Recent Files" { fillRecentFiles(menu); return }
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let entries = ProjectStore.shared.recents.menuItems(limit: AppPreferences.general.recentLimit)
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

    var frontProject: ProjectWindowController? { NSApp.keyWindow?.windowController as? ProjectWindowController }

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

    @objc func runProject(_ sender: Any?) { frontProject?.runProject() }
    @objc func runTests(_ sender: Any?) { frontProject?.runTests() }
    @objc func runTestAtCursor(_ sender: Any?) { frontProject?.runTestAtCursor() }

    @objc func goToFile(_ sender: Any?) { frontProject?.goToFile() }
    @objc func goToWorkspaceSymbol(_ sender: Any?) { frontProject?.goToWorkspaceSymbol() }
    @objc func goToFileSymbol(_ sender: Any?) { frontProject?.goToFileSymbol() }
    @objc func commandPalette(_ sender: Any?) { frontProject?.commandPalette { [weak self] action in if let self { MainMenuBuilder.perform(action: action, delegate: self) } } }

    @objc func findReferences(_ sender: Any?) { frontProject?.findReferences() }
    @objc func renameSymbol(_ sender: Any?) { frontProject?.renameSymbol() }
    @objc func organizeImports(_ sender: Any?) { frontProject?.organizeImports() }
    @objc func codeActions(_ sender: Any?) { frontProject?.showCodeActions() }
    @objc func parameterInfo(_ sender: Any?) { frontProject?.showParameterInfo() }

    /// About Gobi: the standard panel with the version, build number and commit of this build (and of the gobid it carries).
    @objc func showAbout(_ sender: Any?) {
        let detail = AppVersion.display(version: GobiClientVersion.current, build: GobiClientVersion.build, commit: GobiClientVersion.commit)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: GobiClientVersion.current,
            .version: detail,
            .credits: NSAttributedString(string: "An alpha release of a Go IDE for macOS.\nSee the CHANGELOG for what changed.", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func goToDefinition(_ sender: Any?) { frontProject?.goToDefinition() }
    @objc func goToImplementation(_ sender: Any?) { frontProject?.goToImplementation() }
    @objc func formatDocument(_ sender: Any?) { frontProject?.formatDocument() }
    @objc func closeProject(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }
    @objc func saveAll(_ sender: Any?) { frontProject?.saveAll() }
    @objc func toggleSidebar(_ sender: Any?) { frontProject?.toggleSidebar() }
    @objc func debugStart(_ sender: Any?) { frontProject?.startDebugging() }
    @objc func debugStop(_ sender: Any?) { frontProject?.debugAction("stop") }
    @objc func debugRestart(_ sender: Any?) { frontProject?.debugAction("restart") }
    @objc func debugContinue(_ sender: Any?) { frontProject?.debugAction("continue") }
    @objc func debugStepOver(_ sender: Any?) { frontProject?.debugAction("over") }
    @objc func debugStepInto(_ sender: Any?) { frontProject?.debugAction("into") }
    @objc func debugStepOut(_ sender: Any?) { frontProject?.debugAction("out") }
    @objc func findInFiles(_ sender: Any?) { frontProject?.findInFiles() }
    @objc func newTerminal(_ sender: Any?) { frontProject?.openNewTerminal() }
    @objc func profile(_ sender: Any?) { frontProject?.showProfiler() }
    @objc func debugConditional(_ sender: Any?) { frontProject?.addConditionalBreakpoint() }
    @objc func debugAttach(_ sender: Any?) { frontProject?.attachToProcess() }
    @objc func debugGoroutines(_ sender: Any?) { frontProject?.showGoroutines() }
    @objc func toggleBreakpoint(_ sender: Any?) { frontProject?.toggleBreakpointAtCaret() }

    /// Debug menu items follow the debugger: stepping only while paused, Stop and Restart while a session runs.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state = frontProject?.debugState ?? .idle
        if let id = item.identifier?.rawValue, let enabled = MenuAvailability.isEnabled(id, in: menuContext) { return enabled }
        switch item.action {
        case #selector(debugStart(_:)): return frontProject != nil && !state.isActive
        case #selector(debugStop(_:)), #selector(debugRestart(_:)): return state.isActive
        case #selector(debugContinue(_:)), #selector(debugStepOver(_:)), #selector(debugStepInto(_:)), #selector(debugStepOut(_:)): return state.canStep
        case #selector(toggleBreakpoint(_:)), #selector(debugConditional(_:)): return frontProject?.currentPane != nil
        case #selector(debugAttach(_:)): return frontProject != nil && !state.isActive
        default: return true
        }
    }

    private var environmentsWindow: EnvironmentsWindowController?
    @objc func showEnvironments(_ sender: Any?) {
        guard let project = frontProject else { return }
        let controller = EnvironmentsWindowController(store: project.environments)
        controller.onSaved = { [weak project] in project?.reloadEnvironments() }
        environmentsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private var multiVersionWindow: MultiVersionWindowController?
    @objc func runMultiVersion(_ sender: Any?) {
        guard let project = frontProject else { return }
        let controller = MultiVersionWindowController(project: project)
        multiVersionWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private var setupWindow: SetupWindowController?
    @objc func openLogsFolder(_ sender: Any?) { LogSupport.revealLogs() }
    @objc func copyDiagnostics(_ sender: Any?) { LogSupport.copyDiagnostics() }

    /// Non-modal: a notice with Reveal Logs above the open editor, else a status-bar note. Welcome-only sessions have neither.
    private func showCrashNotice() {
        let text = "Gobi did not exit cleanly last time. The logs may say why."
        if let pane = frontProject?.currentPane {
            pane.editor.showNotice(text, style: .warning, actions: [NoticeAction(title: "Reveal Logs") { LogSupport.revealLogs() }])
        } else {
            frontProject?.showNote(text + " Help > Open Logs Folder.")
        }
    }

    @objc func showSetup(_ sender: Any?) {
        let controller = setupWindow ?? SetupWindowController()
        setupWindow = controller
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// At launch: if go or gopls is missing, open the Setup window so the user knows why things do not work.
    private func checkSetupAtLaunch() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let tools = try? ControlClient.connect().toolsCheck() else { AppLog.shared.logWarn("could not ask gobid which tools are installed"); return }
            for tool in ToolStatus.missing(tools) { AppLog.shared.logWarn("\(tool.name) not found\(tool.required ? " (required)" : "")") }
            guard ToolStatus.needsAttention(tools) else { return }
            DispatchQueue.main.async { self?.showSetup(nil) }
        }
    }

    private var toolchainsWindow: ToolchainsWindowController?
    @objc func showToolchains(_ sender: Any?) {
        let controller = toolchainsWindow ?? ToolchainsWindowController()
        toolchainsWindow = controller
        controller.project = frontProject
        controller.reload(projectRoot: frontProject?.root)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private var settingsWindow: SettingsWindowController?
    @objc func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        controller.sync()
        controller.advanced.onCheckSetup = { [weak self] in self?.showSetup(nil) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showGitSettings(_ sender: Any?) {
        showSettings(sender)
        settingsWindow?.select(pane: 5)
    }
    @objc func toggleInspector(_ sender: Any?) { frontProject?.toggleInspector() }
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
