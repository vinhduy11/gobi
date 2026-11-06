import AppKit
import GobiModel

/// A one-line panel above the caret with the signature of the call being typed; the active parameter is bold.
private final class SignaturePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Signature")
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4), label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ signature: SignatureText, above rect: NSRect, in parent: NSWindow) {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let parts = signature.parts
        let text = NSMutableAttributedString(string: parts.before, attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: parts.active, attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: parts.after, attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = text
        let size = label.fittingSize
        let screenWidth = parent.screen?.visibleFrame.width ?? 900
        setContentSize(NSSize(width: min(size.width + 20, screenWidth - 40), height: size.height + 8))
        setFrameOrigin(NSPoint(x: rect.minX - 6, y: rect.maxY + 4))
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Signature help for one editor: typing `(` or `,` asks `provider` for the signature at the caret and shows it; `)` or Esc
/// closes it. `trigger()` asks on demand (⇧⌘Space).
public final class SignatureController {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private let panel = SignaturePanel()
    private var generation = 0

    /// Asks for the signature at a position; calls back on the main thread with nil when the caret is not in a call.
    public var provider: ((LSPPosition, @escaping (SignatureText?) -> Void) -> Void)?
    public private(set) var currentText: SignatureText?
    public var isOpen: Bool { currentText != nil }

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
    }

    /// Called after the user typed `string` into the editor.
    func typed(_ string: String) {
        switch string {
        case "(", ",": trigger()
        case ")": dismiss()
        default: break
        }
    }

    public func trigger() {
        guard let textView, textView.selectedRange().length == 0 else { return }
        generation += 1
        let mine = generation
        provider?(document.lineIndex.position(at: textView.selectedRange().location)) { [weak self] signature in
            guard let self, mine == self.generation else { return }
            guard let signature, let textView = self.textView, let window = textView.window else { self.hidePanel(); return }
            self.currentText = signature
            let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            self.panel.show(signature, above: rect, in: window)
        }
    }

    public func dismiss() {
        generation += 1
        hidePanel()
    }

    private func hidePanel() {
        currentText = nil
        panel.hide()
    }

    /// Esc closes the popup; true when it was open.
    func handle(command selector: Selector) -> Bool {
        guard isOpen, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismiss()
        return true
    }
}
