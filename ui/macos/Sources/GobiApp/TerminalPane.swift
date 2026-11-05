import AppKit
import GobiClient
import GobiModel
import SwiftTerm

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
        strip.spacing = 6
        strip.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
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
            let button = NSButton(title: title, target: self, action: #selector(tabPressed(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: index == selected ? .semibold : .regular)
            button.contentTintColor = index == selected ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityLabel("Terminal \(title)")
            strip.addArrangedSubview(button)
        }
        strip.addArrangedSubview(NSView())
        strip.addArrangedSubview(iconButton("plus", "New Terminal", #selector(newPressed)))
        strip.addArrangedSubview(iconButton("chevron.down", "Terminal menu", #selector(menuPressed(_:))))
        strip.addArrangedSubview(iconButton("rectangle.split.2x1", "Split Terminal (not available yet)", nil))
        strip.addArrangedSubview(iconButton("trash", "Kill Terminal", #selector(killPressed)))
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector?) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        button.isEnabled = action != nil
        button.setAccessibilityLabel(label)
        return button
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

    @objc private func tabPressed(_ sender: NSButton) { select(sender.tag) }

    @objc private func killPressed() {
        guard sessions.indices.contains(selected) else { return }
        let session = sessions.remove(at: selected)
        session.client?.close()
        session.view.removeFromSuperview()
        if sessions.isEmpty { host.subviews.forEach { $0.removeFromSuperview() }; rebuildStrip() } else { select(min(selected, sessions.count - 1)) }
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
