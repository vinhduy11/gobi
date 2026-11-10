import AppKit
import GobiEditor
import GobiModel

/// The explorer's file icons, in the style of the reference: a quiet grey outline for folders, a solid cyan badge for Go
/// source, outlined pages with a small letter for configuration files, and bare coloured glyphs for Markdown and JSON.
/// Colours are soft rather than the saturated system ones. Each kind is drawn once and kept; the drawing handler runs again
/// when the appearance changes, so greys follow light and dark.
enum FileIcons {
    private static var cache: [FileKind: NSImage] = [:]
    static let size = NSSize(width: 18, height: 18)

    static func color(_ color: FileColor) -> NSColor {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        switch color {
        case .blue: return rgb(0x66, 0x93, 0xFF)
        case .cyan: return rgb(0x5B, 0xB5, 0xD5)
        case .teal: return rgb(0x4F, 0xC1, 0xC8)
        case .green: return rgb(0x67, 0xA6, 0x62)
        case .yellow: return rgb(0xD6, 0xB6, 0x5C)
        case .orange: return rgb(0xD0, 0x8A, 0x5C)
        case .red: return rgb(0xE2, 0x76, 0x7D)
        case .purple: return rgb(0xA9, 0x8B, 0xEA)
        case .gray: return ThemeColors.theme.isDark ? rgb(0x9D, 0xA0, 0xA8) : rgb(0x6C, 0x70, 0x7E)
        }
    }

    /// The theme changed: icons are drawn again with its greys.
    static func reset() { cache.removeAll() }

    static func image(for kind: FileKind) -> NSImage {
        if let cached = cache[kind] { return cached }
        let look = kind.look
        let image = NSImage(size: size, flipped: false) { rect in
            let tint = color(look.color)
            switch look.style {
            case .solidBadge:
                let badge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 3.5, yRadius: 3.5)
                tint.setFill()
                badge.fill()
                draw(look.text, size: 8, color: NSColor.white, centredIn: rect, weight: .heavy)
            case .documentLetter:
                symbol("doc", tint, in: rect)
                draw(look.text, size: 7, color: tint, at: NSPoint(x: rect.maxX - 7.5, y: 0.5), weight: .bold)
            case .documentSymbol:
                symbol("doc", tint, in: rect)
                symbolSmall(look.symbol, tint, at: NSRect(x: rect.maxX - 8.5, y: 0.5, width: 8, height: 8))
            case .glyph:
                draw(look.text, size: look.text.count > 1 ? 11 : 13, color: tint, centredIn: rect, weight: .bold)
            case .symbol:
                symbol(look.symbol, tint, in: rect)
            }
            return true
        }
        cache[kind] = image
        return image
    }

    private static func symbol(_ name: String, _ tint: NSColor, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let box = image.size
        image.draw(in: NSRect(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2, width: box.width, height: box.height))
    }

    private static func symbolSmall(_ name: String, _ tint: NSColor, at rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold).applying(.init(paletteColors: [tint]))
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?.draw(in: rect)
    }

    private static func draw(_ text: String, size: CGFloat, color: NSColor, centredIn rect: NSRect, weight: NSFont.Weight) {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let box = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
    }

    private static func draw(_ text: String, size: CGFloat, color: NSColor, at point: NSPoint, weight: NSFont.Weight) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: point)
    }
}
