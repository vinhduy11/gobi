import AppKit
import GobiClient
import GobiModel

/// What the Generate popup was built from: the facts about the caret, core's items and gopls' fill struct when it offers one.
struct GenerateOffer {
    var request: GenerateRequest
    var items: [GenerateItem]
    var fillStruct: CodeAction?
    /// Why core gave no items (the buffer does not parse, ...); nil when it answered.
    var problem: String?
}

/// Generate… (⌃N): the popup at the caret, the dialog, and the insertion of what core renders as one undoable edit.
extension ProjectWindowController {
    /// Explorer > Generate ▸ entries: menu action id and core item id.
    static let folderGenerateItems: [(String, String)] = [
        ("generateHandler", "folder-http-handler"), ("generateConsumer", "folder-consumer"), ("generateRepository", "folder-repository"),
        ("generateConfig", "folder-config"), ("generateWorker", "folder-worker"),
    ]

    // MARK: calling core

    /// Runs `work` with a fresh control connection off the main thread and hands the outcome to the main thread.
    private func withControl<T>(_ work: @escaping (ControlClient) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { () -> T in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try work(client)
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// The `go` line of the nearest go.mod above the file, else the toolchain's version, else "" (unknown: core assumes the oldest).
    private func moduleGoVersion(of file: URL) -> String {
        var folder = file.deletingLastPathComponent()
        while folder.path.hasPrefix(root.path) {
            if let text = try? String(contentsOf: folder.appendingPathComponent("go.mod"), encoding: .utf8) { return GoModule.goDirective(in: text) ?? "" }
            if folder.path == root.path { break }
            folder.deleteLastPathComponent()
        }
        return goVersion.flatMap(GoModule.majorMinor(of:)) ?? ""
    }

    // MARK: the popup

    /// Generate… at the caret of the open Go file.
    func showGenerate() {
        guard let pane = currentPane, pane.editorFile.fileURL.pathExtension == "go", !pane.editorFile.isReadOnlyByLineLength else {
            showNote("Generate works in a Go file")
            NSSound.beep()
            return
        }
        loadGenerateOffer(in: pane) { [weak self] offer in
            guard let self, let offer else { return }
            if let problem = offer.problem { self.showNote("Generate: \(problem)") }
            guard self.presentsGenerateUI else { return }
            if offer.items.isEmpty && offer.fillStruct == nil {
                if offer.problem == nil { self.showNote("Nothing to generate here") }
                NSSound.beep()
                return
            }
            self.popUpGenerateMenu(offer, in: pane)
        }
    }

    /// Reads the symbols at the caret, asks core which items apply and gopls whether it can fill a struct. `completion` runs on
    /// the main thread, or gets nil when the buffer changed or a newer request started in the meantime.
    func loadGenerateOffer(in pane: EditorPane, completion: @escaping (GenerateOffer?) -> Void) {
        let file = pane.editorFile
        let version = file.version
        let ticket = generateGate.begin(version: version)
        let caret = file.lineIndex.position(at: pane.textView.selectedRange().location)
        let source = pane.textView.string
        let url = file.fileURL
        let build: ([DocumentSymbolInfo]) -> Void = { [weak self, weak pane] symbols in
            guard let self, let pane else { return }
            var request = GenerateContext.make(path: url.path, package: "", source: source, caret: caret, symbols: symbols, version: UInt64(version), goVersion: self.moduleGoVersion(of: url))
            request.package = GenerateContext.packageClause(in: source) ?? NewEntry.packageName(folder: url.deletingLastPathComponent().lastPathComponent, sibling: self.packageOfGoFiles(in: url.deletingLastPathComponent(), among: (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []))
            let group = DispatchGroup()
            var list: Result<GenerateList, Error> = .success(GenerateList(version: 0, items: []))
            var fill: CodeAction?
            group.enter()
            self.withControl({ try $0.generateList(request) }) { list = $0; group.leave() }
            if let client = file.client {
                group.enter()
                client.codeActions(uri: file.uri, from: caret, to: caret, kinds: ["refactor.rewrite.fillStruct"]) { actions in
                    DispatchQueue.main.async { fill = actions.first; group.leave() }
                }
            }
            group.notify(queue: .main) { [weak self, weak pane] in
                guard let self, let pane, self.generateGate.accepts(ticket, version: pane.editorFile.version) else { completion(nil); return }
                switch list {
                case .success(let answer) where answer.version == UInt64(version):
                    completion(GenerateOffer(request: request, items: answer.items, fillStruct: fill, problem: nil))
                case .success:
                    completion(nil)   // an answer for another version of the buffer
                case .failure(let error):
                    completion(GenerateOffer(request: request, items: [], fillStruct: fill, problem: "\(error)"))
                }
            }
        }
        if let client = file.client { client.documentSymbolInfos(uri: file.uri, version: version) { symbols in DispatchQueue.main.async { build(symbols) } } } else { build([]) }
    }

    private func popUpGenerateMenu(_ offer: GenerateOffer, in pane: EditorPane) {
        let menu = NSMenu(title: "Generate")
        menu.autoenablesItems = false
        fill(menu, with: GeneratePopup.entries(from: offer.items, fillStruct: offer.fillStruct != nil), offer: offer, pane: pane)
        let textView = pane.textView
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualRange: nil)
        guard let window = textView.window else { return }
        let point = textView.convert(window.convertFromScreen(NSRect(origin: screenRect.origin, size: .zero)).origin, from: nil)
        menu.popUp(positioning: nil, at: point, in: textView)
    }

    /// The popup as an NSMenu; the self-test reads the same menu.
    func generateMenu(for offer: GenerateOffer, in pane: EditorPane) -> NSMenu {
        let menu = NSMenu(title: "Generate")
        menu.autoenablesItems = false
        fill(menu, with: GeneratePopup.entries(from: offer.items, fillStruct: offer.fillStruct != nil), offer: offer, pane: pane)
        return menu
    }

    private func fill(_ menu: NSMenu, with entries: [GeneratePopupEntry], offer: GenerateOffer, pane: EditorPane) {
        for entry in entries {
            switch entry {
            case .heading(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                MenuIconImage.set(GenerateIcons.patterns, on: item)
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                fill(submenu, with: children, offer: offer, pane: pane)
                item.submenu = submenu
                menu.addItem(item)
            case .fillStruct:
                let item = NSMenuItem(title: GeneratePopup.fillStructTitle, action: nil, keyEquivalent: "")
                MenuIconImage.set(GenerateIcons.fillStruct, on: item)
                bind(item) { [weak self, weak pane] in
                    guard let self, let action = offer.fillStruct, pane != nil else { return }
                    self.perform(action, named: GeneratePopup.fillStructTitle)
                }
                menu.addItem(item)
            case .item(let generateItem):
                let item = NSMenuItem(title: generateItem.title, action: nil, keyEquivalent: "")
                if generateItem.group.isEmpty, !generateItem.detail.isEmpty {
                    let text = NSMutableAttributedString(string: generateItem.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    text.append(NSAttributedString(string: "  " + generateItem.detail, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = text
                }
                MenuIconImage.set(GenerateIcons.symbol(forItem: generateItem.id, group: generateItem.group), on: item)
                bind(item) { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    self.chooseGenerate(generateItem, offer: offer, in: pane)
                }
                menu.addItem(item)
            }
        }
    }

    private func bind(_ item: NSMenuItem, _ run: @escaping () -> Void) {
        let behaviour = MenuAction(run)
        item.action = #selector(MenuAction.fire(_:))
        item.target = behaviour
        item.representedObject = behaviour
    }

    // MARK: choosing, the dialog

    private func needsDialog(_ item: GenerateItem, fieldCount: Int) -> Bool {
        item.needsName || !item.params.isEmpty || (item.needsFields && fieldCount > 1 && item.title.hasSuffix("…"))
    }

    func chooseGenerate(_ item: GenerateItem, offer: GenerateOffer, in pane: EditorPane) {
        let form = GenerateForm(item: item, fieldNames: item.needsFields ? offer.request.fields.map(\.name) : [])
        if needsDialog(item, fieldCount: form.fieldNames.count) && presentsGenerateUI {
            presentGenerateSheet(form: form, base: offer.request, pane: pane, folder: nil)
        } else {
            insertGenerated(form, base: offer.request, in: pane)
        }
    }

    private func presentGenerateSheet(form: GenerateForm, base: GenerateRequest, pane: EditorPane?, folder: URL?) {
        guard let window else { return }
        let sheet = GenerateSheet(form: form, offersNewFile: folder == nil && !form.item.group.isEmpty)
        sheet.requestPreview = { [weak self, weak pane] form, show in
            guard let self else { return }
            self.previewGenerated(form, base: base, in: pane, show: show)
        }
        sheet.onFinish = { [weak self, weak pane] form in
            guard let self, let form else { return }
            self.insertGenerated(form, base: base, in: pane, folder: folder)
        }
        sheet.present(on: window)
    }

    /// The text the dialog shows. A reply is dropped when a newer preview was asked for or the buffer changed.
    func previewGenerated(_ form: GenerateForm, base: GenerateRequest, in pane: EditorPane?, show: @escaping (Result<String, Error>) -> Void) {
        var request = base
        form.apply(to: &request)
        let ticket = generatePreviewGate.begin(version: pane?.editorFile.version ?? 0)
        withControl({ try $0.generatePreview(request) }) { [weak self, weak pane] outcome in
            guard let self, self.generatePreviewGate.accepts(ticket, version: pane?.editorFile.version ?? 0) else { return }
            show(outcome.map(\.text))
        }
    }

    // MARK: inserting

    /// Renders the item and applies it: the edits of the open file as one undo step, new files created and opened. `completion`
    /// gets true when something was applied.
    func insertGenerated(_ form: GenerateForm, base: GenerateRequest, in pane: EditorPane?, folder: URL? = nil, completion: ((Bool) -> Void)? = nil) {
        var request = base
        form.apply(to: &request)
        if let pane, pane.editorFile.version != Int(request.version) {
            showNote("Generate: the file changed, open Generate again")
            completion?(false)
            return
        }
        let ticket = generateGate.begin(version: pane?.editorFile.version ?? 0)
        let title = form.item.title.hasSuffix("…") ? String(form.item.title.dropLast()) : form.item.title
        withControl({ try $0.generateRender(request) }) { [weak self, weak pane] outcome in
            guard let self else { return }
            if pane != nil, !self.generateGate.accepts(ticket, version: pane?.editorFile.version ?? 0) {
                self.showNote("Generate: the file changed, nothing was inserted")
                completion?(false)
                return
            }
            switch outcome {
            case .success(let result):
                let applied = self.applyGenerated(result, title: title, in: pane)   // not inside the optional call: it would be skipped without a completion
                completion?(applied)
            case .failure(let error):
                self.showNote("Generate: \(error)")
                NSSound.beep()
                completion?(false)
            }
        }
    }

    /// Applies a render result. Returns false, changing nothing, when the buffer is no longer the one it was rendered for.
    @discardableResult
    func applyGenerated(_ result: GenerateResult, title: String, in pane: EditorPane?) -> Bool {
        if let pane {
            guard pane.editorFile.version == Int(result.version) else {
                showNote("Generate: the file changed, nothing was inserted")
                return false
            }
            if !result.edits.isEmpty {
                let before = pane.textView.string
                let caret = GenerateInsertion.caret(of: result.text, edits: result.edits, in: before)
                pane.apply(result.edits, named: "Generate \(title)")
                if let caret { pane.reveal(line: caret.line, character: caret.character) }
            }
        }
        var created: URL?
        for file in result.files { created = createGeneratedFile(file) ?? created }
        if let created { openFile(created) }
        return !result.edits.isEmpty || created != nil
    }

    /// Writes a file core rendered, inside the project and never over an existing one, then shows it in the Explorer.
    private func createGeneratedFile(_ file: GenerateFile) -> URL? {
        let url = URL(fileURLWithPath: file.path)
        let folder = url.deletingLastPathComponent()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard contains(url) else { showNote("Generate: \(url.lastPathComponent) is outside the project"); return nil }
        if let problem = NewEntry.problem(with: url.lastPathComponent, existing: existing) {
            showNote("Generate: " + Self.describe(problem, name: url.lastPathComponent))
            return nil
        }
        do { try file.content.write(to: url, atomically: true, encoding: .utf8) } catch {
            showNote("Generate: \(error.localizedDescription)")
            return nil
        }
        reloadExplorer()
        return url
    }

    // MARK: Explorer: Generate ▸ on a folder

    /// Generate ▸ HTTP Handler… and the others, in `folder`: the dialog, then a new Go file.
    func generateInFolder(_ folder: URL, itemID: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var base = GenerateRequest()
        base.path = folder.path
        base.kind = "folder"
        base.package = NewEntry.packageName(folder: folder.lastPathComponent, sibling: packageOfGoFiles(in: folder, among: names))
        base.goVersion = moduleGoVersion(of: folder.appendingPathComponent("x.go"))
        base.target = "file"
        withControl({ try $0.generateList(base) }) { [weak self] outcome in
            guard let self else { return }
            let list: GenerateList
            switch outcome {
            case .success(let answer): list = answer
            case .failure(let error):
                self.showNote("Generate: \(error)")
                return
            }
            guard let item = list.items.first(where: { $0.id == itemID }) else {
                self.showNote("Generate: this item is not available here")
                return
            }
            var form = GenerateForm(item: item, fieldNames: [])
            form.target = .file
            if self.presentsGenerateUI { self.presentGenerateSheet(form: form, base: base, pane: nil, folder: folder) } else { self.insertGenerated(form, base: base, in: nil, folder: folder) }
        }
    }
}
