import Testing
@testable import GobiModel

@Suite("Menu icons")
struct MenuIconsTests {
    private func titles(_ entries: [MenuEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            entry.isSeparator ? [] : [entry.title] + titles(entry.children)
        }
    }

    private var everyTitle: [String] {
        titles(MenuSpec.all.flatMap(\.entries)) + titles(ContextMenuSpec.editor) + titles(ContextMenuSpec.explorer) + titles(ContextMenuSpec.tab)
    }

    @Test func everyMenuItemHasAnIcon() {
        let missing = Set(everyTitle.filter { MenuIcons.symbol(for: $0) == nil })
        #expect(missing.isEmpty, "no icon for: \(missing.sorted())")
    }

    @Test func iconNamesAreNeverEmptyAndAnUnknownTitleHasNone() {
        #expect(everyTitle.allSatisfy { !(MenuIcons.symbol(for: $0) ?? "x").isEmpty })
        #expect(MenuIcons.symbol(for: "No Such Item") == nil)
    }

    @Test func theTableHoldsNothingThatNoMenuUses() {
        let used = Set(everyTitle)
        let stale = MenuIcons.titles.filter { !used.contains($0) }
        #expect(stale.isEmpty, "unused: \(stale.sorted())")
    }

    @Test func sameWordsGetTheSameIconEverywhere() {
        // "Copy Path" sits in two submenus and "Close" in two menus; one title, one icon.
        #expect(MenuIcons.symbol(for: "Copy Path") != nil && MenuIcons.symbol(for: "Close Tab") != nil)
    }
}
