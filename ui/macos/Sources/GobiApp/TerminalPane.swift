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

/// A terminal that puts what is selected on the pasteboard when "Copy on select" is on. SwiftTerm announces a changed
/// selection through the open `selectionChanged`.
final class GobiTerminalView: TerminalView {
    var copyOnSelect = false
    private(set) var selectionEvents = 0
    private var lastCopied = ""

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        selectionEvents += 1
        copyIfEnabled(getSelection())
    }

    /// Puts the selected text on the pasteboard when the setting is on and the text is new. Returns whether it did.
    @discardableResult
    func copyIfEnabled(_ text: String?) -> Bool {
        guard copyOnSelect, let text, !text.isEmpty, text != lastCopied else { return false }
        lastCopied = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
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
        /// A second terminal shown beside this one (Split Terminal).
        var split: Session?
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
    private let findField = NSSearchField()
    private let findLabel = NSTextField(labelWithString: "")
    private let findBar = NSStackView()
    private var findMatches: [TerminalMatch] = []
    private var findIndex = 0
    private(set) var shells: [String] = []
    private var loginShell = ""
    var onTrustRequested: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// The folder the newest shell was asked to start in.
    private(set) var lastStartFolder = ""
    var sessionCount: Int { sessions.count }
    var titles: [String] { sessions.map(\.title) }
    var isShowingNotice: Bool { !notice.isHidden }

    init(root: URL, trusted: Bool) {
        self.root = root
        self.trusted = trusted
        super.init(frame: .zero)
        build()
        if trusted { loadShells() }
        NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in self?.applySettingsToAll() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { sessions.forEach { $0.client?.close(); $0.split?.client?.close() } }

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
        findField.placeholderString = "Find in Terminal"
        findField.target = self
        findField.action = #selector(findEntered)
        findField.sendsSearchStringImmediately = true
        findField.controlSize = .small
        findField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        findLabel.textColor = .secondaryLabelColor
        findLabel.font = NSFont.systemFont(ofSize: 12)
        let previous = NSButton(title: "↑", target: self, action: #selector(findPrevious))
        let next = NSButton(title: "↓", target: self, action: #selector(findNext))
        let done = NSButton(title: "Done", target: self, action: #selector(closeFind))
        for b in [previous, next, done] { b.bezelStyle = .rounded; b.controlSize = .small }
        findBar.setViews([findField, findLabel, previous, next, NSView(), done], in: .leading)
        findBar.spacing = 8
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        findBar.isHidden = true
        let column = NSStackView(views: [strip, rule, findBar, host])
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
            host.widthAnchor.constraint(equalTo: column.widthAnchor), findBar.widthAnchor.constraint(equalTo: column.widthAnchor),
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
        let learn = NSButton(title: "Learn More", target: self, action: #selector(learnMorePressed))
        learn.isBordered = false
        learn.contentTintColor = .controlAccentColor
        let buttons = NSStackView(views: [trust, learn])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, text, buttons])
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

    /// Restricted Mode explained (Terminal extras mock).
    @objc private func learnMorePressed() {
        let alert = NSAlert()
        alert.messageText = "About Restricted Mode"
        alert.informativeText = "A project you have not trusted can put commands in its files: go generate, cgo, tests, the toolchain line in go.mod.\n\nUntil you trust it, Gobi still edits, navigates and shows diagnostics, but turns off Run, Debug, Test, Profile, terminals, Git and environment profiles."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Trust Project…")
        if alert.runModal() == .alertSecondButtonReturn { onTrustRequested?() }
    }

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
        sessions.forEach { applyPalette(to: $0.view); if let split = $0.split { applyPalette(to: split.view) } }
    }

    // MARK: sessions

    /// Starts the first shell the first time the tab is shown.
    func startIfNeeded() {
        if trusted && sessions.isEmpty { newTerminal() }
    }

    @objc private func newPressed() { newTerminal() }

    func newTerminal() {
        guard trusted else { return }
        let session = makeSession()
        sessions.append(session)
        select(sessions.count - 1)
    }

    /// A terminal view and its shell, connecting in the background.
    private func makeSession() -> Session {
        let view = GobiTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.terminalDelegate = self
        // The library fixes the scrollback when the buffer is made, so it is set on a fresh view only.
        view.getTerminal().options.scrollback = AppPreferences.terminal.scrollback
        view.getTerminal().resetNormalBuffer()
        applySettings(to: view)
        applyPalette(to: view)
        let chosen = ShellChoice.effective(selected: WindowSettings.terminalShell, shells: shells, login: loginShell)
        let title = TerminalTitle.make(shellPath: chosen.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] : chosen, folder: root.lastPathComponent)
        let session = Session(view: view, title: title)
        let rootPath = AppPreferences.terminal.startIn.folder(project: root.path, home: NSHomeDirectory())
        lastStartFolder = rootPath
        let shell = WindowSettings.terminalShell
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
            do {
                let client = try TerminalClient(workspaceRoot: rootPath, trusted: true, shell: shell)
                DispatchQueue.main.async {
                    guard let self, let view, self.owns(view) else { client.close(); return }
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
        return session
    }

    /// Font size, cursor and Option key from Settings > Terminal.
    private func applySettings(to view: TerminalView) {
        let settings = AppPreferences.terminal
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        view.optionAsMetaKey = settings.optionAsMeta
        (view as? GobiTerminalView)?.copyOnSelect = settings.copyOnSelect
        let style: CursorStyle
        switch (settings.cursor, settings.blink) {
        case (.block, true): style = .blinkBlock
        case (.block, false): style = .steadyBlock
        case (.bar, true): style = .blinkBar
        case (.bar, false): style = .steadyBar
        case (.underline, true): style = .blinkUnderline
        case (.underline, false): style = .steadyUnderline
        }
        view.getTerminal().setCursorStyle(style)
    }

    private func applySettingsToAll() {
        for session in sessions {
            applySettings(to: session.view)
            if let split = session.split { applySettings(to: split.view) }
        }
    }

    /// For the self-test: the font size and Option setting the focused terminal has.
    var terminalAppearance: (fontSize: Int, optionAsMeta: Bool)? {
        guard sessions.indices.contains(selected) else { return nil }
        let view = sessions[selected].view
        return (Int(view.font.pointSize), view.optionAsMetaKey)
    }

    /// For the self-test: the scrollback the selected terminal was made with, and what copy on select has seen.
    var scrollbackLines: Int? { sessions.indices.contains(selected) ? sessions[selected].view.getTerminal().options.scrollback : nil }
    var copyOnSelectState: (enabled: Bool, selectionEvents: Int)? {
        guard sessions.indices.contains(selected), let view = sessions[selected].view as? GobiTerminalView else { return nil }
        return (view.copyOnSelect, view.selectionEvents)
    }

    /// For the self-test: selects the whole buffer, which makes SwiftTerm announce a selection.
    func selectAllForTest() { if sessions.indices.contains(selected) { sessions[selected].view.selectAll(nil) } }

    /// For the self-test: hands the terminal a selected text the way its selection callback does.
    func copySelectionForTest(_ text: String) -> Bool { (sessions.indices.contains(selected) ? sessions[selected].view as? GobiTerminalView : nil)?.copyIfEnabled(text) ?? false }

    private func owns(_ view: TerminalView) -> Bool { sessions.contains { $0.view === view || $0.split?.view === view } }

    private func loadShells() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let client = try? ControlClient.connect() else { return }
            defer { client.close() }
            guard let found = try? client.terminalShells() else { return }
            DispatchQueue.main.async { self?.shells = found.shells; self?.loginShell = found.login }
        }
    }

    private func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        selected = index
        host.subviews.forEach { $0.removeFromSuperview() }
        let session = sessions[index]
        let content: NSView
        if let split = session.split {
            let pair = NSSplitView()
            pair.isVertical = true
            pair.dividerStyle = .thin
            pair.addArrangedSubview(session.view)
            pair.addArrangedSubview(split.view)
            content = pair
        } else {
            content = session.view
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        rebuildStrip()
        window?.makeFirstResponder(session.view)
    }

    /// Split Terminal (⌘\): a second shell beside the selected one, in the same tab.
    func splitSelected() {
        guard trusted, sessions.indices.contains(selected), sessions[selected].split == nil else { return }
        sessions[selected].split = makeSession()
        select(selected)
        if let split = sessions[selected].split { window?.makeFirstResponder(split.view) }
    }

    var isSplit: Bool { sessions.indices.contains(selected) && sessions[selected].split != nil }

    @objc private func killPressed() { close(at: selected) }

    /// Ends the shell of tab `index` (and its split) and removes the tab; the neighbour takes over.
    private func close(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions.remove(at: index)
        for part in [session, session.split].compactMap({ $0 }) {
            part.client?.close()
            part.view.removeFromSuperview()
        }
        if sessions.isEmpty {
            host.subviews.forEach { $0.removeFromSuperview() }
            rebuildStrip()
        } else {
            select(min(index < selected ? selected - 1 : selected, sessions.count - 1))
        }
    }

    /// The menu of the mock: new, split, kill, clear, find, the shells and the settings.
    @objc private func menuPressed(_ sender: NSButton) {
        let menu = terminalMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    func terminalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ shortcut: String, _ action: Selector?) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            MainMenuBuilder.applyShortcut(shortcut, to: item)   // shown in the menu; this menu is not in the menu bar, so the keys act only through the pane
        }
        add("New Terminal", "⌃⇧`", #selector(newPressed))
        add("Split Terminal", "⌘\\", isSplit ? nil : #selector(splitPressed))
        add("Kill Terminal", "⌃D", #selector(killPressed))
        menu.addItem(.separator())
        add("Clear", "⌘K", #selector(clearPressed))
        add("Find in Terminal", "⌘F", #selector(showFind))
        menu.addItem(.separator())
        for choice in ShellChoice.menuItems(shells: shells, login: loginShell.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "") : loginShell, selected: WindowSettings.terminalShell) {
            let item = menu.addItem(withTitle: choice.title, action: #selector(shellChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.path
            item.state = choice.isChecked ? .on : .off
            item.toolTip = choice.path
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Terminal settings…", action: #selector(settingsPressed), keyEquivalent: "")
        settings.target = self
        return menu
    }

    @objc private func splitPressed() { splitSelected() }
    @objc private func settingsPressed() { onOpenSettings?() }

    /// Choosing a shell is remembered; it applies to terminals opened from now on.
    @objc private func shellChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        WindowSettings.terminalShell = path == loginShell ? "" : path
    }

    @objc private func clearPressed() {
        guard sessions.indices.contains(selected) else { return }
        let session = focusedSession ?? sessions[selected]
        session.view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        session.client?.send([0x0c])   // the shell redraws its prompt
    }

    /// The terminal that has the keyboard (the selected tab's main one or its split).
    private var focusedSession: Session? {
        guard sessions.indices.contains(selected) else { return nil }
        let responder = window?.firstResponder
        let current = sessions[selected]
        if let split = current.split, responder === split.view { return split }
        return current
    }

    // MARK: find

    @objc func showFind() {
        guard trusted else { return }
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
        findEntered()
    }

    @objc private func closeFind() {
        findBar.isHidden = true
        findMatches = []
        if let session = focusedSession ?? sessions.first { window?.makeFirstResponder(session.view) }
    }

    @objc private func findEntered() {
        guard let session = focusedSession else { return }
        let text = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
        findMatches = TerminalFind.matches(in: text, query: findField.stringValue)
        findIndex = max(0, findMatches.count - 1)   // start from the newest, at the bottom
        showFindMatch(in: session, totalLines: text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    @objc private func findNext() { stepFind(forward: true) }
    @objc private func findPrevious() { stepFind(forward: false) }

    private func stepFind(forward: Bool) {
        guard let session = focusedSession, !findMatches.isEmpty else { return }
        findIndex = TerminalFind.next(from: findIndex, count: findMatches.count, forward: forward)
        let text = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
        showFindMatch(in: session, totalLines: text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private func showFindMatch(in session: Session, totalLines: Int) {
        findLabel.stringValue = findField.stringValue.isEmpty ? "" : TerminalFind.label(index: findIndex, count: findMatches.count)
        guard findMatches.indices.contains(findIndex) else { return }
        let rows = session.view.getTerminal().rows
        guard totalLines > rows else { return }   // nothing to scroll
        session.view.scroll(toPosition: TerminalFind.scrollPosition(line: findMatches[findIndex].line, totalLines: totalLines, visibleLines: rows))
    }

    var findStatus: String { findLabel.stringValue }
    var isFindVisible: Bool { !findBar.isHidden }
    func search(_ text: String) { findField.stringValue = text; findEntered() }

    /// Keys that mean something only inside a terminal: ⌘\ split, ⌘K clear, ⌘F find, Esc to close the find bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let inTerminal = focusedSession.map { window?.firstResponder === $0.view } ?? false
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if inTerminal, flags == .command {
            switch event.charactersIgnoringModifiers {
            case "\\": splitSelected(); return true
            case "k": clearPressed(); return true
            case "f": showFind(); return true
            default: break
            }
        }
        if !findBar.isHidden, event.keyCode == 53, flags.isEmpty { closeFind(); return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: TerminalViewDelegate

    private func session(for view: TerminalView) -> Session? {
        for session in sessions {
            if session.view === view { return session }
            if let split = session.split, split.view === view { return split }
        }
        return nil
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session(for: source)?.client?.send(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session(for: source)?.client?.resize(columns: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { if AppPreferences.terminal.bell == .sound { NSSound.beep() } }
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
