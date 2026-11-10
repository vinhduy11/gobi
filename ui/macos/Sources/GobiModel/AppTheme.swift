// The named themes of Settings > Appearance, as plain colour values. The app layer turns them into NSColors and applies them to
// the window, the editor and the terminal.

extension RGB {
    public init(_ hex: UInt32) { self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)) }

    /// "#RRGGBB" or "RRGGBB", any case; nil for anything else.
    public init?(hex text: String) {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    public var hex: String {
        func two(_ v: UInt8) -> String { let s = String(v, radix: 16, uppercase: true); return s.count == 1 ? "0" + s : s }
        return "#" + two(red) + two(green) + two(blue)
    }

    /// Moves each channel `amount` (0 to 1) of the way towards white (`towardsWhite`) or black.
    public func shifted(_ amount: Double, towardsWhite: Bool) -> RGB {
        func move(_ v: UInt8) -> UInt8 {
            let target: Double = towardsWhite ? 255 : 0
            return UInt8((Double(v) + (target - Double(v)) * amount).rounded())
        }
        return RGB(move(red), move(green), move(blue))
    }
}

/// The colours of what gopls names: types, functions, parameters, properties, constants, packages, and directive comments.
public struct SemanticColors: Equatable, Sendable {
    public let type: RGB
    public let function: RGB
    public let parameter: RGB
    public let property: RGB
    public let constant: RGB
    public let namespace: RGB
    public let annotation: RGB
}

public struct ThemePalette: Equatable, Sendable {
    /// The window and the tool windows around the editor.
    public let window: RGB
    public let editor: RGB
    /// The terminal and the bottom panel: the editor's colour in most themes, a shade off it in Islands Light and High Contrast.
    public let bottomPanel: RGB
    public let text: RGB
    public let secondaryText: RGB
    public let keyword: RGB
    public let builtin: RGB
    public let string: RGB
    public let comment: RGB
    public let number: RGB
    public let heading: RGB
    public let semantic: SemanticColors
    public let isDark: Bool

    /// The tool window colour with "Different tool window background" on: lighter than the editor in a dark theme, darker in a light one.
    public var alternateToolWindow: RGB { editor.shifted(0.05, towardsWhite: isDark) }
    public var alternateBottomPanel: RGB { bottomPanel.shifted(0.05, towardsWhite: isDark) }
}

public enum AppTheme: String, CaseIterable, Sendable {
    case islandsLight, islandsDark, highContrast, solarizedLight, solarizedDark, oneLight, oneDark

    public var title: String {
        switch self {
        case .islandsLight: return "Islands Light"
        case .islandsDark: return "Islands Dark"
        case .highContrast: return "High Contrast"
        case .solarizedLight: return "Solarized Light"
        case .solarizedDark: return "Solarized Dark"
        case .oneLight: return "One Light"
        case .oneDark: return "One Dark"
        }
    }

    /// The colour of the labels of the interface (file tree, tabs, panel titles), which JetBrains tints per theme.
    public var uiText: RGB {
        switch self {
        case .oneDark: return RGB(0xC8CFDC)
        case .solarizedDark: return RGB(0x93A1A1)
        case .highContrast: return RGB(0xFFFFFF)
        default: return palette.text
        }
    }

    /// The colour of toolbar and panel icons: grey in the light themes, the text colour in the dark ones.
    public var icon: RGB {
        switch self {
        case .islandsLight: return RGB(0x6C707E)
        case .oneLight: return RGB(0x696C77)
        default: return palette.text
        }
    }

    /// The strip behind the editor tabs: the editor's colour, except where the theme draws it darker.
    public var tabStrip: RGB { self == .solarizedDark ? RGB(0x092531) : palette.editor }

    public var isDark: Bool {
        switch self {
        case .islandsLight, .solarizedLight, .oneLight: return false
        case .islandsDark, .highContrast, .solarizedDark, .oneDark: return true
        }
    }

    public var palette: ThemePalette {
        func make(_ window: UInt32, _ editor: UInt32, _ text: UInt32, _ secondary: UInt32, keyword: UInt32, builtin: UInt32, string: UInt32,
                  comment: UInt32, number: UInt32, heading: UInt32, bottomPanel: UInt32? = nil, semantic: SemanticColors? = nil, annotation: UInt32? = nil) -> ThemePalette {
            // Where a theme draws these names in the plain text colour (Islands, High Contrast) nothing is given.
            let plain = RGB(text)
            let colours = semantic ?? SemanticColors(type: plain, function: plain, parameter: plain, property: plain, constant: plain, namespace: plain, annotation: RGB(annotation ?? comment))
            return ThemePalette(window: RGB(window), editor: RGB(editor), bottomPanel: RGB(bottomPanel ?? editor), text: RGB(text), secondaryText: RGB(secondary), keyword: RGB(keyword),
                         builtin: RGB(builtin), string: RGB(string), comment: RGB(comment), number: RGB(number), heading: RGB(heading), semantic: colours, isDark: isDark)
        }
        switch self {
        case .oneDark:
            return make(0x22252A, 0x292C33, 0xABB2BF, 0x9DA0A8, keyword: 0xC678DD, builtin: 0x56B6C2, string: 0x98C379, comment: 0x5C6370, number: 0xD19A66, heading: 0x61AFEF, semantic: SemanticColors(type: RGB(0xE5C07B), function: RGB(0x61AFEF), parameter: RGB(0xE06C75), property: RGB(0xE06C75), constant: RGB(0xD19A66), namespace: RGB(0xABB2BF), annotation: RGB(0xE5C07B)))
        case .oneLight:
            return make(0xE9E9EA, 0xFAFAFA, 0x383A42, 0x696C77, keyword: 0xA626A4, builtin: 0x0184BC, string: 0x50A14F, comment: 0xA0A1A7, number: 0x986801, heading: 0x4078F2, semantic: SemanticColors(type: RGB(0xC18401), function: RGB(0x4078F2), parameter: RGB(0xE45649), property: RGB(0xE45649), constant: RGB(0xE45649), namespace: RGB(0x383A42), annotation: RGB(0x986801)))
        case .solarizedDark:
            return make(0x173541, 0x0E2A35, 0x839496, 0x657B83, keyword: 0x859900, builtin: 0x268BD2, string: 0x2AA198, comment: 0x586E75, number: 0x2AA198, heading: 0x268BD2, semantic: SemanticColors(type: RGB(0xB58900), function: RGB(0x268BD2), parameter: RGB(0x268BD2), property: RGB(0x268BD2), constant: RGB(0x268BD2), namespace: RGB(0x268BD2), annotation: RGB(0xCB4B16)))
        case .solarizedLight:
            return make(0xECE7D6, 0xFCF6E5, 0x657B83, 0x586E75, keyword: 0x859900, builtin: 0x268BD2, string: 0x2AA198, comment: 0x93A1A1, number: 0x2AA198, heading: 0x268BD2, semantic: SemanticColors(type: RGB(0xB58900), function: RGB(0x268BD2), parameter: RGB(0x268BD2), property: RGB(0x268BD2), constant: RGB(0x268BD2), namespace: RGB(0x268BD2), annotation: RGB(0xCB4B16)))
        case .islandsDark:
            return make(0x26282C, 0x191A1C, 0xBCBEC4, 0x9A9DA3, keyword: 0xCF8E6D, builtin: 0x56A8F5, string: 0x6AAB73, comment: 0x7A7E85, number: 0x2AACB8, heading: 0x56A8F5, annotation: 0xBBB529)
        case .islandsLight:
            return make(0xE8E9ED, 0xFFFFFF, 0x1A1A1A, 0x5C5F66, keyword: 0x0033B3, builtin: 0x00627A, string: 0x067D17, comment: 0x6F737A, number: 0x1750EB, heading: 0x0033B3, bottomPanel: 0xF7F8F9, annotation: 0x9E880D)
        case .highContrast:
            return make(0x1A1B1E, 0x000000, 0xD8D9DD, 0x8E9097, keyword: 0xE0A97F, builtin: 0x00E5FF, string: 0xA3D9A2, comment: 0xB8B8B8, number: 0x6CC4D0, heading: 0x4FC3F7, bottomPanel: 0x0E0F11, annotation: 0xDFDA8B)
        }
    }

    /// The theme to show. With "Sync with OS" a theme of the other brightness is swapped for One Light or One Dark.
    public static func resolved(selected: AppTheme, syncWithOS: Bool, systemIsDark: Bool) -> AppTheme {
        guard syncWithOS, selected.isDark != systemIsDark else { return selected }
        return systemIsDark ? .oneDark : .oneLight
    }
}

public enum AccentChoice: Equatable, Sendable {
    case blue, teal, purple, orange
    case custom(RGB)

    public static let presets: [AccentChoice] = [.blue, .teal, .purple, .orange]

    public var rgb: RGB {
        switch self {
        case .blue: return RGB(0x4670DA)
        case .teal: return RGB(0x3FA593)
        case .purple: return RGB(0x9059E0)
        case .orange: return RGB(0xE08A4F)
        case .custom(let color): return color
        }
    }

    public var encoded: String {
        switch self {
        case .blue: return "blue"
        case .teal: return "teal"
        case .purple: return "purple"
        case .orange: return "orange"
        case .custom(let color): return color.hex
        }
    }

    public init?(encoded: String) {
        if let preset = Self.presets.first(where: { $0.encoded == encoded }) { self = preset } else if let color = RGB(hex: encoded) { self = .custom(color) } else { return nil }
    }
}

/// The Settings > Appearance values (theme, accent, editor colour scheme). The app stores `encoded()` text.
public struct ThemeSettings: Equatable, Sendable {
    public var theme = AppTheme.oneDark
    /// Off by default: the theme you choose is the theme you get. On, a theme of the other brightness gives way to One Light or One Dark.
    public var syncWithOS = false
    /// nil is "Theme default": the editor uses the theme's own colours.
    public var editorScheme: AppTheme?
    public var accent = AccentChoice.blue
    public var differentToolWindowBackground = false

    public init() {}

    public func effectiveTheme(systemIsDark: Bool) -> AppTheme {
        AppTheme.resolved(selected: theme, syncWithOS: syncWithOS, systemIsDark: systemIsDark)
    }

    /// The colours the editor draws with: its own scheme if one is chosen, else the theme's.
    public func editorPalette(systemIsDark: Bool) -> ThemePalette {
        (editorScheme ?? effectiveTheme(systemIsDark: systemIsDark)).palette
    }

    public func encoded() -> String {
        ["theme=\(theme.rawValue)", "sync=\(syncWithOS)", "editorScheme=\(editorScheme?.rawValue ?? "")", "accent=\(accent.encoded)", "toolBackground=\(differentToolWindowBackground)"]
            .joined(separator: "\n")
    }

    public static func decodeOrDefault(_ text: String) -> ThemeSettings {
        var s = ThemeSettings()
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]), value = String(line[line.index(after: equals)...])
            switch key {
            case "theme": if let t = AppTheme(rawValue: value) { s.theme = t }
            case "sync": s.syncWithOS = value == "true"
            case "editorScheme": s.editorScheme = AppTheme(rawValue: value)
            case "accent": if let a = AccentChoice(encoded: value) { s.accent = a }
            case "toolBackground": s.differentToolWindowBackground = value == "true"
            default: break
            }
        }
        return s
    }
}
