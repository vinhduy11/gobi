import AppKit
import GobiClient

/// Draws diagnostic underlines as TextKit 2 rendering attributes, which never touch the text storage.
/// Only the two underline keys are added and removed, so the syntax colours that SyntaxHighlighter sets on the
/// same ranges survive. (setRenderingAttributes replaces every key on a range and would drop the colour.)
public enum DiagnosticUnderlines {
    /// Clears the underlines of earlier diagnostics, then underlines each diagnostic that has a non-empty range.
    public static func apply(_ diagnostics: [LSPDiagnostic], to textView: NSTextView, lineIndex: LineIndex) {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: layout.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: layout.documentRange)
        let length = (textView.string as NSString).length
        for diagnostic in diagnostics {
            let start = lineIndex.offset(of: diagnostic.start)
            var end = lineIndex.offset(of: diagnostic.end)
            if end <= start { end = min(start + 1, length) }
            guard end > start,
                  let from = content.location(content.documentRange.location, offsetBy: start),
                  let to = content.location(from, offsetBy: end - start),
                  let range = NSTextRange(location: from, end: to) else { continue }
            let colour: NSColor = diagnostic.severity == 1 ? .systemRed : .systemOrange
            layout.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, for: range)
            layout.addRenderingAttribute(.underlineColor, value: colour, for: range)
        }
    }
}
