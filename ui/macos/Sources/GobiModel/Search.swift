/// One match from Find in Files (core/internal/search). Line is 0-based; start and end are UTF-16 columns of the whole line;
/// `text` may be a window of a very long line, beginning at column `textStart`.
public struct SearchHit: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let start: Int
    public let end: Int
    public let text: String
    public let textStart: Int
    public let replacement: String

    public init(path: String, line: Int, start: Int, end: Int, text: String, textStart: Int, replacement: String) {
        self.path = path; self.line = line; self.start = start; self.end = end; self.text = text; self.textStart = textStart; self.replacement = replacement
    }

    /// The text that was found, cut out of `text`.
    public var matched: String {
        let units = Array(text.utf16)
        let from = max(0, min(units.count, start - textStart)), to = max(from, min(units.count, end - textStart))
        return String(decoding: units[from ..< to], as: UTF16.self)
    }
}

public struct SearchGroup: Equatable, Sendable {
    public let path: String
    public let hits: [SearchHit]
}

public struct SearchResults: Equatable, Sendable {
    public var hits: [SearchHit] = []
    public var files = 0
    public var skipped = 0
    public var truncated = false
    public init() {}

    public static func parse(_ fields: [WireField]) throws -> SearchResults {
        var result = SearchResults()
        for field in fields {
            switch field.number {
            case 1:
                var path = "", text = "", replacement = ""
                var line = 0, start = 0, end = 0, textStart = 0
                for f in try WireField.parse(field.bytes) {
                    switch f.number {
                    case 1: path = f.string
                    case 2: line = Int(f.uint)
                    case 3: start = Int(f.uint)
                    case 4: end = Int(f.uint)
                    case 5: text = f.string
                    case 6: textStart = Int(f.uint)
                    case 7: replacement = f.string
                    default: break
                    }
                }
                result.hits.append(SearchHit(path: path, line: line, start: start, end: end, text: text, textStart: textStart, replacement: replacement))
            case 2: result.files = Int(field.uint)
            case 3: result.skipped = Int(field.uint)
            case 4: result.truncated = field.uint != 0
            default: break
            }
        }
        return result
    }

    /// The hits grouped by file, in the order the files first appear.
    public var groups: [SearchGroup] {
        var order: [String] = []
        var byPath: [String: [SearchHit]] = [:]
        for hit in hits {
            if byPath[hit.path] == nil { order.append(hit.path) }
            byPath[hit.path, default: []].append(hit)
        }
        return order.map { SearchGroup(path: $0, hits: byPath[$0] ?? []) }
    }

    public var summary: String {
        guard !hits.isEmpty else { return "No results" }
        var text = "\(hits.count) result\(hits.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
        if truncated { text += " · stopped at the limit" }
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }
}

public struct ReplaceEdit: Equatable, Sendable {
    public let line: Int
    public let start: Int
    public let end: Int
    public let replacement: String
}

/// What replacing hits in one file's current text would do. A hit whose text is no longer where the search found it is skipped.
public struct ReplacePlan: Equatable, Sendable {
    /// From the end of the file to its start, so they can be applied in order.
    public let edits: [ReplaceEdit]
    public let skipped: Int

    public static func make(hits: [SearchHit], text: String) -> ReplacePlan {
        let lines = Self.utf16Lines(text)
        var edits: [ReplaceEdit] = []
        var skipped = 0
        for hit in hits {
            guard lines.indices.contains(hit.line), hit.start >= 0, hit.end > hit.start, hit.end <= lines[hit.line].count,
                  String(decoding: lines[hit.line][hit.start ..< hit.end], as: UTF16.self) == hit.matched else { skipped += 1; continue }
            edits.append(ReplaceEdit(line: hit.line, start: hit.start, end: hit.end, replacement: hit.replacement))
        }
        edits.sort { ($0.line, $0.start) > ($1.line, $1.start) }
        return ReplacePlan(edits: edits, skipped: skipped)
    }

    public func apply(to text: String) -> String {
        var lines = Self.utf16Lines(text)
        for edit in edits where lines.indices.contains(edit.line) && edit.end <= lines[edit.line].count {
            lines[edit.line].replaceSubrange(edit.start ..< edit.end, with: Array(edit.replacement.utf16))
        }
        var joined: [UInt16] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(10) }
            joined += line
        }
        return String(decoding: joined, as: UTF16.self)
    }

    /// Lines as UTF-16 units, split on "\n" only (Swift would treat "\r\n" as one character).
    private static func utf16Lines(_ text: String) -> [[UInt16]] {
        var lines: [[UInt16]] = [[]]
        for unit in text.utf16 {
            if unit == 10 { lines.append([]) } else { lines[lines.count - 1].append(unit) }
        }
        return lines
    }
}

public enum ReplaceSelection {
    /// The hits of every file not in `excludingPaths`: what Replace All applies.
    public static func included(_ hits: [SearchHit], excludingPaths: Set<String>) -> [SearchHit] {
        hits.filter { !excludingPaths.contains($0.path) }
    }

    /// The hits of a repeated search that stand for what the person picked: the same spot when `exact` (one match), else the same files.
    public static func refresh(_ fresh: [SearchHit], chosen: [SearchHit], exact: Bool) -> [SearchHit] {
        if exact { return fresh.filter { hit in chosen.contains { $0.path == hit.path && $0.line == hit.line && $0.start == hit.start } } }
        let paths = Set(chosen.map(\.path))
        return fresh.filter { paths.contains($0.path) }
    }
}

public enum SearchHistory {
    public static let limit = 10

    /// `history` with `query` first: no duplicate, nothing blank, at most `limit` entries.
    public static func adding(_ query: String, to history: [String]) -> [String] {
        guard !query.isEmpty else { return history }
        return Array(([query] + history.filter { $0 != query }).prefix(limit))
    }
}

public enum SearchOptionsText {
    /// "*.go, internal/**.go" as separate globs.
    public static func globs(_ text: String) -> [String] {
        text.split(separator: ",").map { String($0).filter { $0 != " " } }.filter { !$0.isEmpty }
    }
}
