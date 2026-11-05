// Small facts about a project folder, parsed from the text of its files so the Welcome window can show them.
// Plain strings in and out: the file reading stays in the app layer.

public enum GoWork {
    /// Number of modules a go.work file lists, in `use ./a` lines and `use ( ... )` blocks.
    public static func moduleCount(_ text: String) -> Int {
        var count = 0
        var inBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = withoutComment(rawLine).trimmingSpaces()
            if trimmed.isEmpty { continue }
            if inBlock {
                if trimmed == ")" { inBlock = false } else { count += 1 }
            } else if trimmed == "use (" || trimmed == "use(" {
                inBlock = true
            } else if trimmed.hasPrefix("use ") && !trimmed.hasSuffix("(") {
                count += 1
            }
        }
        return count
    }
}

/// The part of a line before a `//` comment (no Foundation here, so the search is by hand).
private func withoutComment(_ line: Substring) -> Substring {
    var previous: Character?
    var index = line.startIndex
    while index < line.endIndex {
        let character = line[index]
        if character == "/", previous == "/" { return line[line.startIndex ..< line.index(before: index)] }
        previous = character
        index = line.index(after: index)
    }
    return line
}

public enum GitHead {
    /// The branch name from the contents of `.git/HEAD`, a short hash when detached, nil when it says nothing useful.
    public static func branch(_ head: String) -> String? {
        let text = head.trimmingSpaces()
        let prefix = "ref: refs/heads/"
        if text.hasPrefix(prefix) {
            let name = String(text.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        let isHash = text.count >= 7 && text.allSatisfy { $0.isHexDigit }
        return isHash ? String(text.prefix(7)) : nil
    }
}

public enum GoVersion {
    /// "1.26.5" from the output of `go env GOVERSION` ("go1.26.5"); nil for development builds and empty output.
    public static func display(fromGoEnv output: String) -> String? {
        let text = output.trimmingSpaces()
        guard text.hasPrefix("go1") else { return nil }
        return String(text.dropFirst(2))
    }
}

extension RecentProjects {
    /// Entries whose folder name or path contains `query`, ignoring case; all of them for an empty query.
    public func matching(_ query: String) -> [RecentProject] {
        let needle = query.trimmingSpaces().lowercased()
        if needle.isEmpty { return items }
        return items.filter { $0.path.lowercased().contains(needle) }
    }
}

extension StringProtocol {
    fileprivate func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" || first == "\n" || first == "\r" { scalars = scalars.dropFirst() }
        while let last = scalars.last, last == " " || last == "\t" || last == "\n" || last == "\r" { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
