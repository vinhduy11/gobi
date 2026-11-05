import AppKit
import GobiClient

/// Token colours, matching the palette in the UI mockups, with separate light and dark values.
enum SyntaxTheme {
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    static let keyword = dynamic(light: 0xAD3DA4, dark: 0xFF7AB2)
    static let builtin = dynamic(light: 0x326D74, dark: 0x5DD8FF)
    static let string = dynamic(light: 0xC41A16, dark: 0xFF8170)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x8A97A3)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD9C97C)
    static let heading = dynamic(light: 0x0058B8, dark: 0x64B0FF)

    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword, .marker: return keyword
        case .builtin, .key, .code: return builtin
        case .string, .character: return string
        case .comment: return comment
        case .number: return number
        case .heading: return heading
        }
    }
}
