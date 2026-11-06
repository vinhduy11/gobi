// Edit > Sort Lines / Reverse Lines work on the text of whole lines; these are the pure parts.

public enum LineOrder {
    /// The lines in plain code-point order. A final newline stays final.
    public static func sorted(_ text: String) -> String { reorder(text) { $0.sorted() } }

    /// The lines in the opposite order. A final newline stays final.
    public static func reversed(_ text: String) -> String { reorder(text) { Array($0.reversed()) } }

    private static func reorder(_ text: String, _ order: ([String]) -> [String]) -> String {
        guard !text.isEmpty else { return text }
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline { lines.removeLast() }
        return order(lines).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }
}

/// View > Recent Files: the files opened last in one project, newest first.
public enum RecentFiles {
    public static let limit = 15

    public static func adding(_ path: String, to list: [String]) -> [String] {
        guard !path.isEmpty else { return list }
        return Array(([path] + list.filter { $0 != path }).prefix(limit))
    }
}
