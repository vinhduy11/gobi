// Lexical syntax highlighting, one line at a time. A line is tokenized from the state the previous line ended in,
// which is what makes incremental updates possible (see SyntaxIndex). Offsets are UTF-16 units relative to the line.
// No Foundation dependency, so it can be tested and benchmarked on its own.

public enum SyntaxKind: UInt8, Sendable {
    case keyword, builtin, string, character, comment, number, heading, code, marker, key
    /// What gopls knows and the lexer cannot (see `SemanticTokens`), and directive comments like `//go:generate`.
    case typeName, function, parameter, property, constant, namespace, annotation
}

public struct SyntaxToken: Equatable, Sendable {
    public var start: Int32
    public var length: Int32
    public var kind: SyntaxKind
}

/// What a line leaves open for the next one.
public enum LexState: UInt8, Sendable {
    case normal, blockComment, rawString, fencedCode
}

public enum SyntaxLanguage: Sendable {
    case go, json, markdown, plain
}

public func tokenizeLine(_ line: [UInt16], state: LexState, language: SyntaxLanguage) -> (tokens: [SyntaxToken], end: LexState) {
    switch language {
    case .go: return GoLexer.tokenize(line, state: state)
    case .json: return (JSONLexer.tokenize(line), .normal)
    case .markdown: return MarkdownLexer.tokenize(line, state: state)
    case .plain: return ([], .normal)
    }
}

// MARK: shared helpers

private func ascii(_ character: Character) -> UInt16 { UInt16(character.asciiValue!) }

private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

private func isIdentifierStart(_ unit: UInt16) -> Bool {
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
}

private func isIdentifierPart(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }

/// `//go:name` as the first thing on a line is a compiler directive (go:generate, go:build, go:noinline), not prose.
private func isDirective(_ line: [UInt16], from start: Int, lineStart: Bool) -> Bool {
    guard lineStart, start >= 0 else { return false }
    for unit in line[..<start] where unit != 0x20 && unit != 0x09 { return false }
    let marker = Array("//go:".utf16)
    return line.count > start + marker.count && Array(line[start ..< start + marker.count]) == marker
}

// MARK: Go

private enum GoLexer {
    private struct Word {
        var text: [UInt16]
        var kind: SyntaxKind
    }

    private static let table: [UInt64: Word] = {
        let keywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"
        let builtins = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable true false iota nil append cap clear close complex copy delete imag len make max min new panic print println real recover"
        var words: [UInt64: Word] = [:]
        for (list, kind) in [(keywords, SyntaxKind.keyword), (builtins, .builtin)] {
            for word in list.split(separator: " ") {
                let units = Array(word.utf16)
                let key = hash(units[...])
                precondition(words[key] == nil, "hash collision between Go words")
                words[key] = Word(text: units, kind: kind)
            }
        }
        return words
    }()

    private static func hash(_ units: ArraySlice<UInt16>) -> UInt64 {
        var running: UInt64 = 0xCBF2_9CE4_8422_2325
        for unit in units { running = (running ^ UInt64(unit)) &* 0x0000_0100_0000_01B3 }
        return running
    }

    private static func classify(_ identifier: ArraySlice<UInt16>) -> SyntaxKind? {
        guard identifier.count >= 2, identifier.count <= 11, let word = table[hash(identifier)], word.text.elementsEqual(identifier) else { return nil }
        return word.kind
    }

    static func tokenize(_ line: [UInt16], state: LexState) -> (tokens: [SyntaxToken], end: LexState) {
        var tokens: [SyntaxToken] = []
        var state = state
        var cursor = 0
        let count = line.count

        func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            tokens.append(SyntaxToken(start: Int32(start), length: Int32(end - start), kind: kind))
        }
        /// Index just past `*/` at or after `from`, or nil.
        func blockCommentEnd(from: Int) -> Int? {
            var scan = from
            while scan + 1 < count {
                if line[scan] == ascii("*") && line[scan + 1] == ascii("/") { return scan + 2 }
                scan += 1
            }
            return nil
        }
        /// Index just past the closing quote of a string or rune starting at `start`, or the line end.
        func quotedEnd(_ start: Int, quote: UInt16) -> Int {
            var scan = start + 1
            while scan < count {
                if line[scan] == ascii("\\") { scan += 2; continue }
                if line[scan] == quote { return scan + 1 }
                scan += 1
            }
            return count
        }

        // Continue what the previous line left open.
        switch state {
        case .blockComment:
            if let end = blockCommentEnd(from: 0) { add(0, end, .comment); cursor = end; state = .normal } else {
                if count > 0 { add(0, count, .comment) }
                return (tokens, .blockComment)
            }
        case .rawString:
            if let close = line.firstIndex(of: ascii("`")) { add(0, close + 1, .string); cursor = close + 1; state = .normal } else {
                if count > 0 { add(0, count, .string) }
                return (tokens, .rawString)
            }
        default:
            break
        }

        while cursor < count {
            let unit = line[cursor]
            switch unit {
            case ascii("/") where cursor + 1 < count && line[cursor + 1] == ascii("/"):
                add(cursor, count, isDirective(line, from: cursor, lineStart: tokens.isEmpty) ? .annotation : .comment)
                return (tokens, .normal)
            case ascii("/") where cursor + 1 < count && line[cursor + 1] == ascii("*"):
                if let end = blockCommentEnd(from: cursor + 2) {
                    add(cursor, end, .comment)
                    cursor = end
                } else {
                    add(cursor, count, .comment)
                    return (tokens, .blockComment)
                }
            case ascii("\""):
                let end = quotedEnd(cursor, quote: unit)
                add(cursor, end, .string)
                cursor = end
            case ascii("'"):
                let end = quotedEnd(cursor, quote: unit)
                add(cursor, end, .character)
                cursor = end
            case ascii("`"):
                if let close = line[(cursor + 1)...].firstIndex(of: unit) {
                    add(cursor, close + 1, .string)
                    cursor = close + 1
                } else {
                    add(cursor, count, .string)
                    return (tokens, .rawString)
                }
            case _ where isDigit(unit) || (unit == ascii(".") && cursor + 1 < count && isDigit(line[cursor + 1])):
                let end = numberEnd(line, from: cursor)
                add(cursor, end, .number)
                cursor = end
            case _ where isIdentifierStart(unit):
                var end = cursor + 1
                while end < count && isIdentifierPart(line[end]) { end += 1 }
                if let kind = classify(line[cursor ..< end]) { add(cursor, end, kind) }
                cursor = end
            default:
                cursor += 1
            }
        }
        return (tokens, .normal)
    }

    private static func numberEnd(_ line: [UInt16], from start: Int) -> Int {
        let isHex = start + 1 < line.count && line[start] == ascii("0") && (line[start + 1] | 0x20) == ascii("x")
        var scan = start
        while scan < line.count {
            let unit = line[scan]
            if isIdentifierPart(unit) && unit < 0x80 || unit == ascii(".") {
                scan += 1
            } else if (unit == ascii("+") || unit == ascii("-")) && scan > start {
                let before = line[scan - 1] | 0x20
                guard before == ascii("p") || (before == ascii("e") && !isHex) else { break }
                scan += 1
            } else {
                break
            }
        }
        return scan
    }
}

// MARK: JSON

private enum JSONLexer {
    static func tokenize(_ line: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var cursor = 0
        let count = line.count
        while cursor < count {
            let unit = line[cursor]
            if unit == ascii("\"") {
                var end = cursor + 1
                while end < count {
                    if line[end] == ascii("\\") { end += 2; continue }
                    if line[end] == ascii("\"") { end += 1; break }
                    end += 1
                }
                end = min(end, count)
                var after = end
                while after < count && (line[after] == ascii(" ") || line[after] == ascii("\t")) { after += 1 }
                let isKey = after < count && line[after] == ascii(":")
                tokens.append(SyntaxToken(start: Int32(cursor), length: Int32(end - cursor), kind: isKey ? .key : .string))
                cursor = end
            } else if unit == ascii("-") || isDigit(unit) {
                var end = cursor + 1
                while end < count, isDigit(line[end]) || line[end] == ascii(".") || (line[end] | 0x20) == ascii("e") || line[end] == ascii("+") || line[end] == ascii("-") { end += 1 }
                tokens.append(SyntaxToken(start: Int32(cursor), length: Int32(end - cursor), kind: .number))
                cursor = end
            } else if unit >= 0x61 && unit <= 0x7A {
                var end = cursor + 1
                while end < count && line[end] >= 0x61 && line[end] <= 0x7A { end += 1 }
                let word = String(decoding: line[cursor ..< end], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(SyntaxToken(start: Int32(cursor), length: Int32(end - cursor), kind: .builtin))
                }
                cursor = end
            } else {
                cursor += 1
            }
        }
        return tokens
    }
}

// MARK: Markdown

private enum MarkdownLexer {
    static func tokenize(_ line: [UInt16], state: LexState) -> (tokens: [SyntaxToken], end: LexState) {
        let count = line.count
        var indent = 0
        while indent < count && indent < 3 && line[indent] == ascii(" ") { indent += 1 }
        let isFence = indent + 2 < count
            && ((line[indent] == ascii("`") && line[indent + 1] == ascii("`") && line[indent + 2] == ascii("`"))
                || (line[indent] == ascii("~") && line[indent + 1] == ascii("~") && line[indent + 2] == ascii("~")))

        if state == .fencedCode {
            if isFence { return ([SyntaxToken(start: 0, length: Int32(count), kind: .comment)], .normal) }
            return (count > 0 ? [SyntaxToken(start: 0, length: Int32(count), kind: .code)] : [], .fencedCode)
        }
        if isFence { return ([SyntaxToken(start: 0, length: Int32(count), kind: .comment)], .fencedCode) }

        if indent < count && line[indent] == ascii("#") {
            var hashes = indent
            while hashes < count && line[hashes] == ascii("#") { hashes += 1 }
            if hashes - indent <= 6 && (hashes == count || line[hashes] == ascii(" ") || line[hashes] == ascii("\t")) {
                return ([SyntaxToken(start: Int32(indent), length: Int32(count - indent), kind: .heading)], .normal)
            }
        }

        var tokens: [SyntaxToken] = []
        var cursor = 0
        while cursor < count && line[cursor] == ascii(" ") { cursor += 1 }
        if cursor < count {
            let first = line[cursor]
            if (first == ascii("-") || first == ascii("*") || first == ascii("+")), cursor + 1 < count, line[cursor + 1] == ascii(" ") {
                tokens.append(SyntaxToken(start: Int32(cursor), length: 1, kind: .marker))
                cursor += 1
            } else if isDigit(first) {
                var digits = cursor
                while digits < count && isDigit(line[digits]) { digits += 1 }
                if digits - cursor <= 9, digits + 1 < count, line[digits] == ascii(".") || line[digits] == ascii(")"), line[digits + 1] == ascii(" ") {
                    tokens.append(SyntaxToken(start: Int32(cursor), length: Int32(digits + 1 - cursor), kind: .marker))
                    cursor = digits + 1
                }
            }
        }
        while cursor < count {
            if line[cursor] == ascii("`"), let close = line[(cursor + 1)...].firstIndex(of: ascii("`")) {
                tokens.append(SyntaxToken(start: Int32(cursor), length: Int32(close + 1 - cursor), kind: .code))
                cursor = close + 1
            } else {
                cursor += 1
            }
        }
        return (tokens, .normal)
    }
}
