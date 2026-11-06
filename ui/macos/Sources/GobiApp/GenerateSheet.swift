import AppKit
import GobiModel

/// The Generate dialog of the mock: what the item asks for, where to insert, and a live preview of the code. It edits a
/// `GenerateForm`; the hints and the enabled state come from the model.
final class GenerateSheet: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private(set) var form: GenerateForm
    var requestPreview: ((GenerateForm, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onFinish: ((GenerateForm?) -> Void)?

    private let panel: NSPanel
    private let offersNewFile: Bool
    private let hintLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private var previewTimer: Timer?
    private weak var parentWindow: NSWindow?

    init(form: GenerateForm, offersNewFile: Bool) {
        self.form = form
        self.offersNewFile = offersNewFile
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    func present(on window: NSWindow) {
        parentWindow = window
        window.beginSheet(panel)
        refresh()
        schedulePreview(delay: 0)
    }

    // MARK: building

    private func build() {
        let item = form.item
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        let title = NSTextField(labelWithString: "Generate " + (item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title))
        title.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(title)
        if !item.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: item.detail)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 480
            stack.addArrangedSubview(detail)
        }
        if item.needsName { stack.addArrangedSubview(row("Name", field: singleLine(form.name, id: "name"))) }
        for param in item.params {
            let multiline = param.multi && param.kind != "names"
            stack.addArrangedSubview(row(param.label, field: multiline ? multiLine(form.text(of: param.key), id: param.key) : singleLine(form.text(of: param.key), id: param.key)))
        }
        if item.needsFields && !form.fieldNames.isEmpty {
            let fields = NSStackView()
            fields.orientation = .vertical
            fields.alignment = .leading
            fields.spacing = 2
            for name in form.fieldNames {
                let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(tickChanged(_:)))
                box.state = form.isTicked(name) ? .on : .off
                fields.addArrangedSubview(box)
            }
            stack.addArrangedSubview(row("Fields", field: fields))
        }
        if offersNewFile {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Current file", "New file \(form.newFileName)"])
            popup.target = self
            popup.action = #selector(targetChanged(_:))
            stack.addArrangedSubview(row("Insert", field: popup))
        }
        hintLabel.textColor = .systemOrange
        hintLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(hintLabel)

        preview.isEditable = false
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        Self.makeScrollable(preview)
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(scroll)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        generateButton.target = self
        generateButton.action = #selector(finish(_:))
        generateButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, generateButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(buttons)

        panel.contentView = stack
        panel.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
    }

    /// A bare `NSTextView` has a zero frame and does not track its scroll view, so its text never shows.
    private static func makeScrollable(_ text: NSTextView) {
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
    }

    private func row(_ label: String, field: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [text, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    private func singleLine(_ value: String, id: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 350).isActive = true
        return field
    }

    private func multiLine(_ value: String, id: String) -> NSView {
        let text = NSTextView()
        text.identifier = NSUserInterfaceItemIdentifier(id)
        text.string = value
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.delegate = self
        Self.makeScrollable(text)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 350).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return scroll
    }

    // MARK: editing

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        edited(id, field.stringValue)
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView, let id = text.identifier?.rawValue else { return }
        edited(id, text.string)
    }

    private func edited(_ id: String, _ value: String) {
        if id == "name" { form.name = value } else { form.set(id, to: value) }
        refresh()
        schedulePreview(delay: 0.25)
    }

    @objc private func tickChanged(_ sender: NSButton) {
        form.setTicked(sender.title, sender.state == .on)
        refresh()
        schedulePreview(delay: 0.1)
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        form.target = sender.indexOfSelectedItem == 1 ? .file : .current
        schedulePreview(delay: 0.1)
    }

    private func refresh() {
        let keys = (form.item.needsName ? ["name"] : []) + form.item.params.map(\.key) + ["fields"]
        hintLabel.stringValue = keys.compactMap { form.hint(for: $0) }.first ?? ""
        generateButton.isEnabled = form.canGenerate
    }

    private func schedulePreview(delay: TimeInterval) {
        previewTimer?.invalidate()
        guard form.canGenerate else { return }
        previewTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.requestPreview?(self.form) { [weak self] outcome in
                switch outcome {
                case .success(let text): self?.preview.string = text
                case .failure(let error): self?.preview.string = "\(error)"
                }
            }
        }
    }

    @objc private func cancel(_ sender: Any?) { close(with: nil) }

    @objc private func finish(_ sender: Any?) { close(with: form) }

    private func close(with result: GenerateForm?) {
        previewTimer?.invalidate()
        parentWindow?.endSheet(panel)
        panel.orderOut(nil)
        onFinish?(result)
    }
}
