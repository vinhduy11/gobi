// What the editor does when a bracket or quote is typed, Backspace is pressed between a pair, or Return is pressed: the pairing and
// auto-indent rules, as pure functions over the characters around the caret. The text view carries the result out.

public enum AutoClose {
    public enum Action: Equatable, Sendable {
        case none
        /// Insert this text and put the caret `caretBack` characters before its end (`{}` with 1 puts it between the braces).
        case insert(String, caretBack: Int)
        /// The typed closer is already there: move over it instead of typing it.
        case skip
        /// Put `open` and `close` around the selection.
        case wrap(open: String, close: String)
    }

    private static let partners: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`", "'": "'"]
    private static let closers: Set<Character> = [")", "]", "}"]
    private static let quotes: Set<Character> = ["\"", "`", "'"]

    public static func typed(_ typed: Character, before: Character?, after: Character?, hasSelection: Bool) -> Action {
        guard let partner = partners[typed] else {
            // A closing bracket typed right before the same one is moved over, not doubled.
            return closers.contains(typed) && after == typed && !hasSelection ? .skip : .none
        }
        if hasSelection { return .wrap(open: String(typed), close: String(partner)) }
        if quotes.contains(typed) {
            if after == typed { return .skip }
            // A quote after a word (don't, a`b) or after the same quote (the second of "") is just a character.
            if let before, isWord(before) || before == typed { return .none }
            // `'` is also an apostrophe in comments and prose: it pairs only where a rune literal could start (after an operator).
            return opensAPair(after: after) ? .insert(String(typed) + String(partner), caretBack: 1) : .none
        }
        return opensAPair(after: after) ? .insert(String(typed) + String(partner), caretBack: 1) : .none
    }

    /// Backspace with the caret between `before` and `after`: both go when they are a pair.
    public static func removesPair(before: Character?, after: Character?) -> Bool {
        guard let before, let after, let partner = partners[before] else { return false }
        return partner == after
    }

    public enum NewlineEdit: Equatable, Sendable {
        case insert(String, caretBack: Int)
    }

    /// Return: a new line with the indentation of the current one, one `indentUnit` deeper after an opening bracket; between a bracket
    /// pair (`{|}`) it opens a block: the caret goes on an indented empty line and the closer on the line below.
    public static func newline(lineBeforeCaret: String, after: Character?, indentUnit: String) -> NewlineEdit {
        var base = ""
        for character in lineBeforeCaret {
            if character == " " || character == "\t" { base.append(character) } else { break }
        }
        let trimmed = trimTrailingSpaces(lineBeforeCaret)
        let last = trimmed.last
        let opens = last == "{" || last == "(" || last == "["
        if let last, let after, opens, partners[last] == after, closers.contains(after) {
            return .insert("\n" + base + indentUnit + "\n" + base, caretBack: 1 + base.count)
        }
        return .insert("\n" + base + (opens ? indentUnit : ""), caretBack: 0)
    }

    private static func opensAPair(after: Character?) -> Bool {
        guard let after else { return true }
        return after == " " || after == "\t" || after == "\n" || after == "\r" || closers.contains(after) || after == "," || after == ";"
    }

    private static func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }

    private static func trimTrailingSpaces(_ text: String) -> String {
        var characters = Array(text)
        while let last = characters.last, last == " " || last == "\t" { characters.removeLast() }
        return String(characters)
    }
}
