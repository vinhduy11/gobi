// The icon at the start of every menu item, as an SF Symbol name, keyed by the item's title. macOS 26 draws icons by itself
// on items with a system action (Cut, Copy, Quit…) and none on the rest, so every item gets one here and the menus look the
// same throughout. The app layer turns a name into an image; a test checks that every title in every menu has an entry.

public enum MenuIcons {
    public static func symbol(for title: String) -> String? { table[title] }

    /// Every title the table knows, for the test that finds entries no menu uses any more.
    public static var titles: [String] { Array(table.keys) }

    private static let table: [String: String] = [
        // Gobi
        "About Gobi": "info.circle", "Check for Updates…": "arrow.triangle.2.circlepath", "Settings…": "gearshape", "Services": "puzzlepiece.extension",
        "Hide Gobi": "eye.slash", "Hide Others": "eye.slash", "Quit Gobi": "power",
        // File
        "New Project…": "folder.badge.plus", "New File": "doc.badge.plus", "Open…": "folder", "Open Recent": "clock.arrow.circlepath",
        "Clone Repository…": "arrow.down.circle", "Import Existing Code…": "square.and.arrow.down", "Close Tab": "xmark", "Close Project": "xmark.rectangle",
        "Save": "square.and.arrow.down.on.square", "Save All": "square.and.arrow.down.on.square.fill", "Reveal in Finder": "magnifyingglass.circle",
        // Edit
        "Undo": "arrow.uturn.backward", "Redo": "arrow.uturn.forward", "Cut": "scissors", "Copy": "doc.on.doc", "Paste": "doc.on.clipboard",
        "Paste from History…": "clipboard", "Paste as Plain Text": "doc.plaintext", "Select All": "character.textbox",
        "Find": "magnifyingglass", "Find…": "magnifyingglass", "Find Next": "chevron.down", "Find Previous": "chevron.up",
        "Use Selection for Find": "text.magnifyingglass", "Find in Files…": "doc.text.magnifyingglass",
        "Copy Path": "link", "Copy Reference": "link.badge.plus", "Sort Lines": "arrow.up.arrow.down", "Reverse Lines": "arrow.up.and.down.text.horizontal",
        "Column Selection Mode": "rectangle.split.3x1", "Format Document": "text.alignleft", "Organize Imports": "list.bullet.indent",
        "Rename Symbol…": "pencil", "Code Actions…": "lightbulb", "Parameter Info": "parentheses", "Toggle Comment": "text.bubble",
        "Macros": "record.circle", "Bookmarks": "bookmark", "AutoFill": "text.badge.checkmark", "Start Dictation…": "mic", "Emoji & Symbols": "face.smiling",
        // View
        "Tool Windows": "macwindow", "Appearance": "paintbrush", "Toggle Sidebar": "sidebar.left", "Toggle Inspector": "sidebar.right",
        "Toggle Bottom Panel": "rectangle.bottomthird.inset.filled", "New Terminal": "terminal", "Quick Definition": "text.magnifyingglass",
        "Quick Type Definition": "t.square", "Recent Locations": "clock", "Recent Files": "clock.arrow.circlepath", "Recent Changes": "clock.badge.exclamationmark",
        "Compare with Clipboard": "rectangle.on.rectangle", "Markdown Preview": "doc.richtext", "Editor Layout": "rectangle.split.2x1",
        "Quick Switch Scheme…": "switch.2", "Zoom In": "plus.magnifyingglass", "Zoom Out": "minus.magnifyingglass", "Actual Size": "1.magnifyingglass",
        "Reset Font Size in All Editors": "textformat.size", "Notifications": "bell", "Enter Full Screen": "arrow.up.left.and.arrow.down.right",
        // Go
        "Back": "chevron.left", "Forward": "chevron.right", "Go to File…": "doc", "Go to Symbol in Workspace…": "number", "Go to Symbol in File…": "number.square",
        "Go to Definition": "arrow.turn.down.right", "Go to Implementation": "arrow.triangle.branch", "Find References": "arrow.triangle.turn.up.right.diamond",
        "Go to Test": "checkmark.seal", "Next Problem": "exclamationmark.triangle", "Previous Problem": "exclamationmark.triangle.fill", "Command Palette…": "command",
        // Build and Run
        "Build Project": "hammer", "Build Module": "hammer.fill", "Rebuild Project": "arrow.clockwise", "Build Artifacts": "shippingbox",
        "Run": "play.fill", "Debug": "ant", "Run Context Configuration": "play.circle", "Debug Context Configuration": "ant.circle", "Run with Coverage": "checkmark.shield",
        "Profile": "speedometer", "Stop": "stop.fill", "Run…": "play", "Debug…": "ant.fill", "Run Anything…": "bolt", "Edit Configurations…": "slider.horizontal.3",
        "Update Application": "arrow.triangle.2.circlepath.circle", "Attach to Process…": "paperclip", "Resume Program": "playpause.fill", "Pause Program": "pause.fill",
        "Step Over": "arrow.right.to.line", "Force Step Over": "arrow.right.to.line.compact", "Step Into": "arrow.down.to.line", "Force Step Into": "arrow.down.to.line.compact",
        "Smart Step Into": "arrow.down.right.circle", "Step Out": "arrow.up.to.line", "Run to Cursor": "text.cursor", "Force Run to Cursor": "text.cursor",
        "Show Execution Point": "scope", "Reset Frame": "arrow.counterclockwise", "Evaluate Expression…": "function", "Quick Evaluate Expression": "function",
        "Debugging Actions": "wrench.and.screwdriver", "Restart": "arrow.clockwise.circle", "Hide Coverage": "eye.slash.circle",
        "Toggle Line Breakpoint": "circle.fill", "Toggle Temporary Line Breakpoint": "circle.dashed", "Toggle Method Breakpoint": "m.circle",
        "Toggle Field Watchpoint": "f.circle", "Add Conditional Breakpoint…": "questionmark.circle", "View Breakpoints…": "list.bullet",
        "Show Goroutines": "point.3.connected.trianglepath.dotted", "Run Tests": "checkmark.circle", "Run Test at Cursor": "checkmark.circle.fill",
        "Run on Multiple Go Versions…": "square.stack.3d.up", "Environment": "globe", "Go Toolchain": "wrench", "Manage Environments…": "globe.badge.chevron.backward",
        "Manage Go Toolchains…": "wrench.and.screwdriver.fill",
        // Git
        "Commit…": "checkmark.circle.fill", "Push…": "arrow.up.circle", "Update Project…": "arrow.down.circle.fill", "Pull…": "arrow.down.circle", "Fetch": "arrow.triangle.2.circlepath.circle.fill",
        "Merge…": "arrow.triangle.merge", "Abort Merge": "xmark.circle", "Rebase…": "arrow.triangle.swap", "Abort Rebase": "xmark.circle.fill", "Continue Rebase": "play.circle.fill",
        "Skip Commit": "forward.end", "Resolve Conflicts…": "exclamationmark.arrow.triangle.2.circlepath", "Branches…": "arrow.triangle.branch", "New Branch…": "plus.circle",
        "New Tag…": "tag", "Reset HEAD…": "arrow.counterclockwise.circle", "New Worktree…": "rectangle.stack.badge.plus", "Worktrees…": "rectangle.stack",
        "Show Git Log": "list.bullet.rectangle", "Patch": "bandage", "Create Patch from Changes…": "doc.badge.gearshape", "Apply Patch…": "doc.badge.arrow.up",
        "Uncommitted Changes": "tray", "Stash Changes…": "tray.and.arrow.down", "Unstash Changes…": "tray.and.arrow.up", "Roll Back All…": "arrow.uturn.backward.circle",
        "Current File": "doc.text", "Show Diff": "plusminus", "Show History": "clock.arrow.2.circlepath", "Annotate (Blame)": "person.text.rectangle",
        "Stage / Unstage": "plus.forwardslash.minus", "Roll Back…": "arrow.uturn.backward.circle.fill", "Manage Remotes…": "network", "Clone…": "arrow.down.doc",
        "Continue Revert": "play.circle", "Abort Revert": "xmark.circle", "Continue Cherry-Pick": "play.circle", "Abort Cherry-Pick": "xmark.circle",
        // Window
        "Minimize": "minus.rectangle", "Zoom": "arrow.up.left.and.arrow.down.right.rectangle", "Tool Window Layouts": "rectangle.3.group", "Active Tool Window": "macwindow.badge.plus",
        "Editor Tabs": "square.on.square", "Show Next Tab": "chevron.right.square", "Show Previous Tab": "chevron.left.square", "New Window": "macwindow.badge.plus",
        "Merge All Project Windows": "rectangle.on.rectangle.angled", "Move Tab to New Window": "rectangle.portrait.and.arrow.right", "Next Project Tab": "chevron.right.2",
        "Previous Project Tab": "chevron.left.2", "Next Project Window": "arrow.right.square", "Previous Project Window": "arrow.left.square", "Bring All to Front": "square.3.layers.3d.top.filled",
        // Help
        "Search": "magnifyingglass", "Gobi Help": "questionmark.circle", "Release Notes": "doc.text", "Keyboard Shortcuts": "keyboard", "Check Setup…": "checkmark.shield",
        "Open Logs Folder": "folder.badge.gearshape", "Copy Diagnostics": "stethoscope", "Report an Issue…": "exclamationmark.bubble",
        // Context menus
        "New": "plus", "File…": "doc.badge.plus", "Folder…": "folder.badge.plus", "Go File…": "doc.text", "Go Test File…": "checkmark.circle", "Go Package…": "shippingbox",
        "Absolute Path": "link", "Path from Project Root": "point.topleft.down.curvedto.point.bottomright.up", "File Name": "textformat", "Jump to Source": "arrow.turn.down.right",
        "Replace in Files…": "arrow.2.squarepath", "Refactor": "wand.and.stars", "Rename…": "pencil", "Move…": "folder.badge.questionmark", "Delete…": "trash",
        "Create go.mod": "doc.badge.plus", "Go Mod Tidy": "sparkles", "Download Go Modules": "arrow.down.circle", "Close": "xmark", "Close Others": "xmark.square",
        "Close Tabs to the Right": "arrow.right.to.line.compact",
    ]
}
