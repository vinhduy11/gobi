import AppKit
import GobiModel

/// One row of the popup: a kind letter, the label and the signature in grey.
private func symbol(for kind: CompletionKind) -> (String, NSColor) {
    switch kind {
    case .function, .method: return ("ƒ", NSColor.systemPurple)
    case .variable: return ("v", NSColor.systemBlue)
    case .field: return ("f", NSColor.systemTeal)
    case .type: return ("T", NSColor.systemOrange)
    case .module: return ("m", NSColor.systemGreen)
    case .keyword: return ("k", NSColor.systemPink)
    case .constant: return ("c", NSColor.systemIndigo)
    case .other: return ("·", NSColor.secondaryLabelColor)
    }
}

/// The popup under the caret that lists completions: a small panel that never takes the keyboard from the editor.
private final class CompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var items: [CompletionItem] = []
    static let rowHeight: CGFloat = 22
    static let width: CGFloat = 420
    var onChoose: ((Int) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = Self.width
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.target = self
        table.doubleAction = #selector(rowChosen)
        table.setAccessibilityLabel("Completions")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 3), scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -3),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ items: [CompletionItem], selected: Int, below rect: NSRect, in parent: NSWindow) {
        self.items = items
        table.reloadData()
        select(selected)
        let rows = min(items.count, 8)
        let height = CGFloat(rows) * Self.rowHeight + 6
        setContentSize(NSSize(width: Self.width, height: height))
        setFrameOrigin(NSPoint(x: rect.minX - 6, y: rect.minY - height - 2))
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    @objc private func rowChosen() { if table.clickedRow >= 0 { onChoose?(table.clickedRow) } }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let (letter, colour) = symbol(for: item.kind)
        let kind = NSTextField(labelWithString: letter)
        kind.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        kind.textColor = colour
        kind.alignment = .center
        kind.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: item.label)
        label.font = NSFont.systemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [kind, label, NSView(), detail])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.setAccessibilityLabel(item.label + (item.detail.isEmpty ? "" : ", " + item.detail))
        return stack
    }
}

/// Completion for one editor: asks `provider` for items when typing opens the list (a dot, or letters once an identifier has
/// begun) or when asked with ⌃Space, narrows them as more is typed, and puts the chosen one in with Tab or Return. Esc or
/// leaving the identifier closes it.
public final class CompletionController {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private let panel = CompletionPanel()
    private let snippets: SnippetTabs
    private var list: CompletionList?
    private var generation = 0

    /// Asks for the completions at a position; calls back on the main thread (empty when there are none).
    public var provider: ((LSPPosition, @escaping ([CompletionItem]) -> Void) -> Void)?

    public var isOpen: Bool { list != nil }
    public var visibleLabels: [String] { list?.visible.map(\.label) ?? [] }
    public var selectedLabel: String? { list?.selected?.label }

    init(textView: NSTextView, document: EditorDocument, snippets: SnippetTabs) {
        self.textView = textView
        self.document = document
        self.snippets = snippets
        panel.onChoose = { [weak self] index in
            guard var current = self?.list else { return }
            while current.selectedIndex != index { current.moveDown() }
            self?.list = current
            self?.accept()
        }
    }

    /// The identifier before the caret. Only a window of the text is read: copying the whole file on every keystroke made typing
    /// in a large file take ~100 ms.
    private func currentPrefix() -> (text: String, start: Int) {
        let caret = self.caret
        let text = (textView?.string ?? "") as NSString
        let end = min(caret, text.length)
        let from = max(0, end - 256)
        let window = Array(text.substring(with: NSRange(location: from, length: end - from)).utf16)
        let found = CompletionPrefix.current(before: window, caret: window.count)
        return (found.text, found.start + from)
    }
    private var caret: Int { textView?.selectedRange().location ?? 0 }

    /// Called after the user typed `string` into the editor.
    func typed(_ string: String) {
        guard textView?.selectedRange().length == 0 else { dismiss(); return }
        if list != nil {
            if CompletionTrigger.shouldClose(typed: string) { dismiss() } else { narrow() }
            return
        }
        let prefix = currentPrefix()
        if CompletionTrigger.shouldOpen(typed: string, prefixLength: prefix.text.count) { open() }
    }

    /// Called after text was deleted: the prefix shrinks, or the list closes when the identifier is gone.
    func deleted() {
        guard let current = list else { return }
        if caret < current.anchorOffset { dismiss() } else { narrow() }
    }

    /// ⌃Space.
    public func trigger() { open() }

    private func open() {
        generation += 1
        let mine = generation
        let position = document.lineIndex.position(at: caret)
        let anchor = currentPrefix().start
        provider?(position) { [weak self] items in
            guard let self, mine == self.generation, !items.isEmpty, self.caret >= anchor else { return }
            var list = CompletionList(items: items, anchorOffset: anchor)
            list.update(prefix: currentPrefix().text)
            guard !list.visible.isEmpty else { return }
            self.list = list
            self.present()
        }
    }

    private func narrow() {
        guard var current = list else { return }
        let prefix = currentPrefix()
        guard prefix.start >= current.anchorOffset else { dismiss(); return }
        let text = (textView?.string ?? "") as NSString
        let end = min(caret, text.length)
        current.update(prefix: text.substring(with: NSRange(location: current.anchorOffset, length: max(0, end - current.anchorOffset))))
        if current.visible.isEmpty { dismiss(); return }
        list = current
        present()
    }

    private func present() {
        guard let list, let textView, let window = textView.window else { return }
        let rect = textView.firstRect(forCharacterRange: NSRange(location: list.anchorOffset, length: 0), actualRange: nil)
        panel.show(list.visible, selected: list.selectedIndex, below: rect, in: window)
    }

    public func dismiss() {
        generation += 1
        list = nil
        panel.hide()
    }

    /// Arrow keys move, Tab and Return accept, Esc closes. Returns true when the command was used here.
    func handle(command selector: Selector) -> Bool {
        guard var current = list else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): current.moveDown()
        case #selector(NSResponder.moveUp(_:)): current.moveUp()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
        list = current
        panel.select(current.selectedIndex)
        return true
    }

    /// Puts the selected item in: gopls' own edit range when it sent one, else the typed prefix is replaced by the text.
    public func accept() {
        guard let current = list, let item = current.selected, let textView, let storage = textView.textStorage else { dismiss(); return }
        dismiss()
        var text = item.insertText
        var serverEdit: (start: Int, end: Int)?
        if let edit = item.replaces {
            serverEdit = (document.lineIndex.offset(of: edit.start), document.lineIndex.offset(of: edit.end))
            text = edit.newText
        }
        let (start, end) = CompletionRange.resolve(anchor: current.anchorOffset, caret: caret, serverEdit: serverEdit)
        let snippet = item.isSnippet ? Snippet.parse(text) : nil
        if let snippet { text = snippet.text }
        let range = NSRange(location: start, length: max(0, end - start))
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: start + (text as NSString).length, length: 0))
        if let snippet { snippets.begin(snippet, at: start) }
    }
}
