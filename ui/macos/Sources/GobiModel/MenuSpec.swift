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
    /// Shortcuts the mock gives to two items on purpose (different contexts), so the uniqueness test lets them through.
    public static let sharedShortcuts: Set<String> = ["⌘0", "F5"]

    public static let all: [MenuDefinition] = [
        MenuDefinition(title: "Gobi", entries: [
            .item("About Gobi", "", "about"), .item("Check for Updates…"), .separator,
            .item("Settings…", "⌘,"), .submenu("Services", "services"), .separator,
            .item("Hide Gobi", "⌘H", "hide"), .item("Hide Others", "⌥⌘H", "hideOthers"), .separator,
            .item("Quit Gobi", "⌘Q", "quit"),
        ]),
        MenuDefinition(title: "File", entries: [
            .item("New Project…", "⇧⌘N", "newProject"), .item("New File", "⌘N"), .item("Open…", "⌘O", "open"),
            .submenu("Open Recent", "openRecent"), .item("Clone Repository…", "⇧⌘K", "clone"), .item("Import Existing Code…", "", "importCode"),
            .separator,
            .item("Close Tab", "⌘W", "closeTab"), .item("Close Project", "⇧⌘W", "closeProject"),
            .separator,
            .item("Save", "⌘S", "save"), .item("Save All", "⌥⌘S", "saveAll"),
            .separator,
            .item("Reveal in Finder", "", "revealInFinder"),
        ]),
        MenuDefinition(title: "Edit", entries: [
            .item("Undo", "⌘Z", "undo"), .item("Redo", "⇧⌘Z", "redo"), .separator,
            .item("Cut", "⌘X", "cut"), .item("Copy", "⌘C", "copy"), .item("Paste", "⌘V", "paste"), .item("Select All", "⌘A", "selectAll"), .separator,
            .submenu("Find", nil, [
                .item("Find…", "⌘F", "find"), .item("Find Next", "⌘G", "findNext"), .item("Find Previous", "⇧⌘G", "findPrevious"),
                .item("Use Selection for Find", "⌘E", "useSelection"), .separator, .item("Find in Files…", "⇧⌘F"),
            ]),
            .separator,
            .item("Format Document", "⌥⇧F", "formatDocument"), .item("Organize Imports", "⌃⌥O"), .item("Rename Symbol…", "F2"),
            .item("Code Actions…", "⌘."), .item("Toggle Comment", "⌘/"),
        ]),
        MenuDefinition(title: "View", entries: [
            .item("Toggle Sidebar", "⌘0", "toggleSidebar"), .item("Toggle Inspector", "⌥⌘0"), .item("Toggle Bottom Panel", "⌘J", "toggleBottomPanel"),
            .separator,
            .item("Outline"), .item("Markdown Preview", "⇧⌘V"), .submenu("Editor Layout"),
            .separator,
            .item("Zoom In", "⌘+"), .item("Zoom Out", "⌘−"), .item("Actual Size", "⌘0"),
            .separator,
            .item("Enter Full Screen", "⌃⌘F", "fullScreen"),
        ]),
        MenuDefinition(title: "Go", entries: [
            .item("Back", "⌘["), .item("Forward", "⌘]"), .separator,
            .item("Go to File…", "⌘P"), .item("Go to Symbol in Workspace…", "⌘T"), .item("Go to Symbol in File…", "⇧⌘O"), .separator,
            .item("Go to Definition", "F12", "goToDefinition"), .item("Go to Implementation", "⌘F12"), .item("Find References", "⇧F12"), .item("Go to Test", "⇧⌘T"), .separator,
            .item("Next Problem", "F8"), .item("Previous Problem", "⇧F8"),
        ]),
        MenuDefinition(title: "Run", entries: [
            .item("Run", "⌘R"), .item("Run Tests", "⌘U"), .item("Run Test at Cursor", "⌥⌘U"), .item("Run on Multiple Go Versions…"), .item("Profile", "⌘I"),
            .separator,
            .submenu("Environment"), .submenu("Go Toolchain"),
            .separator,
            .item("Edit Run Configurations…"), .item("Manage Environments…"), .item("Manage Go Toolchains…"),
        ]),
        MenuDefinition(title: "Debug", entries: [
            .item("Start Debugging", "F5"), .item("Stop", "⇧F5"), .item("Restart", "⇧⌘F5"), .item("Continue", "F5"), .separator,
            .item("Step Over", "F10"), .item("Step Into", "F11"), .item("Step Out", "⇧F11"), .separator,
            .item("Toggle Breakpoint", "⌘\\"), .item("Add Conditional Breakpoint…"), .separator,
            .item("Attach to Process…"), .item("Show Goroutines"),
        ]),
        MenuDefinition(title: "Window", entries: [
            .item("Minimize", "⌘M", "minimize"), .item("Zoom", "", "zoomWindow"), .item("Move Tab to New Window"), .item("Bring All to Front", "", "bringAllToFront"),
            .separator,
            .item("Show Next Tab", "⇧⌘]", "nextTab"), .item("Show Previous Tab", "⇧⌘[", "previousTab"),
        ]),
        MenuDefinition(title: "Help", entries: [
            .item("Search", "⇧⌘/"), .item("Gobi Help"), .item("Release Notes"), .item("Keyboard Shortcuts", "", "showShortcuts"), .item("Report an Issue…"),
        ]),
    ]
}

/// The right-click menus of the Context menus mock, in order. Action ids are the ones the app maps to behaviour; an entry
/// without one is in the mock but has no feature behind it yet, so it is drawn disabled.
public enum ContextMenuSpec {
    public static let editor: [MenuEntry] = [
        .item("Go to Definition", "F12", "goToDefinition"), .item("Go to Implementation", "⌘F12"), .item("Find References", "⇧F12"), .separator,
        .item("Rename Symbol…", "F2"), .item("Code Actions…", "⌘."), .item("Format Document", "⌥⇧F", "formatDocument"), .separator,
        .item("Cut", "⌘X", "cut"), .item("Copy", "⌘C", "copy"), .item("Paste", "⌘V", "paste"), .item("Select All", "⌘A", "selectAll"), .separator,
        .item("Reveal in Finder", "", "revealInFinder"), .item("Copy Path", "", "copyPath"),
    ]

    public static let explorer: [MenuEntry] = [
        .submenu("New", nil, [.item("File…"), .item("Folder…"), .separator, .item("Go File…"), .item("Go Test File…")]),
        .separator,
        .item("Cut", "⌘X"), .item("Copy", "⌘C"),
        .submenu("Copy Path", nil, [.item("Absolute Path", "", "copyPath"), .item("Path from Project Root", "", "copyRelativePath"), .item("File Name", "", "copyFileName")]),
        .item("Paste", "⌘V"),
        .separator,
        .item("Jump to Source", "F4", "open"), .item("Reveal in Finder", "", "revealInFinder"),
        .item("Find in Files…", "⇧⌘F"), .item("Replace in Files…", "⇧⌘R"),
        .separator,
        .submenu("Refactor", nil, [.item("Rename…", "⇧F6"), .item("Move…", "F6")]),
        .separator,
        .item("Format Document", "⌥⇧F"), .item("Organize Imports", "⌃⌥O"), .item("Delete…", "⌫"),
        .separator,
        .item("Go Mod Tidy", "", "goModTidy"), .item("Download Go Modules", "", "goModDownload"), .item("Build Module"),
    ]

    public static let tab: [MenuEntry] = [
        .item("Close", "⌘W", "close"), .item("Close Others", "", "closeOthers"), .item("Close Tabs to the Right", "", "closeToTheRight"), .separator,
        .item("Copy Path", "", "copyPath"), .item("Reveal in Finder", "", "revealInFinder"),
    ]
}
