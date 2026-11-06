// What the UI tells core about the caret: the declaration under it (from the document symbols gopls reported), its fields or
// signature, and the live text. Core parses the text itself; these facts are what it cannot read from a lone file.

public enum GoSignature {
    public struct Parsed: Equatable {
        public var params: [GenerateField] = []
        public var results: [String] = []
    }

    /// Reads a signature as gopls prints it in a symbol's detail: `func(a int, b string) (int, error)`. Anything else gives nothing.
    public static func parse(_ text: String) -> Parsed {
        var chars = Array(text.trimmed)
        if chars.starts(with: Array("func")) { chars.removeFirst(4) }
        chars = Array(String(chars).trimmed)
        guard chars.first == "(", let close = matchingClose(chars, from: 0) else { return Parsed() }
        var parsed = Parsed()
        parsed.params = fields(splitTop(String(chars[1 ..< close])))
        let rest = Array(String(chars[(close + 1)...]).trimmed)
        if rest.first == "(", let end = matchingClose(rest, from: 0), end == rest.count - 1 {
            parsed.results = fields(splitTop(String(rest[1 ..< end]))).map(\.type)
        } else if !rest.isEmpty {
            parsed.results = [String(rest)]
        }
        return parsed
    }

    private static func matchingClose(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0
        for index in open ..< chars.count {
            if "([{".contains(chars[index]) { depth += 1 } else if ")]}".contains(chars[index]) {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func splitTop(_ text: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for c in text {
            if "([{".contains(c) { depth += 1 } else if ")]}".contains(c) { depth -= 1 }
            if c == ",", depth == 0 { parts.append(current); current = "" } else { current.append(c) }
        }
        parts.append(current)
        return parts.map(\.trimmed).filter { !$0.isEmpty }
    }

    private static let typeWords: Set<String> = ["chan", "func", "map", "struct", "interface"]

    /// `a int`, `int`, or a bare `a` that shares the type of the next named entry (`a, b int`).
    private static func fields(_ entries: [String]) -> [GenerateField] {
        var out: [(name: String, type: String?)] = entries.map { entry in
            if let space = entry.firstIndex(of: " "), isIdentifier(String(entry[..<space])), !typeWords.contains(String(entry[..<space])) {
                return (String(entry[..<space]), String(entry[entry.index(after: space)...]).trimmed)
            }
            return (entry, nil)
        }
        let anyNamed = out.contains { $0.type != nil }
        var shared: String?
        for index in out.indices.reversed() {
            if let type = out[index].type { shared = type } else if anyNamed, let type = shared { out[index].type = type }
        }
        return out.map { anyNamed ? GenerateField(name: $0.name, type: $0.type ?? $0.name) : GenerateField(name: "", type: $0.name) }
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

extension StringProtocol {
    var trimmed: String {
        var scalars = Substring(self)
        while let c = scalars.first, c == " " || c == "\t" || c == "\n" || c == "\r" { scalars.removeFirst() }
        while let c = scalars.last, c == " " || c == "\t" || c == "\n" || c == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}

public enum GenerateContext {
    /// The request for the caret: kind and name of the top-level declaration it is in, its fields, methods or signature.
    /// `symbols` were read at `version`, which the answers echo.
    public static func make(path: String, package: String, source: String, caret: LSPPosition, symbols: [DocumentSymbolInfo], version: UInt64, goVersion: String) -> GenerateRequest {
        var request = GenerateRequest()
        request.path = path
        request.package = package
        request.source = source
        request.line = caret.line
        request.column = caret.character
        request.version = version
        request.goVersion = goVersion
        request.kind = isEmpty(source) && symbols.isEmpty ? "empty" : "file"
        guard let top = symbols.first(where: { $0.contains(caret) }) else { return request }
        switch top.kind {
        case .type where top.detail.hasPrefix("struct"):
            request.kind = "struct"
            request.name = top.name
            request.fields = top.children.filter { $0.kind == .field && !$0.detail.isEmpty && !$0.name.contains(".") }
                .map { GenerateField(name: $0.name, type: $0.detail) }
        case .type where top.detail.hasPrefix("interface"):
            request.kind = "interface"
            request.name = top.name
            request.methods = top.children.filter { $0.kind == .method }.map { child in
                let signature = GoSignature.parse(child.detail)
                return GenerateMethod(name: child.name, params: signature.params, results: signature.results)
            }
        case .function, .method:
            let (receiver, name) = splitMethodName(top.name)
            let signature = GoSignature.parse(top.detail)
            request.kind = "func"
            request.name = name
            request.receiver = receiver
            request.params = signature.params
            request.results = signature.results
        default:
            break
        }
        return request
    }

    /// `(*Server).Run` and `Server.Run` give ("Server", "Run"); a plain name gives ("", name).
    static func splitMethodName(_ name: String) -> (String, String) {
        if name.hasPrefix("("), let close = name.firstIndex(of: ")") {
            var receiver = String(name[name.index(after: name.startIndex) ..< close])
            if receiver.hasPrefix("*") { receiver.removeFirst() }
            if let bracket = receiver.firstIndex(of: "[") { receiver = String(receiver[..<bracket]) }
            let rest = name[name.index(after: close)...]
            return (receiver, rest.hasPrefix(".") ? String(rest.dropFirst()) : String(rest))
        }
        if let dot = name.lastIndex(of: ".") { return (String(name[..<dot]), String(name[name.index(after: dot)...])) }
        return ("", name)
    }

    /// Nothing but blank lines, comments and the package clause.
    static func isEmpty(_ source: String) -> Bool {
        source.split(separator: "\n", omittingEmptySubsequences: true).allSatisfy { line in
            let text = line.trimmed
            return text.isEmpty || text.hasPrefix("//") || text.hasPrefix("package ")
        }
    }
}

public enum GenerateInsertion {
    /// Where the first line of `snippet` lands once all `edits` are applied to `original`, or nil when no edit holds it.
    public static func caret(of snippet: String, edits: [TextEdit], in original: String) -> LSPPosition? {
        let units = Array(original.utf16)
        let index = LineIndex(utf16: units)
        let snippetUnits = Array(snippet.utf16)
        guard !snippetUnits.isEmpty else { return nil }
        let located = edits.map { (start: index.offset(of: $0.start), end: index.offset(of: $0.end), text: Array($0.newText.utf16)) }
        guard let holder = located.first(where: { contains($0.text, snippetUnits) }), let inside = find(snippetUnits, in: holder.text) else { return nil }
        // Edits that start before the holder move it by how much longer or shorter their text is than what it replaces.
        let shift = located.filter { $0.start < holder.start || ($0.start == holder.start && $0.end < holder.end) }
            .reduce(0) { $0 + $1.text.count - ($1.end - $1.start) }
        let offset = holder.start + shift + inside
        var result = units
        for edit in located.sorted(by: { $0.start > $1.start }) { result.replaceSubrange(edit.start ..< max(edit.start, edit.end), with: edit.text) }
        return LineIndex(utf16: result).position(at: offset)
    }

    private static func contains(_ text: [UInt16], _ part: [UInt16]) -> Bool { find(part, in: text) != nil }

    private static func find(_ part: [UInt16], in text: [UInt16]) -> Int? {
        guard part.count <= text.count else { return nil }
        for start in 0 ... text.count - part.count where Array(text[start ..< start + part.count]) == part { return start }
        return nil
    }
}
