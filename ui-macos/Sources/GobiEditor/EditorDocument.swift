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
    /// A file with a line longer than this (in UTF-16 units) opens read-only. TextKit lays out a paragraph as one unit, so an
    /// edit costs about 0.1 ms per 1,000 characters of the paragraph, whatever the wrap width. Measured on JSON on one line
    /// (layout only; with painting a keystroke costs about 50% more): 100,000 characters 15 ms, 250,000 30 ms, 500,000 55 ms
    /// (89 ms with painting), 1,000,000 about 100 ms. 550,000 keeps a keystroke under 100 ms including painting.
    public static let editableLineLimit = 550_000
    /// True when the file was opened with a line over `editableLineLimit`; the editor then does not accept edits.
    public let isReadOnlyByLineLength: Bool
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
        self.isReadOnlyByLineLength = (0 ..< index.lineCount).contains { index.lineRange($0).count > Self.editableLineLimit }
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
        // The two units around the edit let the index see a "\r" and a "\n" being joined into one break or split.
        let storageText = textStorage.string as NSString
        let unitBefore: UInt16? = editedRange.location > 0 ? storageText.character(at: editedRange.location - 1) : nil
        let unitAfter: UInt16? = editedRange.upperBound < storageText.length ? storageText.character(at: editedRange.upperBound) : nil
        let change = lineIndex.replace(range: oldRange, with: insertedUnits, before: unitBefore, after: unitAfter)
        version += 1
        if lineIndex.lineRange(change.firstLine).count > Self.overlongLineLimit { hasOverlongLine = true }

        let changed = syntaxIndex.update(firstLine: change.firstLine, oldLineCount: change.oldLineCount, newLineCount: change.newLineCount) { [self] line in
            lineUnits(line, in: textStorage)
        }
        onSyntaxChanged?(change.firstLine ..< change.firstLine + change.newLineCount, changed)

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
