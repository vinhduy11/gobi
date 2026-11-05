// What kind of thing an explorer row is, from its name, and how its icon looks. Colours are named, not drawn: the app
// layer turns a `FileColor` into the platform's colour.

public enum FileColor: Equatable {
    case blue, cyan, teal, green, yellow, orange, red, purple, gray
}

public struct FileLook: Equatable {
    /// Short text drawn on a coloured badge (for example "GO"); empty when a symbol is used instead.
    public var badge: String
    /// An SF Symbol name; empty when a badge is used.
    public var symbol: String
    public var color: FileColor
}

public enum FileKind: CaseIterable, Equatable {
    case folder, goSource, goTest, goMod, goSum, goWork, markdown, yaml, json, toml, makefile, git, env, shell, docker, proto, sql, image, text, generic

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
        case .folder: return FileLook(badge: "", symbol: "folder", color: .gray)
        case .goSource: return FileLook(badge: "GO", symbol: "", color: .cyan)
        case .goTest: return FileLook(badge: "GO", symbol: "", color: .green)
        case .goMod: return FileLook(badge: "M", symbol: "", color: .teal)
        case .goSum: return FileLook(badge: "", symbol: "lock.doc", color: .yellow)
        case .goWork: return FileLook(badge: "W", symbol: "", color: .teal)
        case .markdown: return FileLook(badge: "M↓", symbol: "", color: .blue)
        case .yaml: return FileLook(badge: "Y", symbol: "", color: .red)
        case .json: return FileLook(badge: "{}", symbol: "", color: .purple)
        case .toml: return FileLook(badge: "T", symbol: "", color: .orange)
        case .makefile: return FileLook(badge: "M", symbol: "", color: .blue)
        case .git: return FileLook(badge: "", symbol: "nosign", color: .gray)
        case .env: return FileLook(badge: "E", symbol: "", color: .yellow)
        case .shell: return FileLook(badge: "$", symbol: "", color: .green)
        case .docker: return FileLook(badge: "D", symbol: "", color: .blue)
        case .proto: return FileLook(badge: "P", symbol: "", color: .purple)
        case .sql: return FileLook(badge: "S", symbol: "", color: .orange)
        case .image: return FileLook(badge: "", symbol: "photo", color: .purple)
        case .text: return FileLook(badge: "", symbol: "text.alignleft", color: .gray)
        case .generic: return FileLook(badge: "", symbol: "doc", color: .gray)
        }
    }
}
