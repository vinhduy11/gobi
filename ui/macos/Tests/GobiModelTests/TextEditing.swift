@testable import GobiModel

/// Applies one edit to the text and to its line index the way the editor does: the index is told the unit before and the
/// unit after the edited range, which it needs to see line breaks being joined or split. Returns what changed.
@discardableResult
func applyEdit(_ index: inout LineIndex, _ text: inout [UInt16], range: Range<Int>, with replacement: [UInt16]) -> LineChange {
    let unitBefore = range.lowerBound > 0 ? text[range.lowerBound - 1] : nil
    let unitAfter = range.upperBound < text.count ? text[range.upperBound] : nil
    text.replaceSubrange(range, with: replacement)
    return index.replace(range: range, with: replacement, before: unitBefore, after: unitAfter)
}
