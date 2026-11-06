// LSP snippet syntax ("helper(${1:a int}, ${2:b string})$0") as plain text plus the tab stops to visit, and the session that
// tracks those stops while the user types. Offsets are UTF-16 units, like the editor's text.

public struct SnippetStop: Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    var end: Int { location + length }
}

public struct Snippet: Equatable {
    public let text: String
    /// In the order Tab visits them: $1, $2, ..., then $0 (or the end of the text when the snippet has no $0).
    public let stops: [SnippetStop]

    /// Placeholders become their default text, a choice becomes its first option, variables become their default or nothing.
    /// Text that is not valid snippet syntax (a stray `$`, an unclosed `${`) stays as it is.
    public static func parse(_ source: String) -> Snippet {
        var parser = Parser(input: Array(source.utf16))
        _ = parser.sequence(nested: false)
        var ordered = parser.found.enumerated().filter { $0.element.number != 0 }.sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }.map(\.element.stop)
        ordered += parser.found.filter { $0.number == 0 }.map(\.stop)
        if !parser.found.contains(where: { $0.number == 0 }) { ordered.append(SnippetStop(location: parser.output.count, length: 0)) }
        return Snippet(text: String(decoding: parser.output, as: UTF16.self), stops: ordered)
    }

    private struct Parser {
        let input: [UInt16]
        var index = 0
        var output: [UInt16] = []
        var found: [(number: Int, stop: SnippetStop)] = []

        init(input: [UInt16]) { self.input = input }

        static let dollar: UInt16 = 36, backslash: UInt16 = 92, openBrace: UInt16 = 123, closeBrace: UInt16 = 125, colon: UInt16 = 58, pipe: UInt16 = 124, comma: UInt16 = 44

        private func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
        private func isNameStart(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 }
        private func peek(_ offset: Int = 0) -> UInt16? { index + offset < input.count ? input[index + offset] : nil }

        /// Reads text up to the end, or up to the `}` that closes a placeholder (true when it was found).
        mutating func sequence(nested: Bool) -> Bool {
            while let unit = peek() {
                if unit == Self.backslash, let next = peek(1), next == Self.dollar || next == Self.closeBrace || next == Self.backslash {
                    output.append(next)
                    index += 2
                } else if unit == Self.closeBrace, nested {
                    index += 1
                    return true
                } else if unit == Self.dollar, dollar() {
                    continue
                } else {
                    output.append(unit)
                    index += 1
                }
            }
            return false
        }

        private mutating func number() -> Int {
            var digits = 0
            while let unit = peek(), isDigit(unit) { digits = digits * 10 + Int(unit - 48); index += 1 }
            return digits
        }

        private mutating func skipName() {
            while let unit = peek(), isNameStart(unit) || isDigit(unit) { index += 1 }
        }

        /// At a `$`: reads a tab stop or variable. False (nothing consumed) when it is not one.
        private mutating func dollar() -> Bool {
            let saved = (index, output.count, found.count)
            index += 1
            guard let unit = peek() else { index = saved.0; return false }
            if isDigit(unit) {
                found.append((number(), SnippetStop(location: output.count, length: 0)))
                return true
            }
            if isNameStart(unit) { skipName(); return true }
            if unit == Self.openBrace, braced() { return true }
            index = saved.0
            output.removeLast(output.count - saved.1)
            found.removeLast(found.count - saved.2)
            return false
        }

        private mutating func braced() -> Bool {
            index += 1
            guard let unit = peek() else { return false }
            let isStop = isDigit(unit)
            let stopNumber = isStop ? number() : 0
            if !isStop { guard isNameStart(unit) else { return false }; skipName() }
            let start = output.count
            switch peek() {
            case Self.closeBrace?:
                index += 1
            case Self.colon?:
                index += 1
                guard sequence(nested: true) else { return false }
            case Self.pipe? where isStop:
                index += 1
                var first = true
                while let next = peek(), next != Self.pipe {
                    if next == Self.comma { first = false } else if first { output.append(next) }
                    index += 1
                }
                guard peek() == Self.pipe, peek(1) == Self.closeBrace else { return false }
                index += 2
            default:
                return false
            }
            if isStop { found.append((stopNumber, SnippetStop(location: start, length: output.count - start))) }
            return true
        }
    }
}

/// The tab stops of an inserted snippet, in absolute text offsets, kept in step with edits while the user fills them in.
public struct SnippetSession: Equatable {
    private var stops: [SnippetStop]
    private var index = 0

    public init(stops: [SnippetStop], base: Int) {
        self.stops = stops.map { SnippetStop(location: $0.location + base, length: $0.length) }
    }

    public var current: SnippetStop? { stops.indices.contains(index) ? stops[index] : nil }
    /// True once the last stop is the current one: the next Tab is an ordinary Tab.
    public var isFinished: Bool { index >= stops.count - 1 }

    /// From the first stop's start to the last stop's end; a caret outside it means the user has left the snippet.
    public var span: ClosedRange<Int>? {
        guard let low = stops.map(\.location).min(), let high = stops.map(\.end).max() else { return nil }
        return low ... high
    }

    /// Moves to the next stop and returns it; nil after the last one.
    public mutating func advance() -> SnippetStop? {
        guard !isFinished else { return nil }
        index += 1
        return stops[index]
    }

    /// The text changed: `oldLength` units at `location` were replaced by `newLength` units.
    public mutating func edited(at location: Int, oldLength: Int, newLength: Int) {
        let delta = newLength - oldLength, editEnd = location + oldLength
        for position in stops.indices {
            let stop = stops[position]
            if position == index, location >= stop.location, editEnd <= stop.end {
                stops[position].length = max(0, stop.length + delta)
            } else if stop.location >= editEnd {
                stops[position].location += delta
            } else if stop.end > location, position != index {
                stops[position].length = max(0, stop.length + delta)
            }
        }
    }
}
