// Maps between UTF-16 offsets (what NSTextStorage and the LSP use) and line/column positions.
// Kept on [UInt16] with no Foundation dependency so it can be tested and benchmarked on its own.

public struct LSPPosition: Equatable, Hashable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LineIndex: Equatable {
    private static let newline: UInt16 = 0x0A

    /// Offset at which each line starts; always begins with 0. A text ending in a newline has an empty last line.
    private var lineStarts: [Int]
    private var length: Int

    public init(utf16 text: [UInt16]) {
        var starts = [0]
        for (offset, unit) in text.enumerated() where unit == Self.newline {
            starts.append(offset + 1)
        }
        lineStarts = starts
        length = text.count
    }

    public var lineCount: Int { lineStarts.count }

    public func position(at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, length))
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= clamped { low = middle } else { high = middle - 1 }
        }
        return LSPPosition(line: low, character: clamped - lineStarts[low])
    }

    public func offset(of position: LSPPosition) -> Int {
        guard position.line >= 0, position.line < lineStarts.count else { return length }
        let start = lineStarts[position.line]
        let end = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] - 1 : length
        return min(start + max(0, position.character), end)
    }

    /// Offsets of line `line` without its line break. Out-of-range lines give an empty range at the end of the text.
    public func lineRange(_ line: Int) -> Range<Int> {
        guard line >= 0, line < lineStarts.count else { return length ..< length }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
        return lineStarts[line] ..< end
    }

    /// Updates the index for replacing `range` of the text with `replacement`, without rescanning the document.
    public mutating func replace(range: Range<Int>, with replacement: [UInt16]) {
        let removedStart = firstLineStart(after: range.lowerBound)
        let removedEnd = firstLineStart(after: range.upperBound)
        let delta = replacement.count - range.count

        var inserted: [Int] = []
        for (offset, unit) in replacement.enumerated() where unit == Self.newline {
            inserted.append(range.lowerBound + offset + 1)
        }
        for later in removedEnd ..< lineStarts.count {
            lineStarts[later] += delta
        }
        lineStarts.replaceSubrange(removedStart ..< removedEnd, with: inserted)
        length += delta
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
