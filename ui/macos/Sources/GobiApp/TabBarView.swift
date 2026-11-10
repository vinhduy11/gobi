import AppKit
import GobiClient
import GobiEditor
import GobiModel

/// One tab: the file name (with a dot while it has unsaved edits) and a close button.
private final class TabItemView: NSView {
    let path: String
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var menuProvider: ((String) -> NSMenu?)?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(path: String, title: String, isActive: Bool, isDirty: Bool) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (isActive ? ThemeColors.accent.withAlphaComponent(0.18) : NSColor.clear).cgColor
        layer?.cornerRadius = 6
        label.stringValue = (isDirty ? "● " : "") + title
        label.font = NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? ThemeColors.uiText : ThemeColors.uiSecondaryText
        label.lineBreakMode = .byTruncatingMiddle
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(title)")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        let row = NSStackView(views: [label, closeButton])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14), closeButton.heightAnchor.constraint(equalToConstant: 14),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title + (isDirty ? ", unsaved changes" : ""))
        setAccessibilityValue(isActive ? 1 : 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onSelect?(path) }

    override func otherMouseDown(with event: NSEvent) { onClose?(path) }   // middle click

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(path) }

    @objc private func closePressed() { onClose?(path) }
}

/// A horizontal strip of tabs that follows a TabStrip; it only draws and reports clicks, the owner changes the model.
final class TabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// The right-click menu of a tab, by the tab's path.
    var menuProvider: ((String) -> NSMenu?)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private(set) var titles: [String] = []

    /// Frames of the tab items in the bar's own coordinates, after layout. Empty when no tab is drawn.
    var itemFrames: [NSRect] {
        layoutSubtreeIfNeeded()
        return stack.arrangedSubviews.map { convert($0.bounds, from: $0) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        // A stack used as a document view has no size unless it is pinned: the tabs set its width, the bar its height.
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
        ])
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Open files")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A strip of its own: the window colour with a hairline under it, so inactive tabs stay readable in both appearances.
    override func draw(_ dirtyRect: NSRect) {
        ThemeColors.tabStripBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func reload(_ tabs: TabStrip) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titles = tabs.paths.map { ($0 as NSString).lastPathComponent }
        for path in tabs.paths {
            let item = TabItemView(path: path, title: (path as NSString).lastPathComponent, isActive: path == tabs.active, isDirty: tabs.isDirty(path))
            item.onSelect = { [weak self] in self?.onSelect?($0) }
            item.onClose = { [weak self] in self?.onClose?($0) }
            item.menuProvider = { [weak self] in self?.menuProvider?($0) }
            stack.addArrangedSubview(item)
        }
    }
}
