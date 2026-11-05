// LSP text edits (formatting, rename, code actions) applied to text held as UTF-16 units. Positions are line and UTF-16
// column, as in the protocol; every edit refers to the original text, not to the text after the other edits.

public struct TextEdit: Equatable {
    public var start: LSPPosition
    public var end: LSPPosition
    public var newText: String

    public init(start: LSPPosition, end: LSPPosition, newText: String) {
        self.start = start
        self.end = end
        self.newText = newText
    }
}

public enum TextEdits {
    /// The text after all `edits`. Edits are applied from the end of the text to the start, so earlier positions stay valid.
    public static func apply(_ edits: [TextEdit], to text: [UInt16], lineIndex: LineIndex) -> [UInt16] {
        var result = text
        let located = edits.map { edit -> (Range<Int>, [UInt16]) in
            let start = lineIndex.offset(of: edit.start)
            let end = max(start, lineIndex.offset(of: edit.end))
            return (start ..< end, Array(edit.newText.utf16))
        }
        for (range, replacement) in located.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// The lines from the first edit's start to the last edit's end, for repainting only what changed.
    public static func affectedLines(_ edits: [TextEdit], lineIndex: LineIndex) -> ClosedRange<Int>? {
        guard !edits.isEmpty else { return nil }
        let first = edits.map { $0.start.line }.min() ?? 0
        let last = edits.map { $0.end.line }.max() ?? first
        return first ... max(first, min(last, lineIndex.lineCount - 1))
    }
}
