/// Finds where a Go function ends, for the Profiler's source view. Not a parser: a brace scanner that skips strings,
/// runes, raw strings and comments.
public enum GoFunctionRange {
    private enum Mode { case code, block, raw }

    /// The lines of the function declared at the 1-based line `from`: up to the brace that closes its body. Nil when
    /// the line is outside the file or the body never closes.
    public static func lines(in source: [String], from: Int) -> ClosedRange<Int>? {
        guard from >= 1, from <= source.count else { return nil }
        var mode = Mode.code
        var parens = 0, depth = 0
        var bodyOpen = false
        var previousWord = ""
        for index in (from - 1) ..< source.count {
            let chars = Array(source[index])
            var position = 0
            var word = ""
            while position < chars.count {
                let char = chars[position]
                switch mode {
                case .block:
                    if char == "*", position + 1 < chars.count, chars[position + 1] == "/" { mode = .code; position += 1 }
                case .raw:
                    if char == "`" { mode = .code }
                case .code:
                    if char.isLetter || char.isNumber || char == "_" { word.append(char); position += 1; continue }
                    if !word.isEmpty { previousWord = word; word = "" }
                    if char == "/", position + 1 < chars.count, chars[position + 1] == "/" { position = chars.count; continue }
                    if char == "/", position + 1 < chars.count, chars[position + 1] == "*" { mode = .block; position += 1 }
                    else if char == "`" { mode = .raw }
                    else if char == "\"" || char == "'" { position = skipQuoted(chars, from: position) }
                    else if char == "(" { parens += 1 }
                    else if char == ")" { parens -= 1 }
                    else if char == "{" {
                        let typeLiteral = previousWord == "struct" || previousWord == "interface"
                        if !bodyOpen, parens == 0, !typeLiteral { bodyOpen = true }
                        depth += 1
                    } else if char == "}" {
                        depth -= 1
                        if bodyOpen, depth == 0 { return from ... (index + 1) }
                    }
                    if char != " " && char != "\t" { previousWord = "" }
                }
                position += 1
            }
            if mode == .code, !word.isEmpty { previousWord = word }
        }
        return nil
    }

    /// The closing quote of a string or rune literal that opens at `start`: its index, or the end of the line.
    private static func skipQuoted(_ chars: [Character], from start: Int) -> Int {
        var position = start + 1
        while position < chars.count {
            if chars[position] == "\\" { position += 2; continue }
            if chars[position] == chars[start] { return position }
            position += 1
        }
        return chars.count
    }

    /// The nearest line at or above `line` (1-based) that starts a `func` declaration; the fallback when a profile has no start line.
    public static func declaration(in source: [String], atOrBefore line: Int) -> Int? {
        var number = min(line, source.count)
        while number >= 1 {
            let text = source[number - 1]
            if text.hasPrefix("func ") || text.hasPrefix("func(") { return number }
            number -= 1
        }
        return nil
    }
}
