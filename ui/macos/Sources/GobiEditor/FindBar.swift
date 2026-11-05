import AppKit

/// Find in file: a search field with previous/next buttons above the editor. Matches are found with NSString.range(of:),
/// the selection moves to the match and the view scrolls by text position, so a match anywhere in a 100k-line file costs
/// one scan and no layout of the text in between.
final class FindBar: NSStackView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private weak var textView: NSTextView?
    private(set) var searchString = ""

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        field.placeholderString = "Find"
        field.delegate = self
        field.setAccessibilityLabel("Find in file")
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let previous = NSButton(title: "‹", target: self, action: #selector(previousMatch))
        let next = NSButton(title: "›", target: self, action: #selector(nextMatch))
        previous.setAccessibilityLabel("Previous match")
        next.setAccessibilityLabel("Next match")
        status.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        for item in [field, previous, next, status, done] { addArrangedSubview(item) }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        isHidden = false
        if let selected = textView?.selectedRange(), selected.length > 0, selected.length < 200,
           let text = textView?.string as NSString? {
            setSearchString(text.substring(with: selected))
        }
        window?.makeFirstResponder(field)
    }

    func setSearchString(_ text: String) {
        searchString = text
        field.stringValue = text
    }

    @objc private func close() {
        isHidden = true
        status.stringValue = ""
        window?.makeFirstResponder(textView)
    }

    @objc func nextMatch() { find(forward: true) }
    @objc func previousMatch() { find(forward: false) }

    /// Selects the next (or previous) match after the selection, wrapping at the end (or start) of the text.
    @discardableResult
    func find(forward: Bool) -> NSRange? {
        guard let textView, !searchString.isEmpty else { return nil }
        let text = textView.string as NSString
        let selected = textView.selectedRange()
        let options: NSString.CompareOptions = forward ? [.caseInsensitive] : [.caseInsensitive, .backwards]
        let searched = forward ? NSRange(location: selected.upperBound, length: text.length - selected.upperBound)
                               : NSRange(location: 0, length: selected.lowerBound)
        var match = text.range(of: searchString, options: options, range: searched)
        var wrapped = false
        if match.location == NSNotFound {
            wrapped = true
            match = text.range(of: searchString, options: options)
        }
        guard match.location != NSNotFound else {
            status.stringValue = "No matches"
            return nil
        }
        status.stringValue = wrapped ? "Wrapped" : ""
        textView.setSelectedRange(match)
        textView.scrollRangeToVisible(match)
        return match
    }

    func controlTextDidChange(_ notification: Notification) {
        searchString = field.stringValue
        // Search from the start of the current selection so typing more of the word keeps the same match.
        if let textView { textView.setSelectedRange(NSRange(location: textView.selectedRange().lowerBound, length: 0)) }
        find(forward: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): find(forward: true)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}
