/// Per-line highlighting state for a whole document, updated incrementally as it is edited.
///
/// Each line stores the state it starts in and its tokens. After an edit only the touched lines are tokenized again,
/// plus following lines until a line starts in the state it already had: for ordinary code that is the edited line
/// itself; opening a `/*` or a raw string re-lexes down to the matching close.
public struct SyntaxIndex: Equatable {
    public let language: SyntaxLanguage
    private var startStates: [LexState]
    private var lineTokens: [[SyntaxToken]]

    public init(language: SyntaxLanguage, lineCount: Int, fetchLine: (Int) -> [UInt16]) {
        self.language = language
        startStates = []
        lineTokens = []
        startStates.reserveCapacity(lineCount)
        lineTokens.reserveCapacity(lineCount)
        var state = LexState.normal
        for line in 0 ..< lineCount {
            let lexed = tokenizeLine(fetchLine(line), state: state, language: language)
            startStates.append(state)
            lineTokens.append(lexed.tokens)
            state = lexed.end
        }
    }

    public var lineCount: Int { startStates.count }

    public func tokens(line: Int) -> [SyntaxToken] {
        line >= 0 && line < lineTokens.count ? lineTokens[line] : []
    }

    /// Replaces `oldLineCount` lines starting at `firstLine` with `newLineCount` lines whose text can now be read through
    /// `fetchLine`, and returns the lines whose tokens may have changed.
    @discardableResult
    public mutating func update(firstLine: Int, oldLineCount: Int, newLineCount: Int, fetchLine: (Int) -> [UInt16]) -> Range<Int> {
        let startState = firstLine < startStates.count ? startStates[firstLine] : .normal
        let placeholders = [LexState](repeating: .normal, count: newLineCount)
        startStates.replaceSubrange(firstLine ..< firstLine + oldLineCount, with: placeholders)
        lineTokens.replaceSubrange(firstLine ..< firstLine + oldLineCount, with: [[SyntaxToken]](repeating: [], count: newLineCount))

        var state = startState
        var line = firstLine
        let editedEnd = firstLine + newLineCount
        while line < startStates.count {
            if line >= editedEnd && startStates[line] == state { break }   // converged: the rest is unchanged
            let lexed = tokenizeLine(fetchLine(line), state: state, language: language)
            startStates[line] = state
            lineTokens[line] = lexed.tokens
            state = lexed.end
            line += 1
        }
        return firstLine ..< max(line, min(editedEnd, startStates.count))
    }
}
