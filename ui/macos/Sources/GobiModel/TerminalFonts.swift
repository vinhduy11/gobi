// Which fonts the terminal offers and which it falls back to for icons. Shell prompts (powerlevel10k, starship, oh-my-zsh themes)
// draw Powerline arrows and file-type icons from the Unicode private-use area; SF Mono has none of them, so they show as boxes
// unless a Nerd Font (or a font patched like one) is installed and listed after the main font.

public enum TerminalFonts {
    public static let builtIn = ["SF Mono", "Menlo", "Monaco", "Courier New"]

    /// Nerd Font families Gobi looks for first, in this order.
    public static let iconFallbacks = [
        "Symbols Nerd Font Mono", "Symbols Nerd Font", "MesloLGS NF", "MesloLGS Nerd Font Mono", "JetBrainsMono Nerd Font Mono",
        "JetBrainsMono NF", "Hack Nerd Font Mono", "FiraCode Nerd Font Mono", "FiraMono Nerd Font Mono", "CaskaydiaCove Nerd Font Mono",
        "SauceCodePro Nerd Font Mono", "UbuntuMono Nerd Font Mono",
    ]

    /// The font families to offer in Settings > Terminal: the built-in four, then every installed Nerd Font.
    public static func choices(installedFamilies: [String]) -> [String] {
        var result = builtIn
        for family in installedFamilies.sorted() where isNerdFont(family) && !result.contains(family) { result.append(family) }
        return result
    }

    /// The families the terminal tries, after its own font, for a glyph the font does not have.
    public static func fallbackChain(installedFamilies: [String]) -> [String] {
        let installed = Set(installedFamilies)
        var chain = iconFallbacks.filter { installed.contains($0) }
        for family in installedFamilies.sorted() where isNerdFont(family) && !chain.contains(family) { chain.append(family) }
        return chain
    }

    public static func iconHint(chain: [String]) -> String {
        if let first = chain.first { return "Icons: \(first)" }
        return "Icons: none found. Install a Nerd Font (for example brew install --cask font-meslo-lg-nerd-font) and choose it here."
    }

    private static func isNerdFont(_ family: String) -> Bool {
        family.contains("Nerd Font") || family.hasSuffix(" NF") || family.contains(" NF ")
    }
}
