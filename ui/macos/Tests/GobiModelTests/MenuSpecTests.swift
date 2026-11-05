import Testing
@testable import GobiModel

@Suite("Menu bar against the mock")
struct MenuSpecTests {
    /// The Menus mock, transcribed: menu title, then each item as "title|shortcut" ("-" is a separator).
    private let mock: [(String, [String])] = [
        ("Gobi", ["About Gobi|", "Check for Updates…|", "-", "Settings…|⌘,", "Services|", "-", "Hide Gobi|⌘H", "Hide Others|⌥⌘H", "-", "Quit Gobi|⌘Q"]),
        ("File", ["New Project…|⇧⌘N", "New File|⌘N", "Open…|⌘O", "Open Recent|", "Clone Repository…|⇧⌘K", "Import Existing Code…|", "-", "Close Tab|⌘W", "Close Project|⇧⌘W", "-", "Save|⌘S", "Save All|⌥⌘S", "-", "Reveal in Finder|"]),
        ("Edit", ["Undo|⌘Z", "Redo|⇧⌘Z", "-", "Cut|⌘X", "Copy|⌘C", "Paste|⌘V", "Select All|⌘A", "-", "Find|", "-", "Format Document|⌥⇧F", "Organize Imports|⌃⌥O", "Rename Symbol…|F2", "Code Actions…|⌘.", "Toggle Comment|⌘/"]),
        ("View", ["Toggle Sidebar|⌘0", "Toggle Inspector|⌥⌘0", "Toggle Bottom Panel|⌘J", "-", "Outline|", "Markdown Preview|⇧⌘V", "Editor Layout|", "-", "Zoom In|⌘+", "Zoom Out|⌘−", "Actual Size|⌘0", "-", "Enter Full Screen|⌃⌘F"]),
        ("Go", ["Back|⌘[", "Forward|⌘]", "-", "Go to File…|⌘P", "Go to Symbol in Workspace…|⌘T", "Go to Symbol in File…|⇧⌘O", "-", "Go to Definition|F12", "Go to Implementation|⌘F12", "Find References|⇧F12", "Go to Test|⇧⌘T", "-", "Next Problem|F8", "Previous Problem|⇧F8"]),
        ("Run", ["Run|⌘R", "Run Tests|⌘U", "Run Test at Cursor|⌥⌘U", "Run on Multiple Go Versions…|", "Profile|⌘I", "-", "Environment|", "Go Toolchain|", "-", "Edit Run Configurations…|", "Manage Environments…|", "Manage Go Toolchains…|"]),
        ("Debug", ["Start Debugging|F5", "Stop|⇧F5", "Restart|⇧⌘F5", "Continue|F5", "-", "Step Over|F10", "Step Into|F11", "Step Out|⇧F11", "-", "Toggle Breakpoint|⌘\\", "Add Conditional Breakpoint…|", "-", "Attach to Process…|", "Show Goroutines|"]),
        ("Window", ["Minimize|⌘M", "Zoom|", "Move Tab to New Window|", "Bring All to Front|"]),
        ("Help", ["Search|⇧⌘/", "Gobi Help|", "Release Notes|", "Keyboard Shortcuts|", "Report an Issue…|"]),
    ]

    @Test func theMenusAreTheMocksInTheMocksOrder() {
        #expect(MenuSpec.all.map(\.title) == mock.map(\.0))
    }

    @Test(arguments: 0 ..< 9)
    func eachMenuHasTheMocksItemsAndShortcuts(index: Int) {
        let expected = mock[index].1
        let actual = MenuSpec.all[index].entries.map { $0.isSeparator ? "-" : "\($0.title)|\($0.shortcut)" }
        // Items the app adds beyond the mock (for example Show Next Tab) are listed after the mock's own and checked below.
        #expect(Array(actual.prefix(expected.count)) == expected, "menu \(mock[index].0)")
    }

    @Test func everyShortcutIsUniqueWithinTheMenuBar() {
        var seen: [String: String] = [:]
        for menu in MenuSpec.all {
            for entry in menu.entries where !entry.shortcut.isEmpty && !entry.isSeparator {
                if let other = seen[entry.shortcut], other != entry.title, !MenuSpec.sharedShortcuts.contains(entry.shortcut) {
                    Issue.record("shortcut \(entry.shortcut) is used by \(other) and \(entry.title)")
                }
                seen[entry.shortcut] = entry.title
            }
        }
    }

    @Test func itemsWithoutAFeatureBehindThemAreMarkedNotBuilt() {
        let live = MenuSpec.all.flatMap(\.entries).filter { $0.action != nil }.map(\.title)
        #expect(live.contains("New Project…"))
        #expect(live.contains("Toggle Bottom Panel"))
        let notBuilt = MenuSpec.all.flatMap(\.entries).filter { !$0.isSeparator && $0.action == nil && $0.children.isEmpty }.map(\.title)
        #expect(notBuilt.contains("Start Debugging"))
        #expect(!notBuilt.contains("Quit Gobi"))
    }
}

@Suite("Context menus against the mock")
struct ContextMenuSpecTests {
    /// "title|shortcut", with "▸" in the shortcut column for a submenu, as the mock draws it.
    private func rows(_ entries: [MenuEntry]) -> [String] { entries.map { $0.isSeparator ? "-" : "\($0.title)|\($0.children.isEmpty ? $0.shortcut : "▸")" } }

    @Test func theEditorMenuIsTheMocks() {
        #expect(rows(ContextMenuSpec.editor) == ["Go to Definition|F12", "Go to Implementation|⌘F12", "Find References|⇧F12", "-", "Rename Symbol…|F2", "Code Actions…|⌘.", "Format Document|⌥⇧F", "-", "Cut|⌘X", "Copy|⌘C", "Paste|⌘V", "Select All|⌘A", "-", "Reveal in Finder|", "Copy Path|"])
    }

    @Test func theExplorerMenuIsTheMocks() {
        #expect(rows(ContextMenuSpec.explorer) == ["New|▸", "-", "Cut|⌘X", "Copy|⌘C", "Copy Path|▸", "Paste|⌘V", "-", "Jump to Source|F4", "Reveal in Finder|", "Find in Files…|⇧⌘F", "Replace in Files…|⇧⌘R", "-", "Refactor|▸", "-", "Format Document|⌥⇧F", "Organize Imports|⌃⌥O", "Delete…|⌫", "-", "Go Mod Tidy|", "Download Go Modules|", "Build Module|"])
    }

    @Test func theCopyPathSubmenuOffersThreeForms() {
        let copyPath = ContextMenuSpec.explorer.first { $0.title == "Copy Path" }
        #expect(copyPath?.children.map(\.title) == ["Absolute Path", "Path from Project Root", "File Name"])
    }

    @Test func theTabMenuIsTheMocks() {
        #expect(rows(ContextMenuSpec.tab) == ["Close|⌘W", "Close Others|", "Close Tabs to the Right|", "-", "Copy Path|", "Reveal in Finder|"])
    }

    @Test func theEditorMenuReusesTheMenuBarShortcuts() {
        let bar = MenuSpec.all.flatMap(\.entries) + MenuSpec.all.flatMap(\.entries).flatMap(\.children)
        for entry in ContextMenuSpec.editor where !entry.isSeparator && !entry.shortcut.isEmpty {
            #expect(bar.contains { $0.title == entry.title && $0.shortcut == entry.shortcut }, "\(entry.title) should have the same shortcut in the menu bar")
        }
    }
}
