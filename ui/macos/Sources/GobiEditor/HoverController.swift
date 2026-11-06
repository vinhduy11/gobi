import AppKit
import GobiModel

/// A small panel with the documentation of what the pointer rests on, shown after a short pause and closed when the pointer
/// moves on or the user types.
private final class HoverPanel: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.maximumNumberOfLines = 16
        label.preferredMaxLayoutWidth = 520
        label.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    func show(_ text: String, near point: NSPoint, in parent: NSWindow) {
        label.stringValue = text
        let size = label.fittingSize
        setContentSize(NSSize(width: min(540, size.width + 20), height: size.height + 14))
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height - 14))
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Hover for one editor: when the pointer rests on text, asks `provider` what it is and shows the answer.
public final class HoverController {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private let panel = HoverPanel()
    private var timer: Timer?
    private var generation = 0
    private var shownIndex: Int?

    /// Asks for the hover text at a position (Markdown); calls back on the main thread with nil when there is none.
    public var provider: ((LSPPosition, @escaping (String?) -> Void) -> Void)?
    public var delay: TimeInterval = 0.5
    public private(set) var currentText: String?

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
    }

    func pointerMoved(to point: NSPoint) {
        timer?.invalidate()
        guard let textView else { return }
        let index = textView.characterIndexForInsertion(at: point)
        // Moving within the same word keeps the panel; moving elsewhere closes it and waits again.
        if let shownIndex, abs(shownIndex - index) <= 1 { return }
        hide()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.ask(at: index, near: point) }
    }

    /// Asks now, without waiting for the pointer (also how the self-test drives it).
    public func ask(at index: Int, near point: NSPoint? = nil) {
        guard let textView, index >= 0, index < (textView.string as NSString).length else { return }
        generation += 1
        let mine = generation
        provider?(document.lineIndex.position(at: index)) { [weak self] markdown in
            guard let self, mine == self.generation, let markdown else { return }
            let text = HoverText.plain(fromMarkdown: markdown)
            guard !text.isEmpty else { return }
            self.currentText = text
            self.shownIndex = index
            if let window = textView.window {
                let screen = point.map { textView.convert($0, to: nil) }.map { window.convertPoint(toScreen: $0) } ?? NSEvent.mouseLocation
                self.panel.show(text, near: screen, in: window)
            }
        }
    }

    public func hide() {
        timer?.invalidate()
        generation += 1
        shownIndex = nil
        currentText = nil
        panel.hide()
    }
}
