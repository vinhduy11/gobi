// The completion popup's logic: which items match what has been typed, in what order, which one is selected, and when typing
// opens or closes the popup. Plain values; the popup itself is in GobiEditor.

public struct CompletionList {
    public static let maxVisible = 200

    private let all: [CompletionItem]
    /// Where the typed prefix starts, in UTF-16 units from the start of the text.
    public let anchorOffset: Int
    public private(set) var visible: [CompletionItem]
    public private(set) var selectedIndex = 0

    public init(items: [CompletionItem], anchorOffset: Int) {
        all = items
        self.anchorOffset = anchorOffset
        visible = Array(items.prefix(Self.maxVisible))
    }

    public var selected: CompletionItem? { visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil }

    /// Keeps the items that match `prefix`: first those that start with it (ignoring case), then those that contain its letters
    /// in order. Within each group the server's order stays. The selection goes back to the first item.
    public mutating func update(prefix: String) {
        selectedIndex = 0
        if prefix.isEmpty {
            visible = Array(all.prefix(Self.maxVisible))
            return
        }
        let needle = Array(prefix.lowercased())
        var starting: [CompletionItem] = [], looser: [CompletionItem] = []
        for item in all {
            let label = Array(item.label.lowercased())
            if label.starts(with: needle) { starting.append(item) } else if Self.contains(needle, inOrderIn: label) { looser.append(item) }
        }
        visible = Array((starting + looser).prefix(Self.maxVisible))
    }

    private static func contains(_ needle: [Character], inOrderIn label: [Character]) -> Bool {
        var next = needle.startIndex
        for character in label where next < needle.endIndex && character == needle[next] { next += 1 }
        return next == needle.endIndex
    }

    public mutating func moveDown() {
        guard !visible.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % visible.count
    }

    public mutating func moveUp() {
        guard !visible.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + visible.count) % visible.count
    }
}

public enum CompletionPrefix {
    private static func isIdentifier(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
    }

    /// The identifier ending at `caret`: its text and where it starts. Empty (starting at the caret) after a dot or a space.
    public static func current(before text: [UInt16], caret: Int) -> (text: String, start: Int) {
        var start = min(caret, text.count)
        while start > 0, isIdentifier(text[start - 1]) { start -= 1 }
        return (String(decoding: text[start ..< min(caret, text.count)], as: UTF16.self), start)
    }
}

public enum CompletionTrigger {
    /// A dot always opens the list; a letter, digit or underscore opens it once an identifier has begun.
    public static func shouldOpen(typed: String, prefixLength: Int) -> Bool {
        if typed == "." { return true }
        guard let first = typed.unicodeScalars.first, typed.unicodeScalars.count == 1 else { return false }
        let isWordCharacter = first == "_" || (first.value < 128 && ((first.value >= 48 && first.value <= 57) || (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122)))
        return isWordCharacter && prefixLength >= 1
    }

    /// Anything that is not part of an identifier ends the list.
    public static func shouldClose(typed: String) -> Bool {
        guard let first = typed.unicodeScalars.first else { return false }
        return !(first == "_" || first.value > 127 || (first.value >= 48 && first.value <= 57) || (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122))
    }
}

public enum HoverText {
    public static let maxLines = 14

    /// Hover text from gopls is Markdown. For a small tooltip: code fences are dropped (the code stays), links keep only their
    /// label, and the text is cut to `maxLines` lines with an ellipsis.
    public static func plain(fromMarkdown markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.hasPrefix("```") }
        lines = lines.map(withoutLinks)
        while lines.first?.allSatisfy({ $0 == " " }) == true { lines.removeFirst() }
        while lines.last?.allSatisfy({ $0 == " " }) == true { lines.removeLast() }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) + ["…"] }
        return lines.joined(separator: "\n")
    }

    /// "[label](url)" becomes "label".
    private static func withoutLinks(_ line: String) -> String {
        var result = "", index = line.startIndex
        while index < line.endIndex {
            if line[index] == "[", let close = line[index...].firstIndex(of: "]"), line.index(after: close) < line.endIndex, line[line.index(after: close)] == "(",
               let end = line[line.index(after: close)...].firstIndex(of: ")") {
                result += line[line.index(after: index) ..< close]
                index = line.index(after: end)
            } else {
                result.append(line[index])
                index = line.index(after: index)
            }
        }
        return result
    }
}
