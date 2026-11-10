// What kind of thing an explorer row is, from its name, and how its icon looks. Colours are named, not drawn: the app
// layer turns a `FileColor` into the platform's colour.

public enum FileColor: Equatable {
    case blue, cyan, teal, green, yellow, orange, red, purple, gray
}

/// How an icon is drawn.
public enum FileIconStyle: Equatable {
    /// A filled rounded square with white text ("GO").
    case solidBadge
    /// An outlined page in the colour, with one letter at its lower right ("M" for go.mod).
    case documentLetter
    /// An outlined page with a small symbol at its lower right (a lock for go.sum).
    case documentSymbol
    /// Coloured text on its own ("{}", "M↓").
    case glyph
    /// A single SF Symbol.
    case symbol
}

public struct FileLook: Equatable {
    public var style: FileIconStyle
    /// The text of a badge, letter or glyph; empty for the symbol styles.
    public var text: String
    /// An SF Symbol name for the symbol styles; empty otherwise.
    public var symbol: String
    public var color: FileColor
}

public enum FileKind: CaseIterable, Equatable {
    case folder, goSource, goTest, goMod, goSum, goWork, markdown, html, yaml, json, toml, makefile, git, env, shell, docker, proto, sql, image, text, generic

    public static func classify(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let lower = name.lowercased()
        switch lower {
        case "go.mod": return .goMod
        case "go.sum", "go.work.sum": return .goSum
        case "go.work": return .goWork
        case "makefile", "gnumakefile": return .makefile
        case "dockerfile": return .docker
        case "license", "licence", "notice": return .text
        case ".gitignore", ".gitattributes", ".gitmodules": return .git
        default: break
        }
        if lower == ".env" || lower.hasPrefix(".env.") { return .env }
        if lower.hasSuffix("_test.go") { return .goTest }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return .generic }
        switch lower[lower.index(after: dot)...] {
        case "go": return .goSource
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        case "yml", "yaml": return .yaml
        case "json": return .json
        case "toml": return .toml
        case "sh", "bash", "zsh": return .shell
        case "proto": return .proto
        case "sql": return .sql
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp": return .image
        case "txt": return .text
        default: return .generic
        }
    }

    public var look: FileLook {
        switch self {
        case .folder: return FileLook(style: .symbol, text: "", symbol: "folder", color: .gray)
        case .goSource: return FileLook(style: .solidBadge, text: "GO", symbol: "", color: .cyan)
        case .goTest: return FileLook(style: .solidBadge, text: "GO", symbol: "", color: .green)
        case .goMod: return FileLook(style: .documentLetter, text: "M", symbol: "", color: .teal)
        case .goSum: return FileLook(style: .documentSymbol, text: "", symbol: "lock.fill", color: .yellow)
        case .goWork: return FileLook(style: .documentLetter, text: "W", symbol: "", color: .teal)
        case .markdown: return FileLook(style: .glyph, text: "M↓", symbol: "", color: .blue)
        case .html: return FileLook(style: .glyph, text: "<>", symbol: "", color: .green)
        case .yaml: return FileLook(style: .documentLetter, text: "Y", symbol: "", color: .red)
        case .json: return FileLook(style: .glyph, text: "{}", symbol: "", color: .purple)
        case .toml: return FileLook(style: .documentLetter, text: "T", symbol: "", color: .orange)
        case .makefile: return FileLook(style: .glyph, text: "M", symbol: "", color: .blue)
        case .git: return FileLook(style: .symbol, text: "", symbol: "nosign", color: .gray)
        case .env: return FileLook(style: .documentLetter, text: "E", symbol: "", color: .yellow)
        case .shell: return FileLook(style: .documentLetter, text: "$", symbol: "", color: .green)
        case .docker: return FileLook(style: .documentLetter, text: "D", symbol: "", color: .blue)
        case .proto: return FileLook(style: .documentLetter, text: "P", symbol: "", color: .purple)
        case .sql: return FileLook(style: .documentLetter, text: "S", symbol: "", color: .orange)
        case .image: return FileLook(style: .symbol, text: "", symbol: "photo", color: .purple)
        case .text: return FileLook(style: .symbol, text: "", symbol: "text.alignleft", color: .gray)
        case .generic: return FileLook(style: .symbol, text: "", symbol: "doc", color: .gray)
        }
    }
}
