import Testing
@testable import GobiModel

@Suite("Terminal fonts") struct TerminalFontsTests {
    @Test func theChoicesAreTheBuiltInFontsPlusInstalledNerdFonts() {
        let installed = ["Helvetica", "MesloLGS NF", "Menlo", "JetBrainsMono Nerd Font Mono", "Times"]
        let choices = TerminalFonts.choices(installedFamilies: installed)
        #expect(choices.prefix(4) == ["SF Mono", "Menlo", "Monaco", "Courier New"])
        #expect(choices.contains("MesloLGS NF"))
        #expect(choices.contains("JetBrainsMono Nerd Font Mono"))
        #expect(!choices.contains("Helvetica"))
        #expect(choices.filter { $0 == "Menlo" }.count == 1)
    }

    @Test func theIconFallbackChainKeepsTheKnownOrderThenOtherNerdFonts() {
        let installed = ["Hack Nerd Font Mono", "Symbols Nerd Font Mono", "SomeFont Nerd Font", "Menlo"]
        let chain = TerminalFonts.fallbackChain(installedFamilies: installed)
        #expect(chain == ["Symbols Nerd Font Mono", "Hack Nerd Font Mono", "SomeFont Nerd Font"])
    }

    @Test func noNerdFontMeansNoChain() {
        #expect(TerminalFonts.fallbackChain(installedFamilies: ["Menlo", "Helvetica"]).isEmpty)
    }

    @Test func theFontNameIsStoredAndDefaultsToSFMono() {
        var settings = TerminalSettings()
        #expect(settings.fontName == "SF Mono")
        settings.fontName = "MesloLGS NF"
        #expect(TerminalSettings.decodeOrDefault(settings.encoded()).fontName == "MesloLGS NF")
        #expect(TerminalSettings.decodeOrDefault("fontSize=12").fontName == "SF Mono")
    }

    @Test func theHintNamesTheIconFontOrSaysHowToGetOne() {
        #expect(TerminalFonts.iconHint(chain: ["MesloLGS NF"]) == "Icons: MesloLGS NF")
        #expect(TerminalFonts.iconHint(chain: []).hasPrefix("Icons: none found"))
    }
}
