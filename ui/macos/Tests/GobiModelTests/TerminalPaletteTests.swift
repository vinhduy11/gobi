import Testing
@testable import GobiModel

@Suite("Terminal colours")
struct TerminalPaletteTests {
    @Test(arguments: [TerminalPalette.dark, TerminalPalette.light])
    func thePaletteHasSixteenDistinctColours(palette: TerminalPalette) {
        #expect(palette.ansi.count == 16)
        #expect(Set(palette.ansi).count == 16)
    }

    @Test(arguments: [TerminalPalette.dark, TerminalPalette.light])
    func textIsReadableOnTheBackground(palette: TerminalPalette) {
        #expect(palette.foreground.contrast(with: palette.background) >= 4.5)
    }

    @Test(arguments: [TerminalPalette.dark, TerminalPalette.light])
    func everyColouredAnsiColourIsReadableOnTheBackground(palette: TerminalPalette) {
        // Indices 0 and 8 are black and dark grey, which a theme may keep close to its background; the rest carry meaning.
        for index in [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15] where !(palette === TerminalPalette.light && [7, 15].contains(index)) {
            #expect(palette.ansi[index].contrast(with: palette.background) >= 2.5, "ansi \(index)")
        }
    }

    @Test func theDarkBackgroundIsDarkAndTheLightOneIsLight() {
        #expect(TerminalPalette.dark.background.luminance < 0.1)
        #expect(TerminalPalette.light.background.luminance > 0.8)
    }

    @Test func theChoiceFollowsTheAppearance() {
        #expect(TerminalPalette.forAppearance(isDark: true) === TerminalPalette.dark)
        #expect(TerminalPalette.forAppearance(isDark: false) === TerminalPalette.light)
    }

    @Test func aColourIsWrittenAsRGB() {
        #expect(RGB(0x61, 0xAF, 0xEF).red == 0x61)
        #expect(RGB(0x61, 0xAF, 0xEF) == RGB(0x61, 0xAF, 0xEF))
    }
}
