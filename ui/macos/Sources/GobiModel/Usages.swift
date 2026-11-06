/// One use of a symbol: where it is. The text of the line is not part of it; the panel reads that from its line cache.
public struct UsageLine: Equatable {
    public var uri: String
    public var line: Int
    public var start: Int
    public var end: Int
}

/// The usages inside one declaration (`name` is nil for a usage that is in no declaration, or in a file whose symbols could not
/// be read: "file scope").
public struct UsageFunction: Equatable {
    public var name: String?
    public var lines: [UsageLine]
    /// Start of the declaration; the groups of one file are told apart by it.
    public var key: LSPPosition?
    /// What the declaration is (a function, a method, a type, a field...); nil for file scope.
    public var kind: OutlineSymbol.Kind?
}

public struct UsageFile: Equatable {
    public var uri: String
    public var functions: [UsageFunction]
    public var isTest: Bool
    public var count: Int { functions.reduce(0) { $0 + $1.lines.count } }
}

/// What the Usages tab shows: files with their functions and lines, how many usages the filters left, how many of those are shown
/// and the declaration's name when the declaration is among the locations.
public struct UsageResult: Equatable {
    public var files: [UsageFile]
    public var total: Int
    public var totalFiles: Int
    public var shown: Int
    public var declaration: String?
    public var hidden: Int { total - shown }

    public var lines: [UsageLine] { files.flatMap { $0.functions.flatMap(\.lines) } }
}

/// Pure grouping and wording for the Usages tab.
public enum UsageGroups {
    /// The usages listed before a "show more" row, and how many each "show more" adds.
    public static let pageSize = 5000

    /// Groups locations by file, enclosing declaration and line. `symbols` is by file uri; a file without an entry is one scope.
    public static func build(locations: [SourceLocation], symbols: [String: [DocumentSymbolInfo]], includeTests: Bool = true, limit: Int = pageSize) -> UsageResult {
        var seen = Set<Place>()
        var kept: [SourceLocation] = []
        for location in locations where includeTests || !isTestFile(location.uri) {
            if seen.insert(Place(location)).inserted { kept.append(location) }
        }
        kept.sort { a, b in
            if a.uri != b.uri { return a.uri < b.uri }
            if a.start.line != b.start.line { return a.start.line < b.start.line }
            return a.start.character < b.start.character
        }
        let totalFiles = Set(kept.map(\.uri)).count
        let shown = kept.prefix(max(0, limit))
        var files: [UsageFile] = []
        for location in shown {
            let line = UsageLine(uri: location.uri, line: location.start.line, start: location.start.character, end: location.end.character)
            let chain = chain(containing: location.start, in: symbols[location.uri] ?? [])
            let name = chain.isEmpty ? nil : chain.map { normalized($0.name) }.joined(separator: ".")
            let key = chain.last?.range.0
            if files.last?.uri != location.uri { files.append(UsageFile(uri: location.uri, functions: [], isTest: isTestFile(location.uri))) }
            if let index = files[files.count - 1].functions.firstIndex(where: { $0.key == key }) {
                files[files.count - 1].functions[index].lines.append(line)
            } else {
                files[files.count - 1].functions.append(UsageFunction(name: name, lines: [line], key: key, kind: chain.last?.kind))
            }
        }
        return UsageResult(files: files, total: kept.count, totalFiles: totalFiles, shown: shown.count, declaration: declaration(among: kept, symbols))
    }

    public static func isTestFile(_ uri: String) -> Bool { uri.hasSuffix("_test.go") }

    /// "12 in 4 files".
    public static func summary(usages: Int, files: Int) -> String {
        usages == 0 ? "none" : "\(usages) in \(files) file\(files == 1 ? "" : "s")"
    }

    /// The row after `index` (or before, with a negative `delta`), wrapping around; the first or last row when nothing is selected.
    public static func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta >= 0 ? 0 : count - 1 }
        return ((index + delta) % count + count) % count
    }

    /// A source line for the panel: leading blanks and the line end dropped, the match given as offsets (UTF-16 units) in the text.
    public static func excerpt(_ line: String, start: Int, end: Int) -> (text: String, matchStart: Int, matchEnd: Int) {
        var units = Array(line.utf16)
        while let last = units.last, last == 13 || last == 10 { units.removeLast() }
        let lead = units.prefix { $0 == 32 || $0 == 9 }.count
        let text = units.dropFirst(lead)
        let from = min(max(0, start - lead), text.count)
        return (String(decoding: text, as: UTF16.self), from, min(max(from, end - lead), text.count))
    }

    /// Whether the line still holds what it held when the result was made, so opening it lands on the usage.
    public static func isStillThere(cached: String, current: String?) -> Bool {
        guard let current else { return false }
        return excerpt(cached, start: 0, end: 0).text == excerpt(current, start: 0, end: 0).text
    }

    // MARK: names

    /// "(*Server).Start" reads "Server.Start".
    static func normalized(_ name: String) -> String {
        guard name.hasPrefix("("), let close = name.firstIndex(of: ")") else { return name }
        let dot = name.index(after: close)
        guard dot < name.endIndex, name[dot] == "." else { return name }
        let receiver = name[name.index(after: name.startIndex) ..< close].drop { $0 == "*" }
        return receiver + "." + name[name.index(after: dot)...]
    }

    private static func chain(containing position: LSPPosition, in symbols: [DocumentSymbolInfo]) -> [DocumentSymbolInfo] {
        guard let outer = symbols.first(where: { $0.contains(position) }) else { return [] }
        return [outer] + chain(containing: position, in: outer.children)
    }

    private static func declaration(among locations: [SourceLocation], _ symbols: [String: [DocumentSymbolInfo]]) -> String? {
        for location in locations {
            if let name = declared(at: location.start, in: symbols[location.uri] ?? [], parents: []) { return name }
        }
        return nil
    }

    private static func declared(at position: LSPPosition, in symbols: [DocumentSymbolInfo], parents: [String]) -> String? {
        for symbol in symbols {
            let names = parents + [normalized(symbol.name)]
            if symbol.selection.0 == position { return names.joined(separator: ".") }
            if symbol.contains(position), let found = declared(at: position, in: symbol.children, parents: names) { return found }
        }
        return nil
    }

    private struct Place: Hashable {
        let uri: String, line: Int, start: Int, endLine: Int, end: Int
        init(_ l: SourceLocation) { uri = l.uri; line = l.start.line; start = l.start.character; endLine = l.end.line; end = l.end.character }
    }
}
