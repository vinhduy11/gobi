import AppKit
import GobiClient
import GobiModel

/// Token colours of the editor's colour scheme (Settings > Appearance).
enum SyntaxTheme {
    static func color(for kind: SyntaxKind) -> NSColor {
        let p = ThemeColors.editor
        switch kind {
        case .keyword, .marker: return ThemeColors.color(p.keyword)
        case .builtin, .key, .code: return ThemeColors.color(p.builtin)
        case .string, .character: return ThemeColors.color(p.string)
        case .comment: return ThemeColors.color(p.comment)
        case .number: return ThemeColors.color(p.number)
        case .heading: return ThemeColors.color(p.heading)
        case .typeName: return ThemeColors.color(p.semantic.type)
        case .function: return ThemeColors.color(p.semantic.function)
        case .parameter: return ThemeColors.color(p.semantic.parameter)
        case .property: return ThemeColors.color(p.semantic.property)
        case .constant: return ThemeColors.color(p.semantic.constant)
        case .namespace: return ThemeColors.color(p.semantic.namespace)
        case .annotation: return ThemeColors.color(p.semantic.annotation)
        }
    }
}
