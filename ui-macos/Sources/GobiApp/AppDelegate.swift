import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [EditorWindowController] = []

    private let selfTest = CommandLine.arguments.contains("--selftest")
    private let snapshotPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        // Paths on the command line reach us through application(_:openFile:), which AppKit calls for each one.
        if controllers.isEmpty && !selfTest { openDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // AppKit also offers option values that look like paths (the --snapshot target); those are not documents.
        if filename == snapshotPath { return true }
        return open(URL(fileURLWithPath: filename), selfTest: selfTest, snapshotPath: snapshotPath)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            if controllers.isEmpty { NSApp.terminate(nil) }
            return
        }
        open(url, selfTest: false, snapshotPath: nil)
    }

    @discardableResult
    private func open(_ url: URL, selfTest: Bool, snapshotPath: String?) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if selfTest {
                print("cannot read \(url.path)")   // a modal alert would hang a scripted run
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
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
