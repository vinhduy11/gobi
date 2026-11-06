public struct ShellMenuItem: Equatable, Sendable {
    public let title: String
    public let path: String
    public let isChecked: Bool
}

/// The shells the Terminal menu offers (Terminal mock): the ones /etc/shells lists, the login shell marked, the choice checked.
public enum ShellChoice {
    public static func menuItems(shells: [String], login: String, selected: String) -> [ShellMenuItem] {
        let chosen = effective(selected: selected, shells: shells, login: login)
        return shells.map { path in
            let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
            let checked = chosen.isEmpty ? path == login : path == chosen
            return ShellMenuItem(title: path == login ? name + " (login shell)" : name, path: path, isChecked: checked)
        }
    }

    /// The shell to ask for: "" (the login shell) unless a listed other shell was chosen.
    public static func effective(selected: String, shells: [String], login: String) -> String {
        guard !selected.isEmpty, selected != login, shells.contains(selected) else { return "" }
        return selected
    }
}

public struct TerminalMatch: Equatable, Sendable {
    public let line: Int
    public let column: Int
}

/// Find in Terminal: matches in the text of the terminal buffer, and where to scroll to see one.
public enum TerminalFind {
    public static func matches(in text: String, query: String) -> [TerminalMatch] {
        guard !query.isEmpty else { return [] }
        let needle = Array(query.lowercased())
        var found: [TerminalMatch] = []
        for (line, content) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let hay = Array(content.lowercased())
            guard hay.count >= needle.count else { continue }
            var column = 0
            while column + needle.count <= hay.count {
                if Array(hay[column ..< column + needle.count]) == needle { found.append(TerminalMatch(line: line, column: column)); column += needle.count } else { column += 1 }
            }
        }
        return found
    }

    public static func label(index: Int, count: Int) -> String { count == 0 ? "No matches" : "\(index + 1) of \(count)" }

    public static func next(from index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return forward ? (index + 1) % count : (index - 1 + count) % count
    }

    /// The scroll position (0 top, 1 bottom) that shows `line` of a buffer with `totalLines` lines, `visibleLines` of them on screen.
    public static func scrollPosition(line: Int, totalLines: Int, visibleLines: Int) -> Double {
        let range = totalLines - visibleLines
        guard range > 0 else { return 0 }
        return min(1, max(0, Double(line) / Double(range)))
    }
}
