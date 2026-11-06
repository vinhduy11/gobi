import AppKit
import GobiModel

/// Puts the icon at the start of a menu item. The names live in `MenuIcons` (by title); items made from data at run time, such
/// as branches and recent projects, name their symbol directly.
enum MenuIconImage {
    /// The icon of a menu title from `MenuIcons`, or nil when the table has none or the symbol does not exist on this macOS.
    static func image(named symbol: String) -> NSImage? { NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }

    @discardableResult
    static func apply(to item: NSMenuItem, title: String) -> NSMenuItem {
        if let symbol = MenuIcons.symbol(for: title) { item.image = image(named: symbol) }
        return item
    }

    @discardableResult
    static func set(_ symbol: String, on item: NSMenuItem) -> NSMenuItem {
        item.image = image(named: symbol)
        return item
    }

    /// Titles in `MenuIcons` whose symbol name macOS does not know, for the self-test.
    static var unknownSymbols: [String] { MenuIcons.titles.filter { MenuIcons.symbol(for: $0).map { image(named: $0) == nil } ?? false }.sorted() }
}
