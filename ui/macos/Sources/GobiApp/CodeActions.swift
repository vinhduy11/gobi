import AppKit
import GobiClient
import GobiModel

/// Find References, Rename, Organize Imports and Code Actions: questions to gopls and the edits that come back, applied to the
/// open tabs and to files on disk.
extension ProjectWindowController {
    private var caretPosition: LSPPosition? {
        guard let pane = currentPane else { return nil }
        return pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location)
    }

    /// Where on screen a menu for the caret should appear: just below the caret, in the text view's coordinates.
    private func caretPointInTextView(_ pane: EditorPane) -> NSPoint {
        let textView = pane.textView
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualRange: nil)
        guard let window = textView.window else { return .zero }
        let windowPoint = window.convertFromScreen(NSRect(origin: screenRect.origin, size: .zero)).origin
        return textView.convert(NSPoint(x: windowPoint.x, y: windowPoint.y), from: nil)
    }

    // MARK: references

    /// Find References (⇧F12): gopls lists the uses; one is opened at once, several fill the Usages tab.
    func findReferences() { startUsages(alwaysPanel: false) }

    /// Find Usages (⌥F7): the Usages tab, even for a single hit.
    func findUsages() { startUsages(alwaysPanel: true) }

    private func startUsages(alwaysPanel: Bool) {
        guard let pane = currentPane, let client = pane.editorFile.client, let position = caretPosition else { NSSound.beep(); return }
        usages.start(uri: pane.editorFile.uri, position: position, symbol: wordAtCaret(pane), client: client, alwaysPanel: alwaysPanel)
    }

    private func wordAtCaret(_ pane: EditorPane) -> String {
        let text = Array(pane.textView.string.utf16), caret = pane.textView.selectedRange().location
        let word = CompletionPrefix.current(before: text, caret: caret)
        let tail = text.dropFirst(caret).prefix { c in (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        return word.text + String(decoding: Array(tail), as: UTF16.self)
    }

    /// Go to Implementation (⌘F12): the types that implement the interface (or the methods that implement its method) at the caret.
    func goToImplementation() {
        guard let pane = currentPane, let client = pane.editorFile.client, let position = caretPosition else { NSSound.beep(); return }
        let ticket = locationGate.begin(version: pane.editorFile.version)
        client.implementation(uri: pane.editorFile.uri, at: position) { [weak self] locations in
            DispatchQueue.main.async {
                guard let self, self.locationGate.accepts(ticket, version: pane.editorFile.version) else { return }
                let inProject = locations.filter { URL(string: $0.uri)?.isFileURL == true }
                self.lastListedLocations = inProject.count
                if inProject.isEmpty { self.showNote("No implementations found"); NSSound.beep(); return }
                if inProject.count == 1 { self.open(location: inProject[0]); return }
                if self.presentsLocationMenus { self.offer(locations: inProject, from: pane) }
            }
        }
    }

    /// A click on a code lens: the caret goes to the declared name, then the same flow as the menu item runs.
    func lensClicked(_ action: LensAction, _ declaration: LensDeclaration, in pane: EditorPane) {
        lastLensAction = action
        switch action {
        case .references, .implementations:
            pane.reveal(line: declaration.position.line, character: declaration.position.character)
            if action == .references { findReferences() } else { goToImplementation() }
        case .runTest:
            runTest(in: pane, line: declaration.position.line)
        }
    }

    func open(location: SourceLocation) {
        guard let url = URL(string: location.uri), url.isFileURL else { return }
        openFile(url)
        currentPane?.reveal(line: location.start.line, character: location.start.character)
    }

    private func offer(locations: [SourceLocation], from pane: EditorPane) {
        let menu = NSMenu(title: "References")
        menu.autoenablesItems = false
        for location in locations.prefix(40) {
            guard let url = URL(string: location.uri) else { continue }
            let relative = StatusBar.relativePath(projectRoot: root.path, file: url.path)
            let line = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false)[safe: location.start.line].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let item = NSMenuItem(title: "\(relative):\(location.start.line + 1)   \(line.prefix(80))", action: #selector(chooseLocation(_:)), keyEquivalent: "")
            MenuIconImage.set("doc.text", on: item)
            item.target = self
            item.representedObject = LocationBox(location)
            menu.addItem(item)
        }
        if locations.count > 40 { menu.addItem(withTitle: "… and \(locations.count - 40) more", action: nil, keyEquivalent: "").isEnabled = false }
        menu.popUp(positioning: nil, at: caretPointInTextView(pane), in: pane.textView)
    }

    @objc private func chooseLocation(_ item: NSMenuItem) {
        if let box = item.representedObject as? LocationBox { open(location: box.location) }
    }

    // MARK: rename

    /// Rename Symbol… (F2): asks for the new name and applies gopls' edits in every file they touch.
    func renameSymbol() {
        guard let pane = currentPane, pane.editorFile.client != nil, caretPosition != nil else { NSSound.beep(); return }
        let text = pane.textView.string.utf16
        let word = CompletionPrefix.current(before: Array(text), caret: pane.textView.selectedRange().location)
        let tail = Array(text).dropFirst(pane.textView.selectedRange().location).prefix { c in (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        let current = word.text + String(decoding: Array(tail), as: UTF16.self)
        guard !current.isEmpty, let name = askNewName(current: current) else { return }
        performRename(from: current, to: name)
    }

    /// The rename itself, after the name was asked for (the self-test calls it directly).
    func performRename(from current: String, to name: String) {
        guard let pane = currentPane, let client = pane.editorFile.client, let position = caretPosition else { return }
        client.rename(uri: pane.editorFile.uri, at: position, to: name) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let edits):
                    let files = self.applyWorkspaceEdit(edits, named: "Rename")
                    self.showNote(files == 0 ? "Nothing to rename" : "Renamed \(current) to \(name) in \(files) file\(files == 1 ? "" : "s")")
                case .failure(let error):
                    self.showNote("Cannot rename: \(error.message)")
                    NSSound.beep()
                }
            }
        }
    }

    private func askNewName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename “\(current)”"
        alert.informativeText = "Every use of the symbol in the project is renamed."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return ProjectForm.isGoIdentifier(name) && name != current ? name : nil
    }

    // MARK: organize imports and code actions

    /// Organize Imports (⌃⌥O): gopls adds the imports that are missing and removes the unused ones.
    func organizeImports() {
        guard let pane = currentPane, let client = pane.editorFile.client else { NSSound.beep(); return }
        let last = pane.editorFile.lineIndex.lineCount - 1
        client.codeActions(uri: pane.editorFile.uri, from: LSPPosition(line: 0, character: 0), to: LSPPosition(line: last, character: 0), kinds: ["source.organizeImports"]) { [weak self] actions in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let action = actions.first else { self.showNote("Imports are already in order"); return }
                self.perform(action, named: "Organize Imports")
            }
        }
    }

    /// Parameter Info (⇧⌘Space): the signature of the call around the caret.
    func showParameterInfo() { currentPane?.editor.signature?.trigger() }

    /// Code Actions… (⌘.): the fixes and refactorings gopls offers at the caret, in a menu.
    func showCodeActions() {
        guard let pane = currentPane, let client = pane.editorFile.client, let position = caretPosition else { NSSound.beep(); return }
        client.codeActions(uri: pane.editorFile.uri, from: position, to: position, kinds: []) { [weak self] actions in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !actions.isEmpty else { self.showNote("No code actions here"); NSSound.beep(); return }
                let menu = NSMenu(title: "Code Actions")
                menu.autoenablesItems = false
                for action in actions.prefix(30) {
                    let item = NSMenuItem(title: action.title, action: #selector(self.chooseAction(_:)), keyEquivalent: "")
                    MenuIconImage.set("lightbulb", on: item)
                    item.target = self
                    item.representedObject = ActionBox(action)
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: self.caretPointInTextView(pane), in: pane.textView)
            }
        }
    }

    @objc private func chooseAction(_ item: NSMenuItem) {
        guard let box = item.representedObject as? ActionBox else { return }
        perform(box.action, named: box.action.title)
    }

    /// Applies a code action. gopls sends some without their edit; those are resolved first (`codeAction/resolve`).
    func perform(_ action: CodeAction, named name: String) {
        guard let client = currentPane?.editorFile.client else { return }
        client.resolve(action) { [weak self] resolved in
            DispatchQueue.main.async {
                guard let self else { return }
                if resolved.edits.isEmpty { self.showNote("\(name): no changes"); return }
                _ = self.applyWorkspaceEdit(resolved.edits, named: name)
            }
        }
    }

    // MARK: applying edits

    /// Applies edits by file URI: to the open tab when there is one (one undo step), else to the file on disk. Only files inside
    /// the project are touched. Returns how many files changed.
    @discardableResult
    func applyWorkspaceEdit(_ edits: [String: [TextEdit]], named name: String) -> Int {
        var changed = 0
        for (uri, fileEdits) in edits {
            guard let url = URL(string: uri), url.isFileURL, contains(url) || url.path == root.path, !fileEdits.isEmpty else { continue }
            if let pane = paneIfOpen(url) {
                pane.apply(fileEdits, named: name)
                changed += 1
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let units = Array(text.utf16)
                let result = TextEdits.apply(fileEdits, to: units, lineIndex: LineIndex(utf16: units))
                if (try? String(decoding: result, as: UTF16.self).write(to: url, atomically: true, encoding: .utf8)) != nil { changed += 1 }
            }
        }
        return changed
    }
}

private final class LocationBox: NSObject {
    let location: SourceLocation
    init(_ location: SourceLocation) { self.location = location }
}

private final class ActionBox: NSObject {
    let action: CodeAction
    init(_ action: CodeAction) { self.action = action }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
