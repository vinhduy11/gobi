// "Add to .gitignore" for the changed files of Source control. Pure text: the app reads and writes the file.

public enum GitIgnore {
    /// The text of a .gitignore with `paths` added, each as a pattern anchored at the project root (a trailing slash stays: a folder), or
    /// nil when every path is already listed. Paths are relative to the project root.
    public static func appending(_ paths: [String], to existing: String) -> String? {
        var known = Set(existing.split(separator: "\n", omittingEmptySubsequences: true).map { key(String($0)) })
        var added: [String] = []
        for path in paths where !path.isEmpty {
            guard known.insert(key(path)).inserted else { continue }
            added.append("/" + escaped(path))
        }
        guard !added.isEmpty else { return nil }
        var text = existing
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        for pattern in added { text += pattern + "\n" }
        return text
    }

    /// A line or a path without its anchoring and folder slashes and without escapes, so "/docs/", "docs/" and "/docs" compare equal.
    private static func key(_ line: String) -> String {
        var text = line.filter { $0 != "\\" }
        while text.hasPrefix("/") { text.removeFirst() }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Backslashes before the characters a pattern would read as syntax.
    private static func escaped(_ path: String) -> String {
        var text = ""
        for character in path {
            if "\\ #![]*?".contains(character) { text.append("\\") }
            text.append(character)
        }
        return text
    }
}
