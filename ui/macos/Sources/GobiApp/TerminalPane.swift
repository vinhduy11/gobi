import AppKit
import GobiClient
import GobiModel
import SwiftTerm

/// A small square button for the terminal strip (new terminal, menu) with a soft highlight under the pointer.
private final class StripButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 24) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        guard let image else { return }
        let box = image.size
        image.draw(in: NSRect(x: bounds.midX - box.width / 2, y: bounds.midY - box.height / 2, width: box.width, height: box.height),
                   from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    }
}

/// One terminal tab, as a pill: its title and a close mark, with an accent outline when selected.
private final class TerminalTabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(title)") ?? NSImage(), target: self, action: #selector(closePressed))
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [label, close])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            close.widthAnchor.constraint(equalToConstant: 12), close.heightAnchor.constraint(equalToConstant: 12),
        ])
        selected = isSelected
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("Terminal \(title)")
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var selected = false

    override func updateLayer() {
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.clear).cgColor
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.clear).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closePressed() { onClose?() }
}

/// The Terminal tab of the bottom panel, as in the mock: one tab per shell with a new, shell menu, split and kill control,
/// the terminal below, and a notice instead when the project is not trusted. SwiftTerm draws and understands the terminal;
/// gobid runs the shell on its pty channel.
final class TerminalPane: NSView, TerminalViewDelegate {
    private final class Session {
        let view: TerminalView
        var client: TerminalClient?
        var title: String
        var exited = false
        /// Text typed before the shell connected, sent once it has.
        var pending: [[UInt8]] = []
        init(view: TerminalView, title: String) { self.view = view; self.title = title }
    }

    private let root: URL
    private let trusted: Bool
    private var sessions: [Session] = []
    private var selected = 0
    private let strip = NSStackView()
    private let host = NSView()
    private let notice = NSView()
    var onTrustRequested: (() -> Void)?

    var sessionCount: Int { sessions.count }
    var titles: [String] { sessions.map(\.title) }
    var isShowingNotice: Bool { !notice.isHidden }

    init(root: URL, trusted: Bool) {
        self.root = root
        self.trusted = trusted
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { sessions.forEach { $0.client?.close() } }

    /// What the selected terminal shows, as text, for the self-test.
    var screenText: String {
        guard sessions.indices.contains(selected) else { return "" }
        return String(decoding: sessions[selected].view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// The background the selected terminal uses, as 0-255 components, for the self-test.
    var background: [Int]? {
        guard sessions.indices.contains(selected) else { return nil }
        let view = sessions[selected].view
        func components(_ color: NSColor) -> [Int] {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return [Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())]
        }
        return components(view.nativeBackgroundColor)
    }

    /// Types into the selected terminal as if from the keyboard.
    func type(_ text: String) {
        guard sessions.indices.contains(selected) else { return }
        if let client = sessions[selected].client { client.send(Array(text.utf8)) } else { sessions[selected].pending.append(Array(text.utf8)) }
    }

    /// Runs a command in the selected terminal, starting one when there is none. Only a trusted project has a terminal.
    func run(_ command: String) {
        guard trusted else { return }
        if sessions.isEmpty { newTerminal() }
        type(command + "\r")
    }

    func killSelected() { killPressed() }

    // MARK: layout

    private func build() {
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        host.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        let column = NSStackView(views: [strip, rule, host])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        buildNotice()
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.widthAnchor.constraint(equalTo: column.widthAnchor), rule.widthAnchor.constraint(equalTo: column.widthAnchor),
            host.widthAnchor.constraint(equalTo: column.widthAnchor),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor), notice.trailingAnchor.constraint(equalTo: trailingAnchor),
            notice.topAnchor.constraint(equalTo: topAnchor), notice.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        column.isHidden = !trusted
        notice.isHidden = trusted
        rebuildStrip()
    }

    /// "Terminals are off in Restricted Mode", with the way out, as in the Restricted mock.
    private func buildNotice() {
        let title = NSTextField(labelWithString: "Terminals are off in Restricted Mode")
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let text = NSTextField(wrappingLabelWithString: "A terminal runs commands as you, and a project you have not trusted can put commands in its files. Trust the project to open a terminal here.")
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 560
        let trust = NSButton(title: "Trust Project…", target: self, action: #selector(trustPressed))
        trust.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, text, trust])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 20, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        notice.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: notice.leadingAnchor), stack.topAnchor.constraint(equalTo: notice.topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: notice.trailingAnchor),
        ])
    }

    @objc private func trustPressed() { onTrustRequested?() }

    private func rebuildStrip() {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in TerminalTitle.numbered(sessions.map(\.title)).enumerated() {
            let tab = TerminalTabView(title: title, isSelected: index == selected)
            tab.onSelect = { [weak self] in self?.select(index) }
            tab.onClose = { [weak self] in self?.close(at: index) }
            strip.addArrangedSubview(tab)
        }
        // The new-terminal and menu buttons sit right after the tabs, set off by a divider.
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        strip.addArrangedSubview(divider)
        strip.addArrangedSubview(iconButton("plus", "New Terminal", #selector(newPressed)))
        strip.addArrangedSubview(iconButton("chevron.down", "Terminal menu", #selector(menuPressed(_:))))
        strip.addArrangedSubview(NSView())
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector?) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium).applying(.init(paletteColors: [.labelColor]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration) ?? NSImage()
        let button = StripButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.isEnabled = action != nil
        button.setAccessibilityLabel(label)
        return button
    }

    // MARK: colours

    /// The palette for the window's current light or dark appearance, with the soft ANSI colours.
    private func applyPalette(to view: TerminalView) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = TerminalPalette.forAppearance(isDark: isDark)
        func native(_ color: RGB) -> NSColor { NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1) }
        func swiftTermColor(_ color: RGB) -> Color { Color(red: UInt16(color.red) * 257, green: UInt16(color.green) * 257, blue: UInt16(color.blue) * 257) }
        view.installColors(palette.ansi.map(swiftTermColor))
        view.nativeBackgroundColor = native(palette.background)
        view.nativeForegroundColor = native(palette.foreground)
        view.caretColor = native(palette.cursor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sessions.forEach { applyPalette(to: $0.view) }
    }

    // MARK: sessions

    /// Starts the first shell the first time the tab is shown.
    func startIfNeeded() {
        if trusted && sessions.isEmpty { newTerminal() }
    }

    @objc private func newPressed() { newTerminal() }

    func newTerminal() {
        guard trusted else { return }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyPalette(to: view)
        let title = TerminalTitle.make(shellPath: ProcessInfo.processInfo.environment["SHELL"], folder: root.lastPathComponent)
        let session = Session(view: view, title: title)
        sessions.append(session)
        select(sessions.count - 1)
        let rootPath = root.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
            do {
                let client = try TerminalClient(workspaceRoot: rootPath, trusted: true)
                DispatchQueue.main.async {
                    guard let self, let view, self.sessions.contains(where: { $0.view === view }) else { client.close(); return }
                    session.client = client
                    for queued in session.pending { client.send(queued) }
                    session.pending.removeAll()
                    client.onOutput = { [weak view] bytes in DispatchQueue.main.async { view?.feed(byteArray: bytes[...]) } }
                    client.onExit = { [weak view, weak session] code, message in
                        DispatchQueue.main.async {
                            session?.exited = true
                            let text = message.isEmpty ? "\r\n[Process exited with code \(code)]\r\n" : "\r\n\(message)\r\n"
                            view?.feed(text: text)
                        }
                    }
                    client.start()
                    let terminal = view.getTerminal()
                    client.resize(columns: terminal.cols, rows: terminal.rows)
                }
            } catch {
                DispatchQueue.main.async { view?.feed(text: "Cannot start a terminal: \(error)\r\n") }
            }
        }
    }

    private func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        selected = index
        host.subviews.forEach { $0.removeFromSuperview() }
        let view = sessions[index].view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        rebuildStrip()
        window?.makeFirstResponder(view)
    }

    @objc private func killPressed() { close(at: selected) }

    /// Ends the shell of tab `index` and removes the tab; the neighbour takes over.
    private func close(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions.remove(at: index)
        session.client?.close()
        session.view.removeFromSuperview()
        if sessions.isEmpty {
            host.subviews.forEach { $0.removeFromSuperview() }
            rebuildStrip()
        } else {
            select(min(index < selected ? selected - 1 : selected, sessions.count - 1))
        }
    }

    /// The menu of the mock: new, split, kill, clear and the shell. Only new, kill and clear are live.
    @objc private func menuPressed(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Terminal", action: #selector(newPressed), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Split Terminal", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Kill Terminal", action: #selector(killPressed), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear", action: #selector(clearPressed), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        let current = menu.addItem(withTitle: "\((shell as NSString).lastPathComponent) (login shell)", action: nil, keyEquivalent: "")
        current.state = .on
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func clearPressed() {
        guard sessions.indices.contains(selected) else { return }
        sessions[selected].view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        sessions[selected].client?.send([0x0c])   // the shell redraws its prompt
    }

    // MARK: TerminalViewDelegate

    private func session(for view: TerminalView) -> Session? { sessions.first { $0.view === view } }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session(for: source)?.client?.send(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session(for: source)?.client?.resize(columns: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
