import AppKit
import GobiClient

/// Keeps one open file in sync with the language server and with the syntax highlighter: tracks UTF-16 line
/// offsets as the text storage changes, sends didChange as incremental edits or full text, and re-lexes the
/// touched lines.
public final class EditorDocument: NSObject, NSTextStorageDelegate {
    public let fileURL: URL
    public let language: String
    public private(set) var lineIndex: LineIndex
    public private(set) var syntaxIndex: SyntaxIndex
    public private(set) var version = 1
    public private(set) var changesSent = 0
    /// A line longer than this (in UTF-16 units) is not syntax coloured: TextKit lays out a paragraph as one unit, and
    /// colouring it costs about 13 s per keystroke at 1 MB (3800-character Go lines cost 3 ms). Measured on the 1 MB JSON.
    public static let overlongLineLimit = 20_000
    /// True once the file has had a line over the limit (opened or typed). Sticky until the file is reopened.
    public private(set) var hasOverlongLine: Bool
    public var client: LSPClient?
    /// Called after an edit with the lines whose tokens changed, including lines below the edit.
    var onSyntaxChanged: ((_ editedLines: Range<Int>, _ changedLines: Range<Int>) -> Void)?
    private var syncKind: Int { client?.syncKind ?? 1 }

    public var uri: String { fileURL.absoluteString }

    public init(fileURL: URL, text: String) {
        self.fileURL = fileURL
        self.language = EditorDocument.language(for: fileURL)
        let units = Array(text.utf16)
        let index = LineIndex(utf16: units)
        self.lineIndex = index
        self.hasOverlongLine = (0 ..< index.lineCount).contains { index.lineRange($0).count > Self.overlongLineLimit }
        self.syntaxIndex = SyntaxIndex(language: EditorDocument.syntaxLanguage(for: language), lineCount: index.lineCount) { line in
            Array(units[index.lineRange(line)])
        }
        super.init()
    }

    public static func language(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "go": return "go"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        default: return "plaintext"
        }
    }

    static func syntaxLanguage(for language: String) -> SyntaxLanguage {
        switch language {
        case "go": return .go
        case "json": return .json
        case "markdown": return .markdown
        default: return .plain
        }
    }

    /// Workspace root: the nearest folder holding go.mod for Go files, otherwise the file's own folder.
    public var workspaceRoot: String {
        var directory = fileURL.deletingLastPathComponent()
        guard language == "go" else { return directory.path }
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("go.mod").path) { return directory.path }
            directory.deleteLastPathComponent()
        }
        return fileURL.deletingLastPathComponent().path
    }

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let oldRange = editedRange.location ..< editedRange.location + editedRange.length - delta
        let inserted = (textStorage.string as NSString).substring(with: editedRange)
        let insertedUnits = Array(inserted.utf16)

        let start = lineIndex.position(at: oldRange.lowerBound)
        let end = lineIndex.position(at: oldRange.upperBound)
        lineIndex.replace(range: oldRange, with: insertedUnits)
        version += 1
        if lineIndex.lineRange(start.line).count > Self.overlongLineLimit { hasOverlongLine = true }

        // Lines start..end collapse into one line plus one per newline typed.
        let newLineCount = insertedUnits.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        let changed = syntaxIndex.update(firstLine: start.line, oldLineCount: end.line - start.line + 1, newLineCount: newLineCount) { [self] line in
            lineUnits(line, in: textStorage)
        }
        onSyntaxChanged?(start.line ..< start.line + newLineCount, changed)

        switch syncKind {
        case 2:
            let range: [String: Any] = ["start": ["line": start.line, "character": start.character], "end": ["line": end.line, "character": end.character]]
            client?.didChange(uri: uri, version: version, changes: [["range": range, "text": inserted]])
            changesSent += 1
        case 1:
            client?.didChange(uri: uri, version: version, changes: [["text": textStorage.string]])
            changesSent += 1
        default:
            break
        }
    }

    private func lineUnits(_ line: Int, in textStorage: NSTextStorage) -> [UInt16] {
        let range = lineIndex.lineRange(line)
        var units = [UInt16](repeating: 0, count: range.count)
        (textStorage.string as NSString).getCharacters(&units, range: NSRange(location: range.lowerBound, length: range.count))
        return units
    }
}
