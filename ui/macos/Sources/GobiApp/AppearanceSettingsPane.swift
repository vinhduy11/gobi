import AppKit
import GobiEditor
import GobiModel

/// A round colour choice for the accent: filled with its colour, ringed when it is the one in use.
final class AccentSwatch: NSButton {
    let choice: AccentChoice?
    var isChosen = false { didSet { needsDisplay = true } }

    /// `choice` nil is the "custom" swatch, drawn as a colour wheel.
    init(choice: AccentChoice?, label: String, target: AnyObject, action: Selector) {
        self.choice = choice
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        setAccessibilityLabel(label)
        toolTip = label
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 5, dy: 5)
        if let choice {
            ThemeColors.color(choice.rgb).setFill()
            NSBezierPath(ovalIn: dot).fill()
        } else {
            NSGradient(colors: [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple])?.draw(in: NSBezierPath(ovalIn: dot), angle: 45)
        }
        guard isChosen else { return }
        NSColor.labelColor.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2
        ring.stroke()
    }
}

/// Settings > Appearance: the theme (with Sync with OS), the editor colour scheme, the accent colour and the tool window background.
final class AppearanceSettingsPane: SettingsPane, NSTextFieldDelegate {
    let themePopup = settingsPopup(AppTheme.allCases.map(\.title))
    let syncWithOS = settingsCheckbox("Sync with OS")
    let schemePopup = settingsPopup(["Theme default"] + AppTheme.allCases.map(\.title))
    let hexField = NSTextField()
    let toolBackground = settingsCheckbox("Different tool window background")
    private(set) var swatches: [AccentSwatch] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for popup in [themePopup, schemePopup] { popup.target = self; popup.action = #selector(changed) }
        syncWithOS.target = self
        syncWithOS.action = #selector(changed)
        toolBackground.target = self
        toolBackground.action = #selector(changed)
        swatches = AccentChoice.presets.map { AccentSwatch(choice: $0, label: $0.encoded.capitalized, target: self, action: #selector(swatchPressed(_:))) }
            + [AccentSwatch(choice: nil, label: "Custom colour", target: self, action: #selector(customPressed))]
        let swatchRow = NSStackView(views: swatches)
        swatchRow.spacing = 2
        hexField.placeholderString = "#rrggbb"
        hexField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        hexField.delegate = self
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        hexField.setAccessibilityLabel("Accent colour hex value")
        install([
            settingsRow("Theme", [themePopup, syncWithOS]),
            settingsRow("Editor color scheme", [schemePopup]),
            settingsRow("Accent colour", [swatchRow, hexField]),
            settingsRow("", [toolBackground]),
            settingsRow("", [narrow(settingsHint("Use lighter color in the dark theme and darker color in the light theme as a background."))]),
            settingsRow("", [narrow(settingsHint("With Sync with OS on, a theme of the other brightness is swapped for One Light or One Dark when macOS is in the other mode."))]),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A hint that wraps inside the pane instead of widening it.
    private func narrow(_ label: NSTextField) -> NSTextField {
        label.preferredMaxLayoutWidth = 430
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 430).isActive = true
        return label
    }

    override func sync() {
        let s = AppPreferences.theme
        themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: s.theme) ?? 0)
        syncWithOS.state = s.syncWithOS ? .on : .off
        schemePopup.selectItem(at: s.editorScheme.flatMap { AppTheme.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        toolBackground.state = s.differentToolWindowBackground ? .on : .off
        for swatch in swatches {
            if let choice = swatch.choice { swatch.isChosen = s.accent == choice } else if case .custom = s.accent { swatch.isChosen = true } else { swatch.isChosen = false }
        }
        hexField.stringValue = s.accent.rgb.hex
    }

    @objc private func changed() {
        AppPreferences.update(\.theme) { s in
            let chosen = AppTheme.allCases[max(0, themePopup.indexOfSelectedItem)]
            let pickedTheme = chosen != s.theme
            s.theme = chosen
            // Picking a theme by hand means "show this one", so Sync with OS goes off.
            s.syncWithOS = pickedTheme ? false : syncWithOS.state == .on
            let scheme = schemePopup.indexOfSelectedItem
            s.editorScheme = scheme > 0 ? AppTheme.allCases[scheme - 1] : nil
            s.differentToolWindowBackground = toolBackground.state == .on
        }
        sync()
    }

    @objc private func swatchPressed(_ sender: AccentSwatch) {
        guard let choice = sender.choice else { return }
        AppPreferences.update(\.theme) { $0.accent = choice }
        sync()
    }

    /// The colour-wheel swatch opens the system colour panel; each colour picked there becomes the accent.
    @objc private func customPressed() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = ThemeColors.accent
        panel.setTarget(self)
        panel.setAction(#selector(panelColourChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelColourChanged(_ panel: NSColorPanel) {
        guard let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        let color = RGB(byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        let choice = AccentChoice.presets.first { $0.rgb == color } ?? .custom(color)
        AppPreferences.update(\.theme) { $0.accent = choice }
        sync()
    }

    /// A valid hex value becomes the accent when Return is pressed or the field loses focus; anything else goes back to the current one.
    func controlTextDidEndEditing(_ notification: Notification) {
        if let color = RGB(hex: hexField.stringValue.trimmingCharacters(in: .whitespaces)) {
            let choice = AccentChoice.presets.first { $0.rgb == color } ?? .custom(color)
            AppPreferences.update(\.theme) { $0.accent = choice }
        }
        sync()
    }
}
