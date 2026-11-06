import AppKit
import GobiModel

/// One menu item's behaviour. The item keeps it alive through `representedObject` (an item's `target` is weak).
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    // Not named `perform`: that collides with NSObject.perform(_:) and the selector resolves to the wrong method.
    @objc func fire(_ item: NSMenuItem) { run() }
}

/// Builds the right-click menus from `ContextMenuSpec`. An entry shows enabled only when `handlers` has its action; the
/// text-editing items go through the responder chain so the text view answers them itself.
enum ContextMenus {
    private static let responderChain: [String: Selector] = [
        "cut": #selector(NSText.cut(_:)), "copy": #selector(NSText.copy(_:)), "paste": #selector(NSText.paste(_:)), "selectAll": #selector(NSText.selectAll(_:)),
    ]

    static func build(_ entries: [MenuEntry], handlers: [String: () -> Void]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            MainMenuBuilder.applyShortcut(entry.shortcut, to: item)
            if !entry.children.isEmpty {
                // A submenu is enabled when something in it is.
                let submenu = build(entry.children, handlers: handlers)
                item.submenu = submenu
                item.isEnabled = submenu.items.contains { $0.isEnabled }
            } else if let action = entry.action, let selector = responderChain[action] {
                item.action = selector
                item.isEnabled = true
            } else if let action = entry.action, let run = handlers[action] {
                let behaviour = MenuAction(run)
                item.action = #selector(MenuAction.fire(_:))
                item.target = behaviour
                item.representedObject = behaviour
                item.isEnabled = true
            } else {
                item.isEnabled = false   // in the mock, no feature behind it yet
            }
            menu.addItem(item)
        }
        return menu
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The explorer's outline view, asking its host for the menu of the row under a right-click.
final class ExplorerOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    /// F4 (Jump to Source) on the selected rows.
    var onJumpToSource: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 118 { onJumpToSource?() } else { super.keyDown(with: event) }   // 118 is F4
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuProvider?(row)
    }
}
