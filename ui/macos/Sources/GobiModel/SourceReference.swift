// A `file.go:12:5` mention in compiler or test output, so the output panels can make it a link. Pure text in and out.

public struct SourceReference: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int?
    /// Where the mention starts and how long it is, in UTF-16 units of the line.
    public let offset: Int
    public let length: Int

    public init(path: String, line: Int, column: Int?, offset: Int, length: Int) {
        self.path = path; self.line = line; self.column = column; self.offset = offset; self.length = length
    }

    /// Every `name.go:LINE` or `name.go:LINE:COL` in one line of output. Only `.go` files are recognised: other tools print
    /// other shapes and a false link is worse than a missing one.
    public static func find(in text: String) -> [SourceReference] {
        let units = Array(text.utf16)
        var found: [SourceReference] = []
        var index = 0
        while index < units.count {
            // A mention starts at the beginning of a word: after a space, tab, quote, parenthesis or the start of the line.
            guard isStart(units, index) else { index += 1; continue }
            var end = index
            while end < units.count, !isSeparator(units[end]) { end += 1 }
            if let reference = parse(units, from: index, to: end) {
                found.append(reference)
                index = end
            } else {
                index = end == index ? index + 1 : end
            }
        }
        return found
    }

    private static func isSeparator(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 34 || unit == 40 || unit == 41 || unit == 39 }
    private static func isStart(_ units: [UInt16], _ index: Int) -> Bool { index == 0 || isSeparator(units[index - 1]) }

    private static func parse(_ units: [UInt16], from start: Int, to end: Int) -> SourceReference? {
        // path ends with ".go", then ":" LINE, optionally ":" COL; anything after (a colon, a message) is not part of it.
        // Find the first ".go:" in the word; the path is everything before the colon.
        var cursor = start
        while cursor + 3 < end, !(units[cursor] == 46 && units[cursor + 1] == 103 && units[cursor + 2] == 111 && units[cursor + 3] == 58) { cursor += 1 }
        guard cursor + 3 < end else { return nil }
        let pathEnd = cursor + 3
        var position = pathEnd + 1
        let (line, afterLine) = number(units, position, end)
        guard let lineNumber = line else { return nil }
        position = afterLine
        var column: Int?
        if position < end, units[position] == 58 {
            let (value, afterColumn) = number(units, position + 1, end)
            if let value { column = value; position = afterColumn }
        }
        let path = String(decoding: units[start ..< pathEnd], as: UTF16.self)
        return SourceReference(path: path, line: lineNumber, column: column, offset: start, length: position - start)
    }

    private static func number(_ units: [UInt16], _ from: Int, _ end: Int) -> (Int?, Int) {
        var value = 0, index = from
        while index < end, units[index] >= 48, units[index] <= 57 { value = value * 10 + Int(units[index] - 48); index += 1 }
        return (index == from ? nil : value, index)
    }
}
