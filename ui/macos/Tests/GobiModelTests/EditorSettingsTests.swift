import Testing
@testable import GobiModel

@Suite("Editor settings")
struct EditorSettingsTests {
    @Test func defaultsMatchTheMock() {
        let s = EditorSettings()
        #expect(s.fontName == "SF Mono" && s.fontSize == 13 && s.lineHeight == 1.4)
        #expect(s.indentWithTabs && s.tabWidth == 4 && s.showLineNumbers && !s.showInvisibles && !s.wrapLines)
        #expect(s.rulerColumn == 100 && s.autoSave == .afterDelay)
    }

    @Test func valuesOutsideTheListsAreBroughtBack() {
        var s = EditorSettings()
        s.fontSize = 3
        s.tabWidth = 5
        s.lineHeight = 9
        s.rulerColumn = 7
        let fixed = s.validated()
        #expect(fixed.fontSize == 11 && fixed.tabWidth == 4 && fixed.lineHeight == 1.6 && fixed.rulerColumn == 80)
        s.fontSize = 40
        #expect(s.validated().fontSize == 18)
    }

    @Test func noRulerIsAllowed() {
        var s = EditorSettings()
        s.rulerColumn = 0
        #expect(s.validated().rulerColumn == 0)
    }

    @Test func goFilesAlwaysIndentWithTabs() {
        var s = EditorSettings()
        s.indentWithTabs = false
        #expect(s.indentUnit(forLanguage: "go") == "\t")
        #expect(s.indentUnit(forLanguage: "json") == "    ")
        s.tabWidth = 2
        #expect(s.indentUnit(forLanguage: "markdown") == "  ")
        s.indentWithTabs = true
        #expect(s.indentUnit(forLanguage: "json") == "\t")
    }

    @Test func storedValuesRoundTrip() {
        var s = EditorSettings()
        s.fontSize = 16
        s.wrapLines = true
        s.autoSave = .onFocusLoss
        let again = EditorSettings.decode(s.encoded())
        #expect(again == s)
    }

    @Test func unreadableStoredDataGivesDefaults() {
        #expect(EditorSettings.decode("nope") == nil)
        #expect(EditorSettings.decodeOrDefault("nope") == EditorSettings())
    }
}
