extension StatusBar {
    /// What the left of the status bar says about the language service of the open file.
    public static func serviceText(language: String, connected: Bool, restricted: Bool) -> String {
        switch language {
        case "go": return goplsText(connected: connected, restricted: restricted)
        case "json": return connected ? "JSON · built-in language service" : "JSON · starting…"
        case "markdown": return connected ? "Markdown · built-in language service" : "Markdown · starting…"
        default: return ""
        }
    }

    /// The label at the right: "Go 1.26.5", or "JSON · 1 problem".
    public static func languageLabel(language: String, goVersion: String?, problems: Int) -> String {
        let name: String
        switch language {
        case "go": return goVersion.map { "Go " + $0 } ?? "Go"
        case "json": name = "JSON"
        case "markdown": name = "Markdown"
        default: return "Plain text"
        }
        return problems > 0 ? "\(name) · \(problems) problem\(problems == 1 ? "" : "s")" : name
    }
}

public enum FileFacts {
    /// Headings of a Markdown text: ATX lines (# ...) outside code fences, and setext headings (a line over === or ---).
    public static func headingCount(_ text: String) -> Int {
        var count = 0
        var inFence = false
        var previous = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); previous = ""; continue }
            if inFence { continue }
            if line.hasPrefix("#"), let first = line.drop(while: { $0 == "#" }).first, first == " " { count += 1 }
            else if !previous.isEmpty, !line.isEmpty, line.allSatisfy({ $0 == "=" }) || (line.count >= 3 && line.allSatisfy { $0 == "-" }), !previous.hasPrefix("#") { count += 1 }
            previous = line
        }
        return count
    }

    /// "2 spaces", "tabs" or "none": how the first indented line of a JSON file is indented.
    public static func jsonIndent(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("\t") { return "tabs" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > 0 { return "\(spaces) spaces" }
        }
        return "none"
    }
}

public enum MarkdownPreviewMode: String, CaseIterable, Sendable {
    case source, split, preview
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    public var showsSource: Bool { self != .preview }
    public var showsPreview: Bool { self != .source }
    public var inspectorText: String { self == .source ? "Off" : (self == .split ? "Side by side" : "Preview only") }
}

public enum MarkdownPreviewPage {
    /// The HTML gobid sends, inside a page that runs no scripts and loads nothing from outside.
    public static func wrap(html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.55 -apple-system, "SF Pro Text", sans-serif; margin: 18px 22px; }
        h1, h2 { border-bottom: 1px solid rgba(128,128,128,.3); padding-bottom: .2em; }
        code, pre { font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; background: rgba(128,128,128,.14); border-radius: 5px; }
        code { padding: .1em .35em; } pre { padding: 10px 12px; overflow: auto; } pre code { padding: 0; background: none; }
        table { border-collapse: collapse; } th, td { border: 1px solid rgba(128,128,128,.4); padding: 4px 10px; }
        blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid rgba(128,128,128,.4); color: gray; }
        a { color: #0a84ff; }
        </style></head><body>\(html)</body></html>
        """
    }

    /// A clicked link is handed to the browser only when it is http or https.
    public static func opensExternally(url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}
