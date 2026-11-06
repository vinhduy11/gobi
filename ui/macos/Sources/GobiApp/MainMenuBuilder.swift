import AppKit
import GobiModel

/// Turns `MenuSpec` (the Menus mock as data) into the real menu bar. An entry with no action is drawn disabled: it is in the
/// mock, but the feature behind it is not built yet.
enum MainMenuBuilder {
    static func build(target: AnyObject, recentDelegate: NSMenuDelegate) -> NSMenu {
        let bar = NSMenu()
        for (index, definition) in MenuSpec.all.enumerated() {
            let item = NSMenuItem()
            let menu = NSMenu(title: index == 0 ? "Gobi" : definition.title)
            fill(menu, definition.entries, menuPath: definition.title, target: target, recentDelegate: recentDelegate)
            item.submenu = menu
            bar.addItem(item)
            switch definition.title {
            case "Window": NSApp.windowsMenu = menu
            case "Help": NSApp.helpMenu = menu
            default: break
            }
        }
        return bar
    }

    private static func fill(_ menu: NSMenu, _ entries: [MenuEntry], menuPath: String, target: AnyObject, recentDelegate: NSMenuDelegate) {
        let keymap = AppPreferences.keymap
        for entry in entries {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: selector(for: entry.action), keyEquivalent: "")
            item.target = isResponderChainAction(entry.action) ? nil : target
            if item.action == nil { item.isEnabled = false }
            item.identifier = entry.action.map { NSUserInterfaceItemIdentifier($0) }
            applyShortcut(keymap.shortcut(for: menuPath + " ▸ " + entry.title, default: entry.shortcut), to: item)
            if entry.action == "openRecent" || entry.action == "recentFiles" {
                let submenu = NSMenu(title: entry.title)
                submenu.delegate = recentDelegate
                item.submenu = submenu
                item.isEnabled = true
            } else if entry.action == "services" {
                let submenu = NSMenu(title: "Services")
                item.submenu = submenu
                NSApp.servicesMenu = submenu
                item.isEnabled = true
            } else if entry.title == "Go Toolchain" || entry.title == "Environment" {
                let submenu = NSMenu(title: entry.title)
                submenu.delegate = recentDelegate   // filled from the front project each time it opens
                item.submenu = submenu
                item.isEnabled = true
            } else if !entry.children.isEmpty {
                let submenu = NSMenu(title: entry.title)
                fill(submenu, entry.children, menuPath: menuPath + " ▸ " + entry.title, target: target, recentDelegate: recentDelegate)
                item.submenu = submenu
                item.isEnabled = true
            }
            menu.addItem(item)
        }
    }

    /// Actions the responder chain answers (text editing, window commands) rather than the app delegate.
    private static func isResponderChainAction(_ action: String?) -> Bool {
        ["undo", "redo", "cut", "copy", "paste", "selectAll", "minimize", "zoomWindow", "fullScreen", "bringAllToFront", "hide", "hideOthers", "quit", "about", "startDictation", "emojiSymbols"].contains(action ?? "")
    }

    /// Runs a menu action by id, as choosing the menu item would (used by the Command Palette).
    static func perform(action: String, delegate: AnyObject) {
        guard let selector = selector(for: action) else { return }
        NSApp.sendAction(selector, to: isResponderChainAction(action) ? nil : delegate, from: nil)
    }

    private static func selector(for action: String?) -> Selector? {
        switch action {
        case "about": return #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        case "hide": return #selector(NSApplication.hide(_:))
        case "hideOthers": return #selector(NSApplication.hideOtherApplications(_:))
        case "quit": return #selector(NSApplication.terminate(_:))
        case "newProject": return #selector(AppDelegate.newProject(_:))
        case "open": return #selector(AppDelegate.openDocument(_:))
        case "clone": return #selector(AppDelegate.cloneRepository(_:))
        case "importCode": return #selector(AppDelegate.importCode(_:))
        case "closeTab": return #selector(AppDelegate.closeTab(_:))
        case "closeProject": return #selector(AppDelegate.closeProject(_:))
        case "save": return #selector(AppDelegate.saveFile(_:))
        case "saveAll": return #selector(AppDelegate.saveAll(_:))
        case "revealInFinder": return #selector(AppDelegate.revealInFinder(_:))
        case "undo": return Selector(("undo:"))
        case "redo": return Selector(("redo:"))
        case "cut": return #selector(NSText.cut(_:))
        case "copy": return #selector(NSText.copy(_:))
        case "paste": return #selector(NSText.paste(_:))
        case "selectAll": return #selector(NSText.selectAll(_:))
        case "find": return #selector(AppDelegate.showFind(_:))
        case "findNext": return #selector(AppDelegate.findNext(_:))
        case "findPrevious": return #selector(AppDelegate.findPrevious(_:))
        case "useSelection": return #selector(AppDelegate.useSelectionForFind(_:))
        case "goToDefinition": return #selector(AppDelegate.goToDefinition(_:))
        case "goToImplementation": return #selector(AppDelegate.goToImplementation(_:))
        case "formatDocument": return #selector(AppDelegate.formatDocument(_:))
        case "showShortcuts": return #selector(AppDelegate.showShortcuts(_:))
        case "run": return #selector(AppDelegate.runProject(_:))
        case "runTests": return #selector(AppDelegate.runTests(_:))
        case "runTestAtCursor": return #selector(AppDelegate.runTestAtCursor(_:))
        case "findReferences": return #selector(AppDelegate.findReferences(_:))
        case "renameSymbol": return #selector(AppDelegate.renameSymbol(_:))
        case "organizeImports": return #selector(AppDelegate.organizeImports(_:))
        case "codeActions": return #selector(AppDelegate.codeActions(_:))
        case "parameterInfo": return #selector(AppDelegate.parameterInfo(_:))
        case "goToFile": return #selector(AppDelegate.goToFile(_:))
        case "goToWorkspaceSymbol": return #selector(AppDelegate.goToWorkspaceSymbol(_:))
        case "goToFileSymbol": return #selector(AppDelegate.goToFileSymbol(_:))
        case "commandPalette": return #selector(AppDelegate.commandPalette(_:))
        case "manageToolchains": return #selector(AppDelegate.showToolchains(_:))
        case "showSetup": return #selector(AppDelegate.showSetup(_:))
        case "runMultiVersion": return #selector(AppDelegate.runMultiVersion(_:))
        case "debugStart": return #selector(AppDelegate.debugStart(_:))
        case "debugStop": return #selector(AppDelegate.debugStop(_:))
        case "debugRestart": return #selector(AppDelegate.debugRestart(_:))
        case "debugContinue": return #selector(AppDelegate.debugContinue(_:))
        case "debugStepOver": return #selector(AppDelegate.debugStepOver(_:))
        case "debugStepInto": return #selector(AppDelegate.debugStepInto(_:))
        case "debugStepOut": return #selector(AppDelegate.debugStepOut(_:))
        case "toggleBreakpoint": return #selector(AppDelegate.toggleBreakpoint(_:))
        case "debugConditional": return #selector(AppDelegate.debugConditional(_:))
        case "debugAttach": return #selector(AppDelegate.debugAttach(_:))
        case "debugGoroutines": return #selector(AppDelegate.debugGoroutines(_:))
        case "profile": return #selector(AppDelegate.profile(_:))
        case "newTerminal": return #selector(AppDelegate.newTerminal(_:))
        case "manageEnvironments": return #selector(AppDelegate.showEnvironments(_:))
        case "findInFiles": return #selector(AppDelegate.findInFiles(_:))
        case "settings": return #selector(AppDelegate.showSettings(_:))
        case "toggleInspector": return #selector(AppDelegate.toggleInspector(_:))
        case "toggleSidebar": return #selector(AppDelegate.toggleSidebar(_:))
        case "toggleBottomPanel": return #selector(AppDelegate.toggleBottomPanel(_:))
        case "fullScreen": return #selector(NSWindow.toggleFullScreen(_:))
        case "minimize": return #selector(NSWindow.performMiniaturize(_:))
        case "zoomWindow": return #selector(NSWindow.performZoom(_:))
        case "bringAllToFront": return #selector(NSApplication.arrangeInFront(_:))
        case "nextTab": return #selector(AppDelegate.nextTab(_:))
        case "previousTab": return #selector(AppDelegate.previousTab(_:))
        case "pastePlain": return #selector(AppDelegate.pastePlain(_:))
        case "copyPath": return #selector(AppDelegate.copyPath(_:))
        case "sortLines": return #selector(AppDelegate.sortLines(_:))
        case "reverseLines": return #selector(AppDelegate.reverseLines(_:))
        case "startDictation": return Selector(("startDictation:"))
        case "emojiSymbols": return #selector(NSApplication.orderFrontCharacterPalette(_:))
        case "resetFontSize": return #selector(AppDelegate.resetFontSize(_:))
        case "buildProject": return #selector(AppDelegate.buildProject(_:))
        case "buildModule": return #selector(AppDelegate.buildModule(_:))
        case "rebuildProject": return #selector(AppDelegate.rebuildProject(_:))
        case "stop": return #selector(AppDelegate.stopRunning(_:))
        case "evaluateExpression": return #selector(AppDelegate.evaluateExpression(_:))
        case "viewBreakpoints": return #selector(AppDelegate.viewBreakpoints(_:))
        case "gitCommit": return #selector(AppDelegate.gitCommit(_:))
        case "gitPush": return #selector(AppDelegate.gitPush(_:))
        case "gitUpdate": return #selector(AppDelegate.gitUpdate(_:))
        case "gitPull": return #selector(AppDelegate.gitPull(_:))
        case "gitFetch": return #selector(AppDelegate.gitFetch(_:))
        case "gitMerge": return #selector(AppDelegate.gitMerge(_:))
        case "gitAbortMerge": return #selector(AppDelegate.gitAbortMerge(_:))
        case "gitRebase": return #selector(AppDelegate.gitRebase(_:))
        case "gitAbortRebase": return #selector(AppDelegate.gitAbortRebase(_:))
        case "gitContinueRebase": return #selector(AppDelegate.gitContinueRebase(_:))
        case "gitSkipCommit": return #selector(AppDelegate.gitSkipCommit(_:))
        case "gitResolveConflicts": return #selector(AppDelegate.gitResolveConflicts(_:))
        case "gitBranches": return #selector(AppDelegate.gitBranches(_:))
        case "gitNewBranch": return #selector(AppDelegate.gitNewBranch(_:))
        case "gitNewTag": return #selector(AppDelegate.gitNewTag(_:))
        case "gitResetHead": return #selector(AppDelegate.gitResetHead(_:))
        case "gitNewWorktree": return #selector(AppDelegate.gitNewWorktree(_:))
        case "gitWorktrees": return #selector(AppDelegate.gitWorktrees(_:))
        case "gitShowLog": return #selector(AppDelegate.gitShowLog(_:))
        case "gitCreatePatch": return #selector(AppDelegate.gitCreatePatch(_:))
        case "gitApplyPatch": return #selector(AppDelegate.gitApplyPatch(_:))
        case "gitStash": return #selector(AppDelegate.gitStash(_:))
        case "gitUnstash": return #selector(AppDelegate.gitUnstash(_:))
        case "gitRollBackAll": return #selector(AppDelegate.gitRollBackAll(_:))
        case "gitFileDiff": return #selector(AppDelegate.gitFileDiff(_:))
        case "gitFileStage": return #selector(AppDelegate.gitFileStage(_:))
        case "gitFileRollBack": return #selector(AppDelegate.gitFileRollBack(_:))
        case "gitManageRemotes": return #selector(AppDelegate.gitManageRemotes(_:))
        case "gitClone": return #selector(AppDelegate.cloneRepository(_:))
        case "gitContinueRevert": return #selector(AppDelegate.gitContinueRevert(_:))
        case "gitAbortRevert": return #selector(AppDelegate.gitAbortRevert(_:))
        case "gitContinueCherryPick": return #selector(AppDelegate.gitContinueCherryPick(_:))
        case "gitAbortCherryPick": return #selector(AppDelegate.gitAbortCherryPick(_:))
        case "newWindow": return #selector(AppDelegate.newWindow(_:))
        case "nextProjectWindow": return #selector(AppDelegate.nextProjectWindow(_:))
        case "previousProjectWindow": return #selector(AppDelegate.previousProjectWindow(_:))
        default: return nil   // "openRecent" and "services" are submenus, filled elsewhere
        }
    }

    /// The key equivalent AppKit wants for a mock shortcut, and its modifiers; nil when the text is not a shortcut.
    static func keyEquivalent(for shortcut: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let parsed = Shortcut(parsing: shortcut) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if parsed.control { modifiers.insert(.control) }
        if parsed.option { modifiers.insert(.option) }
        if parsed.shift { modifiers.insert(.shift) }
        if parsed.command { modifiers.insert(.command) }
        switch parsed.key {
        case .character(let text): return (text, modifiers)
        case .function(let number):
            guard let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) else { return nil }
            return (String(Character(scalar)), modifiers)
        case .returnKey: return ("\r", modifiers)
        case .backspace: return ("\u{8}", modifiers)
        case .space: return (" ", modifiers)
        }
    }

    static func applyShortcut(_ shortcut: String, to item: NSMenuItem) {
        guard let equivalent = keyEquivalent(for: shortcut) else { return }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
    }
}
