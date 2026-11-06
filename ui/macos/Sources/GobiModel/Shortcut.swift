// Shortcuts as the mock writes them ("⇧⌘N", "F12", "⌘⌫"), read into modifiers and a key, and the list the Keyboard Shortcuts
// window shows.

public struct Shortcut: Equatable {
    public enum Key: Equatable {
        case character(String)
        case function(Int)
        case returnKey
        case backspace
        case space
    }

    public var control = false
    public var option = false
    public var shift = false
    public var command = false
    public var key: Key

    /// nil for an empty string or modifiers with no key.
    public init?(parsing text: String) {
        var rest = Substring(text)
        var control = false, option = false, shift = false, command = false
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            switch first {
            case "⌃": control = true
            case "⌥": option = true
            case "⇧": shift = true
            default: command = true
            }
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        if rest.first == "F", let number = Int(rest.dropFirst()), (1 ... 20).contains(number) {
            key = .function(number)
        } else if rest == "↩" {
            key = .returnKey
        } else if rest == "⌫" {
            key = .backspace
        } else if rest == "Space" {
            key = .space
        } else if rest == "−" {
            key = .character("-")
        } else if rest.count == 1 {
            key = .character(rest.lowercased())
        } else {
            return nil
        }
    }
}

public struct ShortcutRow: Equatable {
    /// "Edit ▸ Find": the menu, and the submenu when there is one.
    public var menu: String
    public var title: String
    public var shortcut: String
    /// False when the feature behind the item is not built yet.
    public var isAvailable: Bool
}

public enum ShortcutList {
    /// Every menu item with a shortcut, in menu order, for the Keyboard Shortcuts window.
    public static func rows(overrides: KeymapOverrides = KeymapOverrides()) -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        func add(_ menu: String, _ entries: [MenuEntry]) {
            for entry in entries where !entry.isSeparator {
                let shortcut = overrides.shortcut(for: menu + " ▸ " + entry.title, default: entry.shortcut)
                if !shortcut.isEmpty {
                    rows.append(ShortcutRow(menu: menu, title: entry.title, shortcut: shortcut, isAvailable: entry.action != nil))
                }
                if !entry.children.isEmpty { add(menu + " ▸ " + entry.title, entry.children) }
            }
        }
        for definition in MenuSpec.all { add(definition.title, definition.entries) }
        return rows
    }
}

/// One menu item as the Keymap settings list it.
public struct KeymapItem: Equatable, Sendable {
    /// "Run ▸ Run", the key of an override.
    public let id: String
    public let title: String
    public let menu: String
    public let defaultShortcut: String
    /// False when the feature behind the item is not built yet (it cannot take a shortcut).
    public let isLive: Bool
}

public enum KeymapItems {
    /// Every menu item that has a shortcut or a feature behind it, in menu order.
    public static let all: [KeymapItem] = {
        var items: [KeymapItem] = []
        func add(_ menu: String, _ entries: [MenuEntry]) {
            for entry in entries where !entry.isSeparator {
                if entry.children.isEmpty, entry.action != nil || !entry.shortcut.isEmpty {
                    items.append(KeymapItem(id: menu + " ▸ " + entry.title, title: entry.title, menu: menu, defaultShortcut: entry.shortcut, isLive: entry.action != nil))
                }
                if !entry.children.isEmpty { add(menu + " ▸ " + entry.title, entry.children) }
            }
        }
        for definition in MenuSpec.all { add(definition.title, definition.entries) }
        return items
    }()
}
