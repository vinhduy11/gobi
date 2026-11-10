import Testing
@testable import GobiModel

@Suite("App themes")
struct AppThemeTests {
    @Test func theSevenThemesAreListedInTheDropdownOrder() {
        #expect(AppTheme.allCases.map(\.title) == ["Islands Light", "Islands Dark", "High Contrast", "Solarized Light", "Solarized Dark", "One Light", "One Dark"])
        #expect(AppTheme.allCases.filter(\.isDark).map(\.title) == ["Islands Dark", "High Contrast", "Solarized Dark", "One Dark"])
    }

    @Test func everyThemeIsReadable() {
        for theme in AppTheme.allCases {
            let p = theme.palette
            #expect(p.text.contrast(with: p.editor) >= 3.5, "\(theme.title) text on editor")
            #expect(p.text.contrast(with: p.window) >= 3.0, "\(theme.title) text on window")
            #expect(p.keyword.contrast(with: p.editor) >= 2.5, "\(theme.title) keyword")
            #expect(p.string.contrast(with: p.editor) >= 2.5, "\(theme.title) string")
            #expect(p.comment.contrast(with: p.editor) >= 1.8, "\(theme.title) comment")
        }
    }

    @Test func darkThemesHaveADarkEditor() {
        for theme in AppTheme.allCases { #expect((theme.palette.editor.luminance < 0.2) == theme.isDark, "\(theme.title)") }
    }

    @Test func syncWithOSKeepsAThemeOfTheSystemsBrightness() {
        #expect(AppTheme.resolved(selected: .solarizedDark, syncWithOS: true, systemIsDark: true) == .solarizedDark)
        #expect(AppTheme.resolved(selected: .solarizedDark, syncWithOS: true, systemIsDark: false) == .oneLight)
        #expect(AppTheme.resolved(selected: .solarizedLight, syncWithOS: true, systemIsDark: true) == .oneDark)
        #expect(AppTheme.resolved(selected: .solarizedLight, syncWithOS: true, systemIsDark: false) == .solarizedLight)
        #expect(AppTheme.resolved(selected: .highContrast, syncWithOS: false, systemIsDark: false) == .highContrast)
    }

    @Test func hexColoursParseAndPrint() {
        #expect(RGB(hex: "#4D78CC") == RGB(0x4D, 0x78, 0xCC))
        #expect(RGB(hex: "4d78cc") == RGB(0x4D, 0x78, 0xCC))
        #expect(RGB(hex: "#rrggbb") == nil)
        #expect(RGB(hex: "#12345") == nil)
        #expect(RGB(0x4D, 0x78, 0xCC).hex == "#4D78CC")
    }

    @Test func anAccentRoundTripsThroughItsStoredText() {
        for accent in [AccentChoice.blue, .teal, .purple, .orange, .custom(RGB(1, 2, 3))] {
            #expect(AccentChoice(encoded: accent.encoded) == accent)
        }
        #expect(AccentChoice(encoded: "nonsense") == nil)
        #expect(AccentChoice.custom(RGB(1, 2, 3)).encoded == "#010203")
    }

    @Test func settingsRoundTripAndFallBackToDefaults() {
        var s = ThemeSettings()
        #expect(s.theme == .oneDark && !s.syncWithOS && s.editorScheme == nil && s.accent == .blue && !s.differentToolWindowBackground)
        s.theme = .solarizedLight; s.syncWithOS = true; s.editorScheme = .oneDark; s.accent = .custom(RGB(9, 9, 9)); s.differentToolWindowBackground = true
        #expect(ThemeSettings.decodeOrDefault(s.encoded()) == s)
        #expect(ThemeSettings.decodeOrDefault("") == ThemeSettings())
        #expect(ThemeSettings.decodeOrDefault("theme=nope\naccent=zzz") == ThemeSettings())
    }

    @Test func aChosenThemeShowsAsChosenByDefault() {
        let s = ThemeSettings()
        #expect(s.effectiveTheme(systemIsDark: false) == .oneDark)
        #expect(s.effectiveTheme(systemIsDark: true) == .oneDark)
    }

    @Test func theEditorSchemeOverridesOnlyTheEditorColours() {
        var s = ThemeSettings()
        s.theme = .oneLight; s.syncWithOS = false; s.editorScheme = .oneDark
        #expect(s.effectiveTheme(systemIsDark: false) == .oneLight)
        #expect(s.editorPalette(systemIsDark: false) == AppTheme.oneDark.palette)
        s.editorScheme = nil
        #expect(s.editorPalette(systemIsDark: false) == AppTheme.oneLight.palette)
    }

    @Test func aDifferentToolWindowBackgroundIsLighterInDarkAndDarkerInLight() {
        for theme in AppTheme.allCases {
            let p = theme.palette
            for (base, alt) in [(p.editor, p.alternateToolWindow), (p.bottomPanel, p.alternateBottomPanel)] {
                #expect(alt != base)
                #expect(theme.isDark ? alt.luminance > base.luminance : alt.luminance < base.luminance, "\(theme.title)")
            }
        }
    }

    @Test func theTabStripIsDarkerThanTheEditorOnlyInSolarizedDark() {
        #expect(AppTheme.solarizedDark.tabStrip == RGB(0x092531))
        for theme in AppTheme.allCases where theme != .solarizedDark { #expect(theme.tabStrip == theme.palette.editor, "\(theme.title)") }
    }

    @Test func solarizedThemesUseTheSolarizedTerminalColours() {
        for theme in [AppTheme.solarizedDark, .solarizedLight] {
            let ansi = TerminalPalette.forTheme(theme).ansi
            #expect(ansi.count == 16)
            #expect(ansi[1] == RGB(0xDC322F) && ansi[2] == RGB(0x859900) && ansi[3] == RGB(0xB58900) && ansi[4] == RGB(0x268BD2), "\(theme.title)")
            #expect(ansi[5] == RGB(0xD33682) && ansi[6] == RGB(0x2AA198), "\(theme.title)")
        }
        #expect(TerminalPalette.forTheme(.oneDark) === TerminalPalette.dark)
        #expect(TerminalPalette.forTheme(.oneLight) === TerminalPalette.light)
    }

    @Test func solarizedDarkMatchesTheJetBrainsColoursSampledFromItsScreen() {
        let p = AppTheme.solarizedDark.palette
        #expect(p.window == RGB(0x173541))   // the frame, lighter than the islands in this theme
        #expect(p.editor == RGB(0x0E2A35))
        #expect(p.text == RGB(0x839496))
        #expect(AppTheme.solarizedDark.uiText == RGB(0x93A1A1))   // the tree and tab labels are bluer than the code
        #expect(AppTheme.oneDark.uiText == RGB(0xC8CFDC))
        for theme in [AppTheme.oneLight, .islandsDark] { #expect(theme.uiText == theme.palette.text) }
        #expect(p.keyword == RGB(0x859900) && p.string == RGB(0x2AA198) && p.builtin == RGB(0x268BD2) && p.number == RGB(0x2AA198))
    }

    @Test func theOtherThemesMatchTheJetBrainsColoursSampledFromTheirScreens() {
        let il = AppTheme.islandsLight.palette
        #expect(il.window == RGB(0xE8E9ED) && il.editor == RGB(0xFFFFFF) && il.bottomPanel == RGB(0xF7F8F9))
        let hc = AppTheme.highContrast.palette
        #expect(hc.window == RGB(0x1A1B1E) && hc.editor == RGB(0x000000) && hc.bottomPanel == RGB(0x0E0F11) && hc.text == RGB(0xD8D9DD))
        #expect(AppTheme.highContrast.uiText == RGB(0xFFFFFF))
        let sl = AppTheme.solarizedLight.palette
        #expect(sl.window == RGB(0xECE7D6) && sl.editor == RGB(0xFCF6E5))
        #expect(AppTheme.oneLight.palette.window == RGB(0xE9E9EA))
        let id = AppTheme.islandsDark.palette
        #expect(id.window == RGB(0x26282C) && id.editor == RGB(0x191A1C))
        // The terminal and bottom panel are the editor's colour except where the theme draws them a shade off.
        for theme in [AppTheme.oneDark, .oneLight, .solarizedDark, .solarizedLight, .islandsDark] { #expect(theme.palette.bottomPanel == theme.palette.editor, "\(theme.title)") }
    }

    @Test func iconsAreGreyInTheLightThemesAndTheTextColourInTheDarkOnes() {
        #expect(AppTheme.islandsLight.icon == RGB(0x6C707E))
        #expect(AppTheme.oneLight.icon == RGB(0x696C77))
        for theme in [AppTheme.oneDark, .solarizedDark, .highContrast] { #expect(theme.icon == theme.palette.text, "\(theme.title)") }
    }

    @Test func themesColourTypesFunctionsAndParametersAsJetBrainsDoes() {
        let od = AppTheme.oneDark.palette.semantic
        #expect(od.type == RGB(0xE5C07B) && od.function == RGB(0x61AFEF) && od.parameter == RGB(0xE06C75) && od.property == RGB(0xE06C75))
        #expect(od.constant == RGB(0xD19A66) && od.annotation == RGB(0xE5C07B))
        let ol = AppTheme.oneLight.palette.semantic
        #expect(ol.type == RGB(0xC18401) && ol.function == RGB(0x4078F2) && ol.parameter == RGB(0xE45649) && ol.annotation == RGB(0x986801))
        let sd = AppTheme.solarizedDark.palette.semantic, sl = AppTheme.solarizedLight.palette.semantic
        for s in [sd, sl] { #expect(s.type == RGB(0xB58900) && s.function == RGB(0x268BD2) && s.parameter == RGB(0x268BD2) && s.annotation == RGB(0xCB4B16)) }
        // Islands and High Contrast draw these in the plain text colour; only annotations stand out.
        for theme in [AppTheme.islandsDark, .islandsLight, .highContrast] {
            let p = theme.palette
            #expect(p.semantic.type == p.text && p.semantic.function == p.text && p.semantic.parameter == p.text && p.semantic.property == p.text, "\(theme.title)")
        }
        #expect(AppTheme.islandsDark.palette.semantic.annotation == RGB(0xBBB529))
        #expect(AppTheme.islandsLight.palette.semantic.annotation == RGB(0x9E880D))
        #expect(AppTheme.highContrast.palette.semantic.annotation == RGB(0xDFDA8B))
    }

    @Test func everySemanticColourIsReadableOnItsEditor() {
        for theme in AppTheme.allCases {
            let p = theme.palette, s = p.semantic
            for (name, colour) in [("type", s.type), ("function", s.function), ("parameter", s.parameter), ("property", s.property), ("constant", s.constant), ("namespace", s.namespace), ("annotation", s.annotation)] {
                #expect(colour.contrast(with: p.editor) >= 2.5, "\(theme.title) \(name)")
            }
        }
    }

    @Test func oneDarkMatchesTheJetBrainsColoursSampledFromItsScreen() {
        let p = AppTheme.oneDark.palette
        #expect(p.window == RGB(0x22252A))   // the frame around the islands
        #expect(p.editor == RGB(0x292C33))   // the editor and tool window islands
        #expect(AccentChoice.blue.rgb == RGB(0x4670DA))
    }
}
