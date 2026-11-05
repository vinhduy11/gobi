import AppKit
import GobiModel

/// The explorer's file icons: a coloured badge with a short label for source and config files ("GO", "M↓", "{}"), an SF
/// Symbol for folders and plain files. Drawn once per kind and kept.
enum FileIcons {
    private static var cache: [FileKind: NSImage] = [:]
    static let size = NSSize(width: 18, height: 18)

    static func color(_ color: FileColor) -> NSColor {
        switch color {
        case .blue: return .systemBlue
        case .cyan: return NSColor(calibratedRed: 0.22, green: 0.66, blue: 0.84, alpha: 1)
        case .teal: return .systemTeal
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .purple: return .systemPurple
        case .gray: return .secondaryLabelColor
        }
    }

    static func image(for kind: FileKind) -> NSImage {
        if let cached = cache[kind] { return cached }
        let look = kind.look
        let image: NSImage
        if look.badge.isEmpty {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: [kind == .folder ? .systemBlue : color(look.color)]))
            image = (NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)) ?? NSImage(size: size)
        } else {
            let fill = color(look.color)
            image = NSImage(size: size, flipped: false) { rect in
                let badge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 4, yRadius: 4)
                fill.setFill()
                badge.fill()
                let fontSize: CGFloat = look.badge.count > 1 ? 8 : 10
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white]
                let text = NSAttributedString(string: look.badge, attributes: attributes)
                let box = text.size()
                text.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
                return true
            }
        }
        cache[kind] = image
        return image
    }
}
