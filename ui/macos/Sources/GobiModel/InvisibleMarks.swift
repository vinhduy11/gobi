/// Where the "invisible characters" setting draws marks inside one paragraph: a tab (→), a space at the end of the line (·)
/// and the line end (¶). `offset` counts UTF-16 units from the start of the paragraph.
public struct InvisibleMark: Equatable, Sendable {
    public let offset: Int
    public let symbol: String
}

public enum InvisibleMarks {
    public static func find(in paragraph: String) -> [InvisibleMark] {
        let units = Array(paragraph.utf16)
        var end = units.count
        var lineEnd: InvisibleMark?
        // A paragraph ends with its line break; the mark goes on the break itself.
        if end > 0, units[end - 1] == 10 { end -= 1; lineEnd = InvisibleMark(offset: end, symbol: "¶") }
        if end > 0, units[end - 1] == 13, lineEnd != nil { end -= 1; lineEnd = InvisibleMark(offset: end, symbol: "¶") }
        var marks: [InvisibleMark] = []
        var trailingStart = end
        while trailingStart > 0, units[trailingStart - 1] == 32 { trailingStart -= 1 }
        for index in 0 ..< end {
            if units[index] == 9 { marks.append(InvisibleMark(offset: index, symbol: "→")) }
            else if units[index] == 32, index >= trailingStart { marks.append(InvisibleMark(offset: index, symbol: "·")) }
        }
        if let lineEnd { marks.append(lineEnd) }
        return marks
    }
}
