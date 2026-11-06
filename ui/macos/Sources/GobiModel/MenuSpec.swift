// The menu bar as data, in the order and with the shortcuts of the Menus mock. The app layer turns it into NSMenus and
// maps each `action` id to a selector; an entry without an action is in the mock but has no feature behind it yet, so
// it is drawn disabled. Keeping the list here lets a test compare it with the mock.

public struct MenuEntry: Equatable {
    public var title: String
    /// Glyph form as in the mock: "⇧⌘N", "⌘,", "F12".
    public var shortcut: String
    /// The id of what the item does; nil when the feature is not built yet.
    public var action: String?
    public var children: [MenuEntry]
    public var isSeparator: Bool

    public static func item(_ title: String, _ shortcut: String = "", _ action: String? = nil) -> MenuEntry {
        MenuEntry(title: title, shortcut: shortcut, action: action, children: [], isSeparator: false)
    }

    public static func submenu(_ title: String, _ action: String? = nil, _ children: [MenuEntry] = []) -> MenuEntry {
        MenuEntry(title: title, shortcut: "", action: action, children: children, isSeparator: false)
    }

    public static let separator = MenuEntry(title: "", shortcut: "", action: nil, children: [], isSeparator: true)
}

public struct MenuDefinition: Equatable {
    public var title: String
    public var entries: [MenuEntry]
}

public enum MenuSpec {
    /// Shortcuts that two items share on purpose: the mock gives them twice (⌘0, ⇧⌘V), or two items answer the same key in
    /// different states (F5 starts a debug session, or resumes a paused one).
    public static let sharedShortcuts: Set<String> = ["⌘0", "F5", "⇧⌘V"]

    public static let all: [MenuDefinition] = [
        MenuDefinition(title: "Gobi", entries: [
            .item("About Gobi", "", "about"), .item("Check for Updates…"), .separator,
            .item("Settings…", "⌘,", "settings"), .separator,
            .submenu("Services", "services"), .separator,
            .item("Hide Gobi", "⌘H", "hide"), .item("Hide Others", "⌥⌘H", "hideOthers"), .separator,
            .item("Quit Gobi", "⌘Q", "quit"),
        ]),
        MenuDefinition(title: "File", entries: [
            .item("New Project…", "⇧⌘N", "newProject"), .item("New File", "⌘N"), .separator,
            .item("Open…", "⌘O", "open"), .submenu("Open Recent", "openRecent"),
            .item("Clone Repository…", "⇧⌘K", "clone"), .item("Import Existing Code…", "", "importCode"),
            .separator,
            .item("Close Tab", "⌘W", "closeTab"), .item("Close Project", "⇧⌘W", "closeProject"),
            .separator,
            .item("Save", "⌘S", "save"), .item("Save All", "⌥⌘S", "saveAll"), .item("Reveal in Finder", "", "revealInFinder"),
        ]),
        MenuDefinition(title: "Edit", entries: [
            .item("Undo", "⌘Z", "undo"), .item("Redo", "⇧⌘Z", "redo"), .separator,
            .item("Cut", "⌘X", "cut"), .item("Copy", "⌘C", "copy"), .item("Paste", "⌘V", "paste"),
            .item("Paste from History…", "⇧⌘V"), .item("Paste as Plain Text", "⌥⇧⌘V", "pastePlain"), .item("Select All", "⌘A", "selectAll"),
            .separator,
            .submenu("Find", nil, [
                .item("Find…", "⌘F", "find"), .item("Find Next", "⌘G", "findNext"), .item("Find Previous", "⇧⌘G", "findPrevious"),
                .item("Use Selection for Find", "⌘E", "useSelection"),
            ]),
            .item("Find in Files…", "⇧⌘F", "findInFiles"),
            .separator,
            .item("Copy Path", "⇧⌘C", "copyPath"), .item("Copy Reference", "⌥⇧⌘C"),
            .separator,
            .item("Sort Lines", "", "sortLines"), .item("Reverse Lines", "", "reverseLines"),
            .separator,
            .item("Column Selection Mode", "⇧⌘8"),
            .separator,
            .item("Format Document", "⌥⇧F", "formatDocument"), .item("Organize Imports", "⌃⌥O", "organizeImports"), .item("Rename Symbol…", "F2", "renameSymbol"),
            .item("Code Actions…", "⌘.", "codeActions"), .item("Parameter Info", "⇧⌘Space", "parameterInfo"), .item("Toggle Comment", "⌘/"),
            .separator,
            .submenu("Macros"), .submenu("Bookmarks"),
            .separator,
            .submenu("AutoFill"), .item("Start Dictation…", "", "startDictation"), .item("Emoji & Symbols", "", "emojiSymbols"),
        ]),
        MenuDefinition(title: "View", entries: [
            .submenu("Tool Windows"), .submenu("Appearance"),
            .separator,
            .item("Toggle Sidebar", "⌘0", "toggleSidebar"), .item("Toggle Inspector", "⌥⌘0", "toggleInspector"), .item("Toggle Bottom Panel", "⌘J", "toggleBottomPanel"), .item("New Terminal", "⌃⇧`", "newTerminal"),
            .separator,
            .item("Quick Definition", "⌥Space"), .item("Quick Type Definition"),
            .separator,
            .item("Recent Locations", "⇧⌘E"), .submenu("Recent Files", "recentFiles"), .item("Recent Changes", "⌥⇧C"),
            .separator,
            .item("Compare with Clipboard"),
            .separator,
            .item("Markdown Preview", "⇧⌘V"), .submenu("Editor Layout"), .item("Quick Switch Scheme…", "⌃`"),
            .separator,
            .item("Zoom In", "⌘+"), .item("Zoom Out", "⌘−"), .item("Actual Size", "⌘0"), .item("Reset Font Size in All Editors", "", "resetFontSize"),
            .separator,
            .item("Notifications"), .item("Enter Full Screen", "⌃⌘F", "fullScreen"),
        ]),
        MenuDefinition(title: "Go", entries: [
            .item("Back", "⌘["), .item("Forward", "⌘]"), .separator,
            .item("Go to File…", "⌘P", "goToFile"), .item("Go to Symbol in Workspace…", "⌘T", "goToWorkspaceSymbol"), .item("Go to Symbol in File…", "⇧⌘O", "goToFileSymbol"), .separator,
            .item("Go to Definition", "F12", "goToDefinition"), .item("Go to Implementation", "⌘F12", "goToImplementation"), .item("Find References", "⇧F12", "findReferences"), .item("Go to Test", "⇧⌘T"), .separator,
            .item("Next Problem", "F8"), .item("Previous Problem", "⇧F8"),
            .separator,
            .item("Command Palette…", "⇧⌘P", "commandPalette"),
        ]),
        MenuDefinition(title: "Build", entries: [
            .item("Build Project", "⌘F9", "buildProject"), .item("Build Module", "⇧⌘F9", "buildModule"), .item("Rebuild Project", "", "rebuildProject"),
            .separator,
            .item("Build Artifacts"),
        ]),
        MenuDefinition(title: "Run", entries: [
            .item("Run", "⌘R", "run"), .item("Debug", "F5", "debugStart"), .item("Run Context Configuration", "⌃⇧R"), .item("Debug Context Configuration", "⌃⇧D"),
            .item("Run with Coverage"), .item("Profile", "⌘I", "profile"), .item("Stop", "⇧F5", "stop"),
            .separator,
            .item("Run…", "⌃⌥R"), .item("Debug…", "⌃⌥D"), .item("Run Anything…"), .item("Edit Configurations…", "⌃⌥⇧R"),
            .item("Update Application", "⌘F10"), .item("Attach to Process…", "⌥⇧F5", "debugAttach"),
            .separator,
            .item("Resume Program", "F5", "debugContinue"), .item("Pause Program"), .item("Step Over", "F10", "debugStepOver"), .item("Force Step Over", "⌥⇧F8"),
            .item("Step Into", "F11", "debugStepInto"), .item("Force Step Into", "⌥⇧F7"), .item("Smart Step Into", "⇧F7"), .item("Step Out", "⇧F11", "debugStepOut"),
            .item("Run to Cursor", "⌥F9"), .item("Force Run to Cursor", "⌥⌘F9"), .item("Show Execution Point", "⌥F10"), .item("Reset Frame"),
            .item("Evaluate Expression…", "⌥F8", "evaluateExpression"), .item("Quick Evaluate Expression", "⌥⌘F8"),
            .submenu("Debugging Actions", nil, [.item("Restart", "⇧⌘F5", "debugRestart")]),
            .separator,
            .item("Hide Coverage"),
            .separator,
            .item("Toggle Line Breakpoint", "⌘\\", "toggleBreakpoint"), .item("Toggle Temporary Line Breakpoint", "⌥⇧⌘F8"), .item("Toggle Method Breakpoint"), .item("Toggle Field Watchpoint"),
            .item("Add Conditional Breakpoint…", "", "debugConditional"), .item("View Breakpoints…", "⇧⌘F8", "viewBreakpoints"), .item("Show Goroutines", "", "debugGoroutines"),
            .separator,
            .item("Run Tests", "⌘U", "runTests"), .item("Run Test at Cursor", "⌥⌘U", "runTestAtCursor"), .item("Run on Multiple Go Versions…", "", "runMultiVersion"),
            .separator,
            .submenu("Environment"), .submenu("Go Toolchain"), .item("Manage Environments…", "", "manageEnvironments"), .item("Manage Go Toolchains…", "", "manageToolchains"),
        ]),
        MenuDefinition(title: "Git", entries: [
            .item("Commit…", "⌘K", "gitCommit"), .item("Push…", "", "gitPush"), .item("Update Project…", "⌥⌘T", "gitUpdate"), .item("Pull…", "", "gitPull"), .item("Fetch", "", "gitFetch"),
            .separator,
            .item("Merge…", "", "gitMerge"), .item("Abort Merge", "", "gitAbortMerge"), .item("Rebase…", "", "gitRebase"), .item("Abort Rebase", "", "gitAbortRebase"),
            .item("Continue Rebase", "", "gitContinueRebase"), .item("Skip Commit", "", "gitSkipCommit"), .item("Resolve Conflicts…", "", "gitResolveConflicts"),
            .separator,
            .item("Branches…", "", "gitBranches"), .item("New Branch…", "⌥⌘N", "gitNewBranch"), .item("New Tag…", "", "gitNewTag"), .item("Reset HEAD…", "", "gitResetHead"),
            .separator,
            .item("New Worktree…", "", "gitNewWorktree"), .item("Worktrees…", "", "gitWorktrees"),
            .separator,
            .item("Show Git Log", "", "gitShowLog"),
            .submenu("Patch", nil, [.item("Create Patch from Changes…", "", "gitCreatePatch"), .item("Apply Patch…", "", "gitApplyPatch")]),
            .submenu("Uncommitted Changes", nil, [.item("Stash Changes…", "", "gitStash"), .item("Unstash Changes…", "", "gitUnstash"), .item("Roll Back All…", "", "gitRollBackAll")]),
            .submenu("Current File", nil, [
                .item("Show Diff", "", "gitFileDiff"), .item("Show History"), .item("Annotate (Blame)"),
                .item("Stage / Unstage", "", "gitFileStage"), .item("Roll Back…", "", "gitFileRollBack"),
            ]),
            .separator,
            .item("Manage Remotes…", "", "gitManageRemotes"), .item("Clone…", "", "gitClone"),
            .separator,
            .item("Continue Revert", "", "gitContinueRevert"), .item("Abort Revert", "", "gitAbortRevert"),
            .item("Continue Cherry-Pick", "", "gitContinueCherryPick"), .item("Abort Cherry-Pick", "", "gitAbortCherryPick"),
        ]),
        MenuDefinition(title: "Window", entries: [
            .item("Minimize", "⌘M", "minimize"), .item("Zoom", "", "zoomWindow"),
            .separator,
            .submenu("Tool Window Layouts"),
            .separator,
            .submenu("Active Tool Window"),
            .submenu("Editor Tabs", nil, [.item("Show Next Tab", "⇧⌘]", "nextTab"), .item("Show Previous Tab", "⇧⌘[", "previousTab")]),
            .separator,
            .item("New Window", "", "newWindow"), .item("Merge All Project Windows"), .item("Move Tab to New Window"),
            .item("Next Project Tab", "⌥⌘⇣"), .item("Previous Project Tab", "⌥⌘⇡"),
            .item("Next Project Window", "⌘`", "nextProjectWindow"), .item("Previous Project Window", "⇧⌘`", "previousProjectWindow"),
            .separator,
            .item("Bring All to Front", "", "bringAllToFront"),
        ]),
        MenuDefinition(title: "Help", entries: [
            .item("Search", "⇧⌘/"), .item("Gobi Help"), .item("Release Notes"), .item("Keyboard Shortcuts", "", "showShortcuts"), .item("Check Setup…", "", "showSetup"), .item("Open Logs Folder", "", "openLogs"), .item("Copy Diagnostics", "", "copyDiagnostics"), .item("Report an Issue…"),
        ]),
    ]
}

/// The right-click menus of the Context menus mock, in order. Action ids are the ones the app maps to behaviour; an entry
/// without one is in the mock but has no feature behind it yet, so it is drawn disabled.
public enum ContextMenuSpec {
    public static let editor: [MenuEntry] = [
        .item("Go to Definition", "F12", "goToDefinition"), .item("Go to Implementation", "⌘F12", "goToImplementation"), .item("Find References", "⇧F12", "findReferences"), .separator,
        .item("Rename Symbol…", "F2", "renameSymbol"), .item("Code Actions…", "⌘.", "codeActions"), .item("Format Document", "⌥⇧F", "formatDocument"), .separator,
        .item("Cut", "⌘X", "cut"), .item("Copy", "⌘C", "copy"), .item("Paste", "⌘V", "paste"), .item("Select All", "⌘A", "selectAll"), .separator,
        .item("Reveal in Finder", "", "revealInFinder"), .item("Copy Path", "", "copyPath"),
    ]

    public static let explorer: [MenuEntry] = [
        .submenu("New", nil, [.item("File…", "", "newFile"), .item("Folder…", "", "newFolder"), .separator, .item("Go File…", "", "newGoFile"), .item("Go Test File…", "", "newGoTestFile")]),
        .separator,
        .item("Cut", "⌘X", "cutFiles"), .item("Copy", "⌘C", "copyFiles"),
        .submenu("Copy Path", nil, [.item("Absolute Path", "", "copyPath"), .item("Path from Project Root", "", "copyRelativePath"), .item("File Name", "", "copyFileName")]),
        .item("Paste", "⌘V", "pasteFiles"),
        .separator,
        .item("Jump to Source", "F4", "open"), .item("Reveal in Finder", "", "revealInFinder"),
        .item("Find in Files…", "⇧⌘F", "findInFiles"), .item("Replace in Files…", "⇧⌘R", "replaceInFiles"),
        .separator,
        .submenu("Refactor", nil, [.item("Rename…", "⇧F6", "renameFile"), .item("Move…", "F6", "moveFile")]),
        .separator,
        .item("Format Document", "⌥⇧F"), .item("Organize Imports", "⌃⌥O"), .item("Delete…", "⌫", "deleteFiles"),
        .separator,
        .item("Go Mod Tidy", "", "goModTidy"), .item("Download Go Modules", "", "goModDownload"), .item("Build Module"),
    ]

    public static let tab: [MenuEntry] = [
        .item("Close", "⌘W", "close"), .item("Close Others", "", "closeOthers"), .item("Close Tabs to the Right", "", "closeToTheRight"), .separator,
        .item("Copy Path", "", "copyPath"), .item("Reveal in Finder", "", "revealInFinder"),
    ]
}
