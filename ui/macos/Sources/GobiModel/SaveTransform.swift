/// The text changes applied when a file is saved (Settings > Editor > On save).
public enum SaveTransform {
    public static func apply(_ text: String, trimTrailingWhitespace: Bool, finalNewline: Bool) -> String {
        guard trimTrailingWhitespace || finalNewline else { return text }
        // Lines as (body, break); Swift sees "\r\n" as one Character, so walk the scalars.
        var lines: [(body: String.UnicodeScalarView, end: String)] = []
        var body = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pendingReturn = false
        while let scalar = scalars.next() {
            if pendingReturn {
                pendingReturn = false
                if scalar == "\n" { lines.append((body, "\r\n")); body = .init(); continue }
                lines.append((body, "\r")); body = .init()
            }
            if scalar == "\r" { pendingReturn = true } else if scalar == "\n" { lines.append((body, "\n")); body = .init() } else { body.append(scalar) }
        }
        if pendingReturn { lines.append((body, "\r")); body = .init() }
        lines.append((body, ""))   // the text after the last break

        if trimTrailingWhitespace {
            for index in lines.indices { while let last = lines[index].body.last, last == " " || last == "\t" { lines[index].body.removeLast() } }
        }
        if finalNewline {
            // Drop blank lines at the end, keeping the break of the last line that has text.
            while lines.count > 2, lines[lines.count - 1].body.isEmpty, lines[lines.count - 2].body.isEmpty { lines.removeLast(2); lines.append((.init(), "")) }
            if lines.count == 1, lines[0].body.isEmpty { return "" }
            if let last = lines.last, !last.body.isEmpty {
                let style = lines.first { !$0.end.isEmpty }?.end ?? "\n"
                lines[lines.count - 1].end = style
            }
        }
        var out = ""
        for line in lines { out += String(line.body) + line.end }
        return out
    }
}
