import Testing
@testable import GobiModel

struct KeymapMigrationTests {
    @Test func overridesUnderOldMenuNamesMoveToTheNewOnes() {
        var old = KeymapOverrides()
        old.set("⌃⌘1", for: "Debug ▸ Start Debugging")
        old.set("⌃⌘2", for: "Debug ▸ Toggle Breakpoint")
        old.set("⌃⌘3", for: "Edit ▸ Find ▸ Find in Files…")
        old.set("⌃⌘4", for: "Window ▸ Show Next Tab")
        old.set("⌃⌘5", for: "Debug ▸ Restart")
        let migrated = KeymapMigration.migrate(old, from: 0)
        #expect(migrated.shortcut(for: "Run ▸ Debug", default: "") == "⌃⌘1")
        #expect(migrated.shortcut(for: "Run ▸ Toggle Line Breakpoint", default: "") == "⌃⌘2")
        #expect(migrated.shortcut(for: "Edit ▸ Find in Files…", default: "") == "⌃⌘3")
        #expect(migrated.shortcut(for: "Window ▸ Editor Tabs ▸ Show Next Tab", default: "") == "⌃⌘4")
        #expect(migrated.shortcut(for: "Run ▸ Debugging Actions ▸ Restart", default: "") == "⌃⌘5")
        #expect(!migrated.isCustom("Debug ▸ Start Debugging"))
    }

    @Test func aNewNameThatWasAlreadyCustomisedWins() {
        var old = KeymapOverrides()
        old.set("⌃⌘1", for: "Debug ▸ Start Debugging")
        old.set("⌃⌘9", for: "Run ▸ Debug")
        #expect(KeymapMigration.migrate(old, from: 0).shortcut(for: "Run ▸ Debug", default: "") == "⌃⌘9")
    }

    @Test func itRunsOnlyOnce() {
        var old = KeymapOverrides()
        old.set("⌃⌘1", for: "Debug ▸ Start Debugging")
        #expect(KeymapMigration.migrate(old, from: KeymapMigration.currentVersion) == old)
    }

    @Test func everyTargetNameIsAnItemOfTheCurrentMenu() {
        let ids = Set(KeymapItems.all.map(\.id))
        for target in KeymapMigration.renames.values { #expect(ids.contains(target), "\(target)") }
    }

    @Test func otherOverridesAreLeftAlone() {
        var old = KeymapOverrides()
        old.set("⌃⌘1", for: "Run ▸ Run Tests")
        #expect(KeymapMigration.migrate(old, from: 0) == old)
    }
}
