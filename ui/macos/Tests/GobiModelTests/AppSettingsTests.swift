import Testing
@testable import GobiModel

@Suite("App settings")
struct AppSettingsTests {
    @Test func generalDefaultsAndRoundTrip() {
        var s = GeneralSettings()
        #expect(s.onLaunch == .reopenLast && s.recentLimit == 10)
        s.onLaunch = .welcome
        s.recentLimit = 20
        #expect(GeneralSettings.decodeOrDefault(s.encoded()) == s)
        #expect(GeneralSettings.decodeOrDefault("junk") == GeneralSettings())
        var odd = GeneralSettings()
        odd.recentLimit = 7
        #expect(odd.validated().recentLimit == 5 || odd.validated().recentLimit == 10)
        odd.recentLimit = 500
        #expect(odd.validated().recentLimit == 20)
    }

    @Test func terminalDefaultsRoundTripAndValidation() {
        var s = TerminalSettings()
        #expect(s.fontSize == 12 && s.cursor == .block && s.blink && s.optionAsMeta == false && s.bell == .sound)
        s.fontSize = 16; s.cursor = .bar; s.blink = false; s.optionAsMeta = true; s.bell = .off
        #expect(TerminalSettings.decodeOrDefault(s.encoded()) == s)
        var big = TerminalSettings()
        big.fontSize = 99
        #expect(big.validated().fontSize == 18)
        big.fontSize = 2
        #expect(big.validated().fontSize == 11)
    }

    @Test func gitDefaultsAndRoundTrip() {
        var s = GitSettings()
        #expect(s.showColours && s.showGutterMarks && s.refreshOnFocus && s.warnLongSubject)
        s.showColours = false; s.showGutterMarks = false; s.refreshOnFocus = false; s.warnLongSubject = false
        #expect(GitSettings.decodeOrDefault(s.encoded()) == s)
    }

    @Test func aLongFirstLineIsWarnedAboutOnlyWhenAsked() {
        #expect(GitSettings.subjectWarning(for: String(repeating: "x", count: 60), enabled: true) != nil)
        #expect(GitSettings.subjectWarning(for: String(repeating: "x", count: 60), enabled: false) == nil)
        #expect(GitSettings.subjectWarning(for: "short\n" + String(repeating: "y", count: 200), enabled: true) == nil)
        #expect(GitSettings.subjectWarning(for: "", enabled: true) == nil)
    }

    @Test func keymapOverridesRoundTripAndFindConflicts() {
        var map = KeymapOverrides()
        map.set("⌥⌘R", for: "Run ▸ Run")
        map.set("⌘9", for: "Go ▸ Back")
        #expect(KeymapOverrides.decode(map.encoded()) == map)
        #expect(map.shortcut(for: "Run ▸ Run", default: "⌘R") == "⌥⌘R")
        #expect(map.shortcut(for: "Run ▸ Run Tests", default: "⌘U") == "⌘U")
        let all = [("Run ▸ Run", "⌘R"), ("Run ▸ Run Tests", "⌘U"), ("Go ▸ Back", "⌘["), ("Edit ▸ Find", "⌘F")]
        #expect(map.conflict(for: "⌘U", changing: "Go ▸ Back", among: all) == "Run ▸ Run Tests")
        #expect(map.conflict(for: "⌘F", changing: "Edit ▸ Find", among: all) == nil)
        #expect(map.conflict(for: "⌘R", changing: "Run ▸ Run Tests", among: all) == nil)   // ⌘R is no longer Run: it was moved to ⌥⌘R
        map.reset("Run ▸ Run")
        #expect(map.shortcut(for: "Run ▸ Run", default: "⌘R") == "⌘R")
        #expect(map.isCustom("Go ▸ Back"))
        map.resetAll()
        #expect(!map.isCustom("Go ▸ Back"))
    }

    @Test func glyphsAreBuiltFromAKeyAndModifiers() {
        #expect(ShortcutGlyphs.make(key: "r", command: true, option: true, control: false, shift: false) == "⌥⌘R")
        #expect(ShortcutGlyphs.make(key: "u", command: true, option: false, control: false, shift: true) == "⇧⌘U")
        #expect(ShortcutGlyphs.make(key: "`", command: false, option: false, control: true, shift: true) == "⌃⇧`")
        #expect(ShortcutGlyphs.make(key: "\u{F704}", command: false, option: false, control: false, shift: false) == "F1")
        #expect(ShortcutGlyphs.make(key: "x", command: false, option: false, control: false, shift: false) == nil)   // a bare letter is not a shortcut
    }
}

@Suite("Trusted folders")
struct TrustRemovalTests {
    @Test func aFolderCanBeRemovedFromTheTrustList() {
        var list = TrustList()
        list.trust(path: "/Users/me/Work")
        list.trust(path: "/Users/me/Other/")
        list.remove(path: "/Users/me/Work/")
        #expect(list.paths == ["/Users/me/Other"] && !list.isTrusted(path: "/Users/me/Work/proj"))
        list.remove(path: "/nope")
        #expect(list.paths == ["/Users/me/Other"])
    }
}

@Suite("Keymap items")
struct KeymapItemsTests {
    @Test func everyLiveMenuItemIsListedWithItsDefaultShortcut() {
        let items = KeymapItems.all
        let run = items.first { $0.id == "Run ▸ Run" }
        #expect(run?.title == "Run" && run?.defaultShortcut == "⌘R" && run?.isLive == true)
        #expect(items.contains { $0.id == "Go ▸ Go to File…" })
        #expect(items.first { $0.id == "Edit ▸ Find ▸ Find…" }?.defaultShortcut == "⌘F")
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func rowsFollowTheOverrides() {
        var map = KeymapOverrides()
        map.set("⌥⌘R", for: "Run ▸ Run")
        let rows = ShortcutList.rows(overrides: map)
        #expect(rows.first { $0.menu == "Run" && $0.title == "Run" }?.shortcut == "⌥⌘R")
        #expect(rows.first { $0.menu == "Run" && $0.title == "Run Tests" }?.shortcut == "⌘U")
    }
}

@Suite("Language status and file facts")
struct LanguageStatusTests {
    @Test func theStatusBarNamesTheLanguageService() {
        #expect(StatusBar.serviceText(language: "go", connected: true, restricted: false) == "gopls ready")
        #expect(StatusBar.serviceText(language: "go", connected: false, restricted: false) == "gopls starting…")
        #expect(StatusBar.serviceText(language: "json", connected: true, restricted: false) == "JSON · built-in language service")
        #expect(StatusBar.serviceText(language: "markdown", connected: false, restricted: false) == "Markdown · starting…")
        #expect(StatusBar.serviceText(language: "plaintext", connected: true, restricted: false) == "")
    }

    @Test func theRightHandLabelNamesTheLanguageAndProblems() {
        #expect(StatusBar.languageLabel(language: "go", goVersion: "1.26.5", problems: 0) == "Go 1.26.5")
        #expect(StatusBar.languageLabel(language: "json", goVersion: "1.26.5", problems: 1) == "JSON · 1 problem")
        #expect(StatusBar.languageLabel(language: "json", goVersion: nil, problems: 0) == "JSON")
        #expect(StatusBar.languageLabel(language: "markdown", goVersion: nil, problems: 3) == "Markdown · 3 problems")
        #expect(StatusBar.languageLabel(language: "plaintext", goVersion: "1.26.5", problems: 0) == "Plain text")
    }

    @Test func markdownHeadingsAreCounted() {
        #expect(FileFacts.headingCount("# a\n\ntext\n## b\n```\n# not a heading\n```\n### c\nSetext\n===\n") == 4)
        #expect(FileFacts.headingCount("") == 0)
    }

    @Test func jsonIndentIsReadFromTheFile() {
        #expect(FileFacts.jsonIndent("{\n  \"a\": 1\n}\n") == "2 spaces")
        #expect(FileFacts.jsonIndent("{\n    \"a\": 1\n}\n") == "4 spaces")
        #expect(FileFacts.jsonIndent("{\n\t\"a\": 1\n}\n") == "tabs")
        #expect(FileFacts.jsonIndent("{\"a\":1}") == "none")
    }

    @Test func previewModesRoundTrip() {
        #expect(MarkdownPreviewMode(rawValue: "split") == .split)
        #expect(MarkdownPreviewMode.allCases.map(\.title) == ["Source", "Split", "Preview"])
        #expect(MarkdownPreviewMode.split.inspectorText == "Side by side")
        #expect(MarkdownPreviewMode.source.showsPreview == false && MarkdownPreviewMode.preview.showsSource == false && MarkdownPreviewMode.split.showsSource && MarkdownPreviewMode.split.showsPreview)
    }

    @Test func thePreviewPageCarriesNoScriptsAndAContentPolicy() {
        let page = MarkdownPreviewPage.wrap(html: "<h1>hello</h1>")
        #expect(page.contains("<h1>hello</h1>") && page.contains("Content-Security-Policy") && page.contains("default-src 'none'"))
        #expect(!page.lowercased().contains("<script"))
        #expect(MarkdownPreviewPage.opensExternally(url: "https://go.dev") && MarkdownPreviewPage.opensExternally(url: "http://localhost:8080/x"))
        #expect(!MarkdownPreviewPage.opensExternally(url: "javascript:alert(1)") && !MarkdownPreviewPage.opensExternally(url: "file:///etc/passwd") && !MarkdownPreviewPage.opensExternally(url: "about:blank"))
    }
}
