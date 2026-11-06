import AppKit
import GobiClient
import GobiModel

/// The Install Version sheet of the ToolchainMenus mock: the Go releases that can be fetched, with Install for each one that is
/// not installed. Nothing is downloaded until the user presses Install.
final class InstallVersionSheet: NSWindowController {
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "Looking up releases…")
    private let progress = NSProgressIndicator()
    private(set) var rows: [GoInstallRow] = []
    private var installed: [GoInstall]
    private var busy = false
    var onInstalled: () -> Void = {}

    init(installed: [GoInstall]) {
        self.installed = installed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: "Install a Go version")
        heading.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let note = NSTextField(wrappingLabelWithString: "Downloads from go.dev into ~/sdk. Nothing is installed until you press Install.")
        note.textColor = .secondaryLabelColor
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        status.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(finish))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, done])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, note, list, NSView(), status, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        window.contentView = stack
        for view in [note, list, status, progress, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Asks gobid for the releases off the main thread.
    func load() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [String] in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.toolchainAvailable()
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let versions): self?.show(available: versions)
                case .failure(let error): self?.status.stringValue = "Cannot list releases: \(error)"
                }
            }
        }
    }

    func show(available: [String]) {
        rows = GoInstalls.installRows(available: available, installed: installed)
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            let name = NSTextField(labelWithString: "go" + row.version)
            name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            name.widthAnchor.constraint(equalToConstant: 100).isActive = true
            var views: [NSView] = [name]
            switch row.state {
            case .installed: views.append(NSTextField(labelWithString: "Installed"))
            case .latest, .available:
                if row.state == .latest { views.append(NSTextField(labelWithString: "Latest")) }
                let button = NSButton(title: "Install", target: self, action: #selector(installPressed(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(row.version)
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.isEnabled = !busy
                views.append(button)
            }
            let line = NSStackView(views: views)
            line.spacing = 12
            list.addArrangedSubview(line)
        }
        status.stringValue = rows.isEmpty ? "No releases found." : ""
    }

    @objc private func installPressed(_ sender: NSButton) {
        guard let version = sender.identifier?.rawValue else { return }
        install(version)
    }

    func install(_ version: String) {
        guard !busy else { return }
        busy = true
        progress.isHidden = false
        progress.startAnimation(nil)
        status.stringValue = "Installing go\(version)… this downloads about 70 MB"
        show(available: rows.map(\.version))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> Void in
                let client = try ControlClient.connect()
                defer { client.close() }
                try client.toolchainInstall(version)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                switch result {
                case .success:
                    self.installed = GoInstalls.merge(system: GoTool.system(), sdk: GoTool.sdkInstalls())
                    self.status.stringValue = "go\(version) is installed."
                    self.onInstalled()
                case .failure(let error): self.status.stringValue = "Could not install go\(version): \(error)"
                }
                self.show(available: self.rows.map(\.version))
            }
        }
    }

    /// True while this sheet is attached to its parent window.
    var isSheetOpen: Bool { window?.sheetParent != nil }

    @objc func finish() {
        guard let window, let parent = window.sheetParent else { window?.close(); return }
        parent.endSheet(window)
    }
}
