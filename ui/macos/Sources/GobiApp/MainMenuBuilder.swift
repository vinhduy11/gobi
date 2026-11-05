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
            fill(menu, definition.entries, target: target, recentDelegate: recentDelegate)
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

    private static func fill(_ menu: NSMenu, _ entries: [MenuEntry], target: AnyObject, recentDelegate: NSMenuDelegate) {
        for entry in entries {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: selector(for: entry.action), keyEquivalent: "")
            item.target = isResponderChainAction(entry.action) ? nil : target
            if item.action == nil { item.isEnabled = false }
            applyShortcut(entry.shortcut, to: item)
            if entry.action == "openRecent" {
                let submenu = NSMenu(title: "Open Recent")
                submenu.delegate = recentDelegate
                item.submenu = submenu
                item.isEnabled = true
            } else if entry.action == "services" {
                let submenu = NSMenu(title: "Services")
                item.submenu = submenu
                NSApp.servicesMenu = submenu
                item.isEnabled = true
            } else if !entry.children.isEmpty {
                let submenu = NSMenu(title: entry.title)
                fill(submenu, entry.children, target: target, recentDelegate: recentDelegate)
                item.submenu = submenu
                item.isEnabled = true
            }
            menu.addItem(item)
        }
    }

    /// Actions the responder chain answers (text editing, window commands) rather than the app delegate.
    private static func isResponderChainAction(_ action: String?) -> Bool {
        ["undo", "redo", "cut", "copy", "paste", "selectAll", "minimize", "zoomWindow", "fullScreen", "bringAllToFront", "hide", "hideOthers", "quit", "about"].contains(action ?? "")
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
        case "formatDocument": return #selector(AppDelegate.formatDocument(_:))
        case "showShortcuts": return #selector(AppDelegate.showShortcuts(_:))
        case "toggleSidebar": return #selector(AppDelegate.toggleSidebar(_:))
        case "toggleBottomPanel": return #selector(AppDelegate.toggleBottomPanel(_:))
        case "fullScreen": return #selector(NSWindow.toggleFullScreen(_:))
        case "minimize": return #selector(NSWindow.performMiniaturize(_:))
        case "zoomWindow": return #selector(NSWindow.performZoom(_:))
        case "bringAllToFront": return #selector(NSApplication.arrangeInFront(_:))
        case "nextTab": return #selector(AppDelegate.nextTab(_:))
        case "previousTab": return #selector(AppDelegate.previousTab(_:))
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
        }
    }

    static func applyShortcut(_ shortcut: String, to item: NSMenuItem) {
        guard let equivalent = keyEquivalent(for: shortcut) else { return }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
    }
}
