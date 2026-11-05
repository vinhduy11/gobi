// Maps between UTF-16 offsets (what NSTextStorage and the LSP use) and line/column positions.
// Kept on [UInt16] with no Foundation dependency so it can be tested and benchmarked on its own.
//
// Line breaks are the ones the protocol defines: "\n", "\r\n" (one break) and a lone "\r".

public struct LSPPosition: Equatable, Hashable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// What an edit did to the lines: `oldLineCount` lines starting at `firstLine` became `newLineCount` lines.
/// Lines outside that range keep their text.
public struct LineChange: Equatable, Sendable {
    public var firstLine: Int
    public var oldLineCount: Int
    public var newLineCount: Int

    public init(firstLine: Int, oldLineCount: Int, newLineCount: Int) {
        self.firstLine = firstLine
        self.oldLineCount = oldLineCount
        self.newLineCount = newLineCount
    }
}

public struct LineIndex: Equatable {
    private static let lineFeed: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D

    /// Offset at which each line starts; always begins with 0. A text ending in a line break has an empty last line.
    private var lineStarts: [Int]
    /// Length of the break just before each line starts (0 for the first line): 1 for "\n" or a lone "\r", 2 for "\r\n".
    private var breakLengths: [UInt8]
    private var length: Int

    public init(utf16 text: [UInt16]) {
        var starts = [0]
        var lengths: [UInt8] = [0]
        var offset = 0
        while offset < text.count {
            let (breakLength, _) = Self.breakAt(text, offset)
            if breakLength > 0 {
                starts.append(offset + breakLength)
                lengths.append(UInt8(breakLength))
                offset += breakLength
            } else {
                offset += 1
            }
        }
        lineStarts = starts
        breakLengths = lengths
        length = text.count
    }

    /// Length of the line break that begins at `offset` (0 when there is none).
    private static func breakAt(_ text: [UInt16], _ offset: Int) -> (Int, Bool) {
        switch text[offset] {
        case lineFeed: return (1, false)
        case carriageReturn: return offset + 1 < text.count && text[offset + 1] == lineFeed ? (2, true) : (1, false)
        default: return (0, false)
        }
    }

    public var lineCount: Int { lineStarts.count }

    public func position(at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, length))
        let line = lineContaining(clamped)
        // Between the CR and the LF of a "\r\n" the offset is still the end of the line before it.
        return LSPPosition(line: line, character: min(clamped - lineStarts[line], lineRange(line).count))
    }

    public func offset(of position: LSPPosition) -> Int {
        guard position.line >= 0, position.line < lineStarts.count else { return length }
        let range = lineRange(position.line)
        return min(range.lowerBound + max(0, position.character), range.upperBound)
    }

    /// Offsets of line `line` without its line break. Out-of-range lines give an empty range at the end of the text.
    public func lineRange(_ line: Int) -> Range<Int> {
        guard line >= 0, line < lineStarts.count else { return length ..< length }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - Int(breakLengths[line + 1]) : length
        return lineStarts[line] ..< end
    }

    /// Updates the index for replacing `range` of the text with `replacement`, without rescanning the document.
    ///
    /// `before` is the unit just before `range` and `after` the unit at its end (nil at the ends of the text). They matter
    /// because an edit can join a "\r" and a "\n" into one break or split one, so the breaks around the edit are read again.
    @discardableResult
    public mutating func replace(range: Range<Int>, with replacement: [UInt16], before: UInt16? = nil, after: UInt16? = nil) -> LineChange {
        // Only a CR before and an LF after can combine with the new text into a different break.
        let joinsBefore = before == Self.carriageReturn
        let joinsAfter = after == Self.lineFeed
        let windowStart = range.lowerBound - (joinsBefore ? 1 : 0)
        let windowEnd = range.upperBound + (joinsAfter ? 1 : 0)

        let firstLine = lineContaining(windowStart)
        let lastLine = lineContaining(range.upperBound)

        // The old breaks that overlap the window go away; the breaks in the new window text take their place.
        let firstRemoved = firstLineStart(after: windowStart)
        var endRemoved = firstRemoved
        while endRemoved < lineStarts.count && lineStarts[endRemoved] - Int(breakLengths[endRemoved]) < windowEnd { endRemoved += 1 }

        var windowText: [UInt16] = []
        if joinsBefore { windowText.append(Self.carriageReturn) }
        windowText.append(contentsOf: replacement)
        if joinsAfter { windowText.append(Self.lineFeed) }
        var newStarts: [Int] = []
        var newBreakLengths: [UInt8] = []
        var cursor = 0
        while cursor < windowText.count {
            let (breakLength, _) = Self.breakAt(windowText, cursor)
            if breakLength > 0 {
                newStarts.append(windowStart + cursor + breakLength)
                newBreakLengths.append(UInt8(breakLength))
                cursor += breakLength
            } else {
                cursor += 1
            }
        }

        let delta = replacement.count - range.count
        for later in endRemoved ..< lineStarts.count { lineStarts[later] += delta }
        lineStarts.replaceSubrange(firstRemoved ..< endRemoved, with: newStarts)
        breakLengths.replaceSubrange(firstRemoved ..< endRemoved, with: newBreakLengths)
        length += delta

        let oldLineCount = lastLine - firstLine + 1
        return LineChange(firstLine: firstLine, oldLineCount: oldLineCount, newLineCount: oldLineCount + newStarts.count - (endRemoved - firstRemoved))
    }

    /// The line whose text or break contains `offset`.
    private func lineContaining(_ offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Index in `lineStarts` of the first line that starts after `offset`.
    private func firstLineStart(after offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
