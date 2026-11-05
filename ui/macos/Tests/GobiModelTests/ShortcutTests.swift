import Testing
@testable import GobiModel

@Suite("Keyboard shortcuts")
struct ShortcutTests {
    @Test func modifiersAndALetter() throws {
        let shortcut = try #require(Shortcut(parsing: "⇧⌘N"))
        #expect(shortcut.shift && shortcut.command && !shortcut.option && !shortcut.control)
        #expect(shortcut.key == .character("n"))
    }

    @Test func allFourModifiers() throws {
        let shortcut = try #require(Shortcut(parsing: "⌃⌥⇧⌘K"))
        #expect(shortcut.control && shortcut.option && shortcut.shift && shortcut.command)
    }

    @Test func functionKeys() throws {
        #expect(try #require(Shortcut(parsing: "F12")).key == .function(12))
        let withModifier = try #require(Shortcut(parsing: "⇧⌘F5"))
        #expect(withModifier.key == .function(5) && withModifier.shift && withModifier.command)
    }

    @Test func aLetterFThatIsNotAFunctionKey() throws {
        #expect(try #require(Shortcut(parsing: "⌥⇧F")).key == .character("f"))
    }

    @Test func symbolsTheMockWritesAsGlyphs() throws {
        #expect(try #require(Shortcut(parsing: "⌘−")).key == .character("-"))
        #expect(try #require(Shortcut(parsing: "⌘,")).key == .character(","))
        #expect(try #require(Shortcut(parsing: "⌘\\")).key == .character("\\"))
        #expect(try #require(Shortcut(parsing: "↩")).key == .returnKey)
        #expect(try #require(Shortcut(parsing: "⌘⌫")).key == .backspace)
    }

    @Test func emptyOrOnlyModifiersIsNotAShortcut() {
        #expect(Shortcut(parsing: "") == nil)
        #expect(Shortcut(parsing: "⌘") == nil)
    }

    @Test func everyShortcutInTheSpecsParses() {
        let all = MenuSpec.all.flatMap(\.entries) + MenuSpec.all.flatMap(\.entries).flatMap(\.children)
            + ContextMenuSpec.editor + ContextMenuSpec.explorer + ContextMenuSpec.tab
        for entry in all where !entry.shortcut.isEmpty {
            #expect(Shortcut(parsing: entry.shortcut) != nil, "\(entry.title): \(entry.shortcut)")
        }
    }

    @Test func theListGroupsByMenuAndMarksWhatIsNotBuilt() {
        let rows = ShortcutList.rows()
        let find = rows.first { $0.title == "Find…" }
        #expect(find?.menu == "Edit ▸ Find" && find?.shortcut == "⌘F" && find?.isAvailable == true)
        let debug = rows.first { $0.title == "Start Debugging" }
        #expect(debug?.isAvailable == false)
        #expect(!rows.contains { $0.shortcut.isEmpty })
    }
}
