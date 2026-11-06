import AppKit
import GobiModel

/// The terminal's font: the family from Settings > Terminal, with the installed Nerd Fonts as fallback for the icons a shell prompt draws.
enum TerminalFont {
    static var installedFamilies: [String] { NSFontManager.shared.availableFontFamilies }

    static func choices() -> [String] { TerminalFonts.choices(installedFamilies: installedFamilies) }
    static func iconChain() -> [String] { TerminalFonts.fallbackChain(installedFamilies: installedFamilies) }

    static func make(name: String, size: CGFloat) -> NSFont {
        var base: NSFont
        if name == "SF Mono" || name.isEmpty {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else if let named = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), size: size) {
            base = named
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let fallbacks = iconChain().filter { $0 != name }.map { NSFontDescriptor(fontAttributes: [.family: $0]) }
        guard !fallbacks.isEmpty else { return base }
        let withCascade = base.fontDescriptor.addingAttributes([.cascadeList: fallbacks])
        base = NSFont(descriptor: withCascade, size: size) ?? base
        return base
    }

    /// How many fallback fonts a font carries (for tests).
    static func fallbackCount(of font: NSFont) -> Int { (font.fontDescriptor.object(forKey: .cascadeList) as? [Any])?.count ?? 0 }
}
