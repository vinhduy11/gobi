import AppKit

public enum NoticeStyle: Sendable { case info, warning, error }

public struct NoticeAction {
    public let title: String
    public let run: () -> Void
    public init(title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
}

/// A line of text with buttons above the editor: the file changed on disk, was deleted, or is read-only (External changes mock).
final class NoticeBar: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var actions: [NoticeAction] = []
    private var fill = NSColor.clear

    var text: String { label.stringValue }
    var actionTitles: [String] { actions.map(\.title) }

    init() {
        super.init(frame: .zero)
        label.font = NSFont.systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.spacing = 6
        let row = NSStackView(views: [label, NSView(), buttons])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notice")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ message: String, style: NoticeStyle, actions: [NoticeAction]) {
        label.stringValue = message
        self.actions = actions
        let base: NSColor
        switch style {
        case .info: base = .systemBlue
        case .warning: base = .systemOrange
        case .error: base = .systemRed
        }
        fill = base.withAlphaComponent(0.16)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            buttons.addArrangedSubview(button)
        }
        isHidden = false
        needsDisplay = true
    }

    func hide() { isHidden = true; actions = []; label.stringValue = "" }

    func pressForTest(_ index: Int) { if actions.indices.contains(index) { actions[index].run() } }

    @objc private func pressed(_ sender: NSButton) { if actions.indices.contains(sender.tag) { actions[sender.tag].run() } }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
