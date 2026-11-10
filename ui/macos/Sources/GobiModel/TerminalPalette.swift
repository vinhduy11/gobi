// The terminal's colours: a background and foreground in the tone of the window, and a softer set of the sixteen ANSI colours
// than the harsh pure ones terminals default to. Plain values; the app layer hands them to the terminal view.

public struct RGB: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Relative luminance, 0 (black) to 1 (white). Approximate: a gamma of 2 instead of the exact sRGB curve, which needs no
    /// maths library and is close enough to compare colours.
    public var luminance: Double {
        func channel(_ value: UInt8) -> Double { let c = Double(value) / 255; return c * c }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Contrast ratio with another colour, 1 (none) to 21 (black on white).
    public func contrast(with other: RGB) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}

public final class TerminalPalette {
    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    /// Black, red, green, yellow, blue, magenta, cyan, white, then the bright versions of the same eight.
    public let ansi: [RGB]

    init(background: RGB, foreground: RGB, cursor: RGB, ansi: [RGB]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }

    /// A slate background like the editor's, with soft colours.
    public static let dark = TerminalPalette(
        background: RGB(0x1E, 0x1F, 0x22), foreground: RGB(0xBC, 0xBE, 0xC4), cursor: RGB(0x6C, 0x9B, 0xFF),
        ansi: [
            RGB(0x3E, 0x42, 0x4A), RGB(0xE0, 0x6C, 0x75), RGB(0x98, 0xC3, 0x79), RGB(0xE5, 0xC0, 0x7B),
            RGB(0x61, 0xAF, 0xEF), RGB(0xC6, 0x78, 0xDD), RGB(0x56, 0xB6, 0xC2), RGB(0xAB, 0xB2, 0xBF),
            RGB(0x5C, 0x63, 0x70), RGB(0xF0, 0x8A, 0x92), RGB(0xB1, 0xDB, 0x91), RGB(0xF1, 0xD3, 0x9A),
            RGB(0x82, 0xC2, 0xFA), RGB(0xD9, 0x9B, 0xEB), RGB(0x7B, 0xCF, 0xDA), RGB(0xDC, 0xDF, 0xE4),
        ])

    public static let light = TerminalPalette(
        background: RGB(0xFF, 0xFF, 0xFF), foreground: RGB(0x38, 0x3A, 0x42), cursor: RGB(0x1F, 0x6F, 0xEB),
        ansi: [
            RGB(0x38, 0x3A, 0x42), RGB(0xC9, 0x3A, 0x45), RGB(0x2E, 0x8B, 0x3A), RGB(0xA6, 0x6F, 0x00),
            RGB(0x1F, 0x6F, 0xEB), RGB(0x9B, 0x3F, 0xBF), RGB(0x1B, 0x7F, 0x8F), RGB(0x8A, 0x8D, 0x96),
            RGB(0x5C, 0x63, 0x70), RGB(0xD9, 0x4A, 0x55), RGB(0x3F, 0x9E, 0x4B), RGB(0xB8, 0x80, 0x10),
            RGB(0x3A, 0x85, 0xF5), RGB(0xAE, 0x55, 0xCF), RGB(0x2A, 0x93, 0xA3), RGB(0x6B, 0x6F, 0x78),
        ])

    public static func forAppearance(isDark: Bool) -> TerminalPalette { isDark ? dark : light }

    /// The canonical Solarized sixteen colours (the dark and light themes share them; only the background and text differ).
    private static let solarized = TerminalPalette(
        background: RGB(0x00, 0x2B, 0x36), foreground: RGB(0x83, 0x94, 0x96), cursor: RGB(0x93, 0xA1, 0xA1),
        ansi: [
            RGB(0x07, 0x36, 0x42), RGB(0xDC, 0x32, 0x2F), RGB(0x85, 0x99, 0x00), RGB(0xB5, 0x89, 0x00),
            RGB(0x26, 0x8B, 0xD2), RGB(0xD3, 0x36, 0x82), RGB(0x2A, 0xA1, 0x98), RGB(0xEE, 0xE8, 0xD5),
            RGB(0x00, 0x2B, 0x36), RGB(0xCB, 0x4B, 0x16), RGB(0x58, 0x6E, 0x75), RGB(0x65, 0x7B, 0x83),
            RGB(0x83, 0x94, 0x96), RGB(0x6C, 0x71, 0xC4), RGB(0x93, 0xA1, 0xA1), RGB(0xFD, 0xF6, 0xE3),
        ])

    /// The sixteen ANSI colours that go with a theme.
    public static func forTheme(_ theme: AppTheme) -> TerminalPalette {
        switch theme {
        case .solarizedDark, .solarizedLight: return solarized
        default: return forAppearance(isDark: theme.isDark)
        }
    }
}
