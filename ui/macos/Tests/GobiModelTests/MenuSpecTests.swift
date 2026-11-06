import Testing
@testable import GobiModel

@Suite("Menu bar against the mock")
struct MenuSpecTests {
    /// The Menus mock, transcribed: menu title, then each item as "title|shortcut" ("-" is a separator, a submenu has "▸" in the
    /// shortcut column). Where an existing Gobi shortcut owns the key the mock gives to another item, the other item shows no
    /// shortcut, and Gobi's own key stays: Debug F5 (mock ⌘D), Stop ⇧F5 (⌘F2), Resume F5 (⌥⌘R), Step Over F10 (F8), Step Into F11
    /// (F7), Step Out ⇧F11 (⇧F8), Toggle Line Breakpoint ⌘\ (⌘F8), Push none (⇧⌘K is Clone), Recent Files none (⌘E is Use
    /// Selection for Find). See docs/implement/menu-shortcuts.md.
    private let mock: [(String, [String])] = [
        ("Gobi", ["About Gobi|", "Check for Updates…|", "-", "Settings…|⌘,", "-", "Services|", "-", "Hide Gobi|⌘H", "Hide Others|⌥⌘H", "-", "Quit Gobi|⌘Q"]),
        ("File", ["New Project…|⇧⌘N", "New File|⌘N", "-", "Open…|⌘O", "Open Recent|", "Clone Repository…|⇧⌘K", "Import Existing Code…|", "-", "Close Tab|⌘W", "Close Project|⇧⌘W", "-", "Save|⌘S", "Save All|⌥⌘S", "Reveal in Finder|"]),
        ("Edit", ["Undo|⌘Z", "Redo|⇧⌘Z", "-", "Cut|⌘X", "Copy|⌘C", "Paste|⌘V", "Paste from History…|⇧⌘V", "Paste as Plain Text|⌥⇧⌘V", "Select All|⌘A", "-", "Find|▸", "Find in Files…|⇧⌘F", "-", "Copy Path|⇧⌘C", "Copy Reference|⌥⇧⌘C", "-", "Sort Lines|", "Reverse Lines|", "-", "Column Selection Mode|⇧⌘8", "-", "Format Document|⌥⇧F", "Organize Imports|⌃⌥O", "Rename Symbol…|F2", "Code Actions…|⌘.", "Parameter Info|⇧⌘Space", "Toggle Comment|⌘/", "-", "Macros|", "Bookmarks|", "-", "AutoFill|", "Start Dictation…|", "Emoji & Symbols|"]),
        ("View", ["Tool Windows|", "Appearance|", "-", "Toggle Sidebar|⌘0", "Toggle Inspector|⌥⌘0", "Toggle Bottom Panel|⌘J", "New Terminal|⌃⇧`", "-", "Quick Definition|⌥Space", "Quick Type Definition|", "-", "Recent Locations|⇧⌘E", "Recent Files|", "Recent Changes|⌥⇧C", "-", "Compare with Clipboard|", "-", "Markdown Preview|⇧⌘V", "Editor Layout|", "Quick Switch Scheme…|⌃`", "-", "Zoom In|⌘+", "Zoom Out|⌘−", "Actual Size|⌘0", "Reset Font Size in All Editors|", "-", "Notifications|", "Enter Full Screen|⌃⌘F"]),
        ("Go", ["Back|⌘[", "Forward|⌘]", "-", "Go to File…|⌘P", "Go to Symbol in Workspace…|⌘T", "Go to Symbol in File…|⇧⌘O", "-", "Go to Definition|F12", "Go to Implementation|⌘F12", "Find References|⇧F12", "Find Usages|⌥F7", "Go to Test|⇧⌘T", "-", "Next Problem|F8", "Previous Problem|⇧F8", "-", "Command Palette…|⇧⌘P"]),
        ("Build", ["Build Project|⌘F9", "Build Module|⇧⌘F9", "Rebuild Project|", "-", "Build Artifacts|"]),
        ("Run", ["Run|⌘R", "Debug|F5", "Run Context Configuration|⌃⇧R", "Debug Context Configuration|⌃⇧D", "Run with Coverage|", "Profile|⌘I", "Stop|⇧F5", "-", "Run…|⌃⌥R", "Debug…|⌃⌥D", "Run Anything…|", "Edit Configurations…|⌃⌥⇧R", "Update Application|⌘F10", "Attach to Process…|⌥⇧F5", "-", "Resume Program|F5", "Pause Program|", "Step Over|F10", "Force Step Over|⌥⇧F8", "Step Into|F11", "Force Step Into|⌥⇧F7", "Smart Step Into|⇧F7", "Step Out|⇧F11", "Run to Cursor|⌥F9", "Force Run to Cursor|⌥⌘F9", "Show Execution Point|⌥F10", "Reset Frame|", "Evaluate Expression…|⌥F8", "Quick Evaluate Expression|⌥⌘F8", "Debugging Actions|▸", "-", "Hide Coverage|", "-", "Toggle Line Breakpoint|⌘\\", "Toggle Temporary Line Breakpoint|⌥⇧⌘F8", "Toggle Method Breakpoint|", "Toggle Field Watchpoint|", "Add Conditional Breakpoint…|", "View Breakpoints…|⇧⌘F8", "Show Goroutines|", "-", "Run Tests|⌘U", "Run Test at Cursor|⌥⌘U", "Run on Multiple Go Versions…|", "-", "Environment|", "Go Toolchain|", "Manage Environments…|", "Manage Go Toolchains…|"]),
        ("Git", ["Commit…|⌘K", "Push…|", "Update Project…|⌥⌘T", "Pull…|", "Fetch|", "-", "Merge…|", "Abort Merge|", "Rebase…|", "Abort Rebase|", "Continue Rebase|", "Skip Commit|", "Resolve Conflicts…|", "-", "Branches…|", "New Branch…|⌥⌘N", "New Tag…|", "Reset HEAD…|", "-", "New Worktree…|", "Worktrees…|", "-", "Show Git Log|", "Patch|▸", "Uncommitted Changes|▸", "Current File|▸", "-", "Manage Remotes…|", "Clone…|", "-", "Continue Revert|", "Abort Revert|", "Continue Cherry-Pick|", "Abort Cherry-Pick|"]),
        ("Window", ["Minimize|⌘M", "Zoom|", "-", "Tool Window Layouts|", "-", "Active Tool Window|", "Editor Tabs|▸", "-", "New Window|", "Merge All Project Windows|", "Move Tab to New Window|", "Next Project Tab|⌥⌘⇣", "Previous Project Tab|⌥⌘⇡", "Next Project Window|⌘`", "Previous Project Window|⇧⌘`", "-", "Bring All to Front|"]),
        ("Help", ["Search|⇧⌘/", "Gobi Help|", "Release Notes|", "Keyboard Shortcuts|", "Check Setup…|", "Open Logs Folder|", "Copy Diagnostics|", "Report an Issue…|"]),
    ]

    private func row(_ entry: MenuEntry) -> String {
        entry.isSeparator ? "-" : "\(entry.title)|\(entry.children.isEmpty ? entry.shortcut : "▸")"
    }

    @Test func theMenusAreTheMocksInTheMocksOrder() {
        #expect(MenuSpec.all.map(\.title) == mock.map(\.0))
    }

    @Test(arguments: 0 ..< 10)
    func eachMenuHasTheMocksItemsAndShortcuts(index: Int) {
        let expected = mock[index].1
        // The File menu in the mock has a rule between New File and Open; Open Recent's arrow is drawn but its shortcut column is empty.
        let actual = MenuSpec.all[index].entries.map { entry -> String in
            let text = row(entry)
            return entry.action == "openRecent" || entry.action == "recentFiles" || entry.action == "services" || entry.title == "Environment" || entry.title == "Go Toolchain" ? "\(entry.title)|" : text
        }
        #expect(actual == expected, "menu \(mock[index].0)")
    }

    @Test func everyShortcutIsUniqueWithinTheMenuBar() {
        var seen: [String: String] = [:]
        func walk(_ entries: [MenuEntry]) {
            for entry in entries where !entry.isSeparator {
                if !entry.shortcut.isEmpty {
                    if let other = seen[entry.shortcut], other != entry.title, !MenuSpec.sharedShortcuts.contains(entry.shortcut) {
                        Issue.record("shortcut \(entry.shortcut) is used by \(other) and \(entry.title)")
                    }
                    seen[entry.shortcut] = entry.title
                }
                walk(entry.children)
            }
        }
        for menu in MenuSpec.all { walk(menu.entries) }
    }

    @Test func theGitSubmenusAreTheMocks() {
        let git = MenuSpec.all.first { $0.title == "Git" }!.entries
        func children(_ title: String) -> [String] { git.first { $0.title == title }!.children.map(\.title) }
        #expect(children("Patch") == ["Create Patch from Changes…", "Apply Patch…"])
        #expect(children("Uncommitted Changes") == ["Stash Changes…", "Unstash Changes…", "Roll Back All…"])
        #expect(children("Current File") == ["Show Diff", "Show History", "Annotate (Blame)", "Stage / Unstage", "Roll Back…"])
    }

    @Test func debuggingIsPartOfTheRunMenuNotAMenuOfItsOwn() {
        #expect(!MenuSpec.all.map(\.title).contains("Debug"))
        let run = MenuSpec.all.first { $0.title == "Run" }!.entries
        #expect(run.first { $0.title == "Debug" }?.action == "debugStart")
        #expect(run.first { $0.title == "Debugging Actions" }?.children.map(\.title) == ["Restart"])
    }

    @Test func itemsWithoutAFeatureBehindThemAreMarkedNotBuilt() {
        func all(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + all($0.children) } }
        let every = MenuSpec.all.flatMap { all($0.entries) }
        let live = every.filter { $0.action != nil }.map(\.title)
        for title in ["New Project…", "Toggle Bottom Panel", "Commit…", "Build Project", "Stop", "Roll Back All…", "Sort Lines", "Recent Files", "New Window", "Next Project Window", "Show Next Tab"] {
            #expect(live.contains(title), "\(title) should be live")
        }
        let notBuilt = every.filter { !$0.isSeparator && $0.action == nil && $0.children.isEmpty }.map(\.title)
        for title in ["Gobi Help", "Column Selection Mode", "Quick Definition", "Notifications", "Build Artifacts", "Run with Coverage", "Show History", "Annotate (Blame)"] {
            #expect(notBuilt.contains(title), "\(title) should stay disabled")
        }
        #expect(!notBuilt.contains("Debug") && !notBuilt.contains("Attach to Process…") && !notBuilt.contains("Quit Gobi"))
    }

    @Test func everyActionIdIsUsedByOneItemOnly() {
        func all(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + all($0.children) } }
        var ids: [String: String] = [:]
        for entry in MenuSpec.all.flatMap({ all($0.entries) }) {
            guard let action = entry.action, !entry.isSeparator else { continue }
            if let other = ids[action] { Issue.record("action \(action) is on \(other) and \(entry.title)") }
            ids[action] = entry.title
        }
    }
}

@Suite("Context menus against the mock")
struct ContextMenuSpecTests {
    /// "title|shortcut", with "▸" in the shortcut column for a submenu, as the mock draws it.
    private func rows(_ entries: [MenuEntry]) -> [String] { entries.map { $0.isSeparator ? "-" : "\($0.title)|\($0.children.isEmpty ? $0.shortcut : "▸")" } }

    @Test func theEditorMenuIsTheMocks() {
        #expect(rows(ContextMenuSpec.editor) == ["Run|", "Debug|", "-", "Go to Definition|F12", "Go to Implementation|⌘F12", "Find References|⇧F12", "Find Usages|⌥F7", "-", "Rename Symbol…|F2", "Code Actions…|⌘.", "Format Document|⌥⇧F", "-", "Cut|⌘X", "Copy|⌘C", "Paste|⌘V", "Select All|⌘A", "-", "Reveal in Finder|", "Copy Path|"])
    }

    @Test func theExplorerMenuIsTheMocks() {
        #expect(rows(ContextMenuSpec.explorer) == ["Run|", "Debug|", "-", "New|▸", "-", "Cut|⌘X", "Copy|⌘C", "Copy Path|▸", "Paste|⌘V", "-", "Jump to Source|F4", "Reveal in Finder|", "Find in Files…|⇧⌘F", "Replace in Files…|⇧⌘R", "-", "Refactor|▸", "-", "Format Document|⌥⇧F", "Organize Imports|⌃⌥O", "Delete…|⌫", "-", "Create go.mod|", "Go Mod Tidy|","Download Go Modules|", "Build Module|"])
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
