import AppKit
import GobiClient
import GobiModel
import GobiEditor

/// The editor, a problems list and a status line for one file; a window or a project tab hosts it.
final class EditorPane: NSViewController {
    private var window: NSWindow? { viewIfLoaded?.window }
    let editor: EditorView
    /// Whether the user trusted the project; untrusted projects run gopls restricted.
    var trusted = false
    /// The Go installation gopls runs with (a folder with bin/go); empty uses the go on PATH.
    var goRoot = ""
    var editorFile: EditorDocument { editor.document }
    var textView: NSTextView { editor.textView }
    private let problemsView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private var diagnosticCount: Int?
    private var diagnosticsSeenAt: Date?
    private let createdAt = Date()
    private var connectedAt: Date?
    private var firstDiagnosticsAt: Date?
    private var underlineMilliseconds = 0.0

    /// Called with the diagnostics gopls sent for this file, and with each status text (a project window shows them in its
    /// own bottom panel and status bar instead of the ones built into the pane).
    var onDiagnostics: (([LSPDiagnostic]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    /// Called when the caret moves, with a zero-based line and column.
    var onCaret: ((Int, Int) -> Void)?
    private(set) var isConnected = false
    /// The code lens above declarations (references, implementations, run test).
    private(set) var lens: CodeLensFeed!
    private(set) var semanticTokens: SemanticTokensFeed!
    private var selectionObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var appPreferencesObserver: NSObjectProtocol?
    private var appliedAdvanced = AppPreferences.advanced
    private var lastStatus = ""
    var statusText: String { statusLabel.stringValue }
    private var textObserver: NSObjectProtocol?
    private var runTextObserver: NSObjectProtocol?
    private var previewTimer: Timer?
    /// The Source | Split | Preview switch, for a Markdown file in a project window.
    private(set) var markdownHost: MarkdownHostView?
    var onPreviewModeChanged: ((MarkdownPreviewMode) -> Void)?

    /// With `embedsPanels` false the pane is just the editor; the host window draws problems and status itself.
    init(fileURL: URL, text: String, embedsPanels: Bool = true) {
        editor = EditorView(fileURL: fileURL, text: text, settings: EditorPreferences.current, lineLimit: AppPreferences.advanced.lineLimit)
        super.init(nibName: nil, bundle: nil)
        editor.apply(EditorPreferences.current)
        appPreferencesObserver = NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyAdvancedChanges()
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.editor.apply(EditorPreferences.current)
        }

        let problemsScroll = NSScrollView()
        problemsScroll.hasVerticalScroller = true
        problemsScroll.documentView = problemsView
        problemsView.isEditable = false
        problemsView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        problemsView.textContainerInset = NSSize(width: 6, height: 6)
        problemsScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [statusLabel])
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let stack = NSStackView(views: [editor.view, problemsScroll, statusRow])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        stack.distribution = .fill
        // The view is set once: a Markdown file's editor goes inside its Source | Split | Preview host first, because swapping a
        // controller's view afterwards leaves the old one in the responder chain.
        var markdown: MarkdownHostView?
        if !embedsPanels, editor.document.language == "markdown" {
            let host = MarkdownHostView(editorView: editor.view, mode: WindowSettings.markdownPreviewMode)
            host.onModeChanged = { [weak self] mode in
                WindowSettings.markdownPreviewMode = mode
                self?.onPreviewModeChanged?(mode)
                if mode.showsPreview { self?.refreshPreview() }
            }
            markdownHost = host
            markdown = host
            textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
                self?.previewTimer?.invalidate()
                self?.previewTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in self?.refreshPreview() }
            }
        }
        view = embedsPanels ? stack : (markdown ?? editor.view)
        editor.completion?.provider = { [weak self] position, done in
            guard let self, let client = self.editorFile.client, !self.editorFile.isReadOnlyByLineLength else { done([]); return }
            client.completion(uri: self.editorFile.uri, at: position) { items in DispatchQueue.main.async { done(items) } }
        }
        editor.signature?.provider = { [weak self] position, done in
            guard let self, let client = self.editorFile.client, !self.editorFile.isReadOnlyByLineLength else { done(nil); return }
            client.signatureHelp(uri: self.editorFile.uri, at: position) { text in DispatchQueue.main.async { done(text) } }
        }
        editor.hover?.provider = { [weak self] position, done in
            guard let self, let client = self.editorFile.client else { done(nil); return }
            let version = self.editorFile.version
            client.hover(uri: self.editorFile.uri, at: position) { text in DispatchQueue.main.async { done(self.editorFile.version == version ? text : nil) } }
        }
        lens = CodeLensFeed(pane: self)
        semanticTokens = SemanticTokensFeed(pane: self)
        refreshRunButtons()
        runTextObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in self?.scheduleRunButtons() }
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor.textView, queue: .main) { [weak self] _ in
            guard let self else { return }
            let position = self.editorFile.lineIndex.position(at: self.textView.selectedRange().location)
            self.onCaret?(position.line, position.character)
        }
    }

    deinit { selectionObserver.map(NotificationCenter.default.removeObserver) }

    /// Asks gopls where the symbol at the caret is defined; `found` runs on the main thread with the first answer.
    func goToDefinition(found: @escaping (SourceLocation?) -> Void) {
        guard let client = editorFile.client else { found(nil); return }
        let position = editorFile.lineIndex.position(at: textView.selectedRange().location)
        client.definition(uri: editorFile.uri, at: position) { locations in DispatchQueue.main.async { found(locations.first) } }
    }

    /// Formats the file with gopls (gofmt). The edits apply as one undo step, and only if the text has not changed since asking.
    func formatDocument() {
        guard let client = editorFile.client, !editorFile.isReadOnlyByLineLength else { return }
        let version = editorFile.version
        client.formatting(uri: editorFile.uri, tabSize: editorFile.language == "json" ? 2 : 4, insertSpaces: editorFile.language == "json") { [weak self] edits in
            DispatchQueue.main.async {
                guard let self, !edits.isEmpty, self.editorFile.version == version else { return }
                self.apply(edits, named: "Format Document")
            }
        }
    }

    /// Applies gopls' edits to the text view from the last to the first, as one undo step.
    func apply(_ edits: [TextEdit], named name: String) {
        guard let storage = textView.textStorage else { return }
        let index = editorFile.lineIndex
        let located = edits.map { edit -> (NSRange, String) in
            let start = index.offset(of: edit.start)
            return (NSRange(location: start, length: max(0, index.offset(of: edit.end) - start)), edit.newText)
        }.sorted { $0.0.location > $1.0.location }
        textView.undoManager?.beginUndoGrouping()
        textView.undoManager?.setActionName(name)
        for (range, text) in located where textView.shouldChangeText(in: range, replacementString: text) {
            storage.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
        textView.undoManager?.endUndoGrouping()
    }

    /// Puts the caret on a zero-based line and column without taking focus (a tab that is not shown yet).
    func placeCaret(line: Int, character: Int) {
        let offset = editorFile.lineIndex.offset(of: LSPPosition(line: line, character: character))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }

    /// Moves the caret to a zero-based line and column and brings it into view.
    func reveal(line: Int, character: Int) {
        let offset = editorFile.lineIndex.offset(of: LSPPosition(line: line, character: character))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        editor.settleHorizontalScrollAfterReveal()
        textView.window?.makeFirstResponder(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Writes the text to the file as UTF-8. Returns false (and says why in the status line) when it cannot.
    ///
    /// `automatic` (auto save, save on focus loss) never overwrites a file that changed or went on disk since it was read, or one
    /// whose conflict notice is still open: it returns false and lets the notice appear. ⌘S, Save All and closing a tab are explicit
    /// and write whatever the answer to "Keep Mine" was.
    @discardableResult
    func save(automatic: Bool = false) -> Bool {
        if automatic {
            let url = editorFile.fileURL
            let state = DiskCheck.state(known: diskSignature, current: Self.signature(of: url), digest: { Self.contentDigest(of: url) })
            guard SaveGuard.allowed(dirty: editorFile.isEdited, state: state, userInitiated: false, conflictPending: diskNotified) else {
                if state != .same { checkDisk() }
                return false
            }
        }
        applySaveTransform()
        do {
            try textView.string.write(to: editorFile.fileURL, atomically: true, encoding: .utf8)
            editorFile.isEdited = false
            diskSignature = Self.signature(of: editorFile.fileURL, digestOf: textView.string)
            hideDiskNotice()
            formatAfterSave()
            return true
        } catch {
            setStatus("Cannot save \(editorFile.fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Trailing whitespace and the final newline, per Settings. Replaces the text only when it changes, keeping the caret's place.
    private func applySaveTransform() {
        guard !editorFile.isReadOnlyByLineLength, WindowSettings.trimTrailingWhitespace || WindowSettings.finalNewline else { return }
        let current = textView.string
        let changed = SaveTransform.apply(current, trimTrailingWhitespace: WindowSettings.trimTrailingWhitespace, finalNewline: WindowSettings.finalNewline)
        guard changed != current else { return }
        let caret = textView.selectedRange().location
        let whole = NSRange(location: 0, length: (current as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: changed) else { return }
        textView.undoManager?.beginUndoGrouping()
        textView.undoManager?.setActionName("Clean Up on Save")
        textView.textStorage?.replaceCharacters(in: whole, with: changed)
        textView.didChangeText()
        textView.undoManager?.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: min(caret, (changed as NSString).length), length: 0))
    }

    /// Format on save: the file is written first (so a slow or absent gopls never blocks saving), then gofmt's edits are applied
    /// and the file written again. Skipped for non-Go files and when the switch in the inspector is off.
    private func formatAfterSave() {
        let language = editorFile.language
        let enabled = language == "go" ? WindowSettings.formatOnSave : (language == "json" ? WindowSettings.formatJSONOnSave : false)
        guard enabled, let client = editorFile.client, !editorFile.isReadOnlyByLineLength else { return }
        let version = editorFile.version
        client.formatting(uri: editorFile.uri, tabSize: editorFile.language == "json" ? 2 : 4, insertSpaces: editorFile.language == "json") { [weak self] edits in
            DispatchQueue.main.async {
                guard let self, !edits.isEmpty, self.editorFile.version == version else { return }
                self.apply(edits, named: "Format on Save")
                try? self.textView.string.write(to: self.editorFile.fileURL, atomically: true, encoding: .utf8)
                self.editorFile.isEdited = false
                self.diskSignature = Self.signature(of: self.editorFile.fileURL, digestOf: self.textView.string)
            }
        }
    }

    // MARK: run buttons

    private var runLinesTimer: Timer?

    /// Puts a Run button in the gutter on each test function of a _test.go file; recomputed shortly after typing stops.
    func refreshRunButtons() {
        guard editorFile.fileURL.lastPathComponent.hasSuffix("_test.go") else { return }
        editor.runnableLines = Set(TestAtCursor.signatureLines(in: textView.string))
    }

    private func scheduleRunButtons() {
        guard editorFile.fileURL.lastPathComponent.hasSuffix("_test.go") else { return }
        runLinesTimer?.invalidate()
        runLinesTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.refreshRunButtons() }
    }

    // MARK: changes on disk

    /// What the file looked like when this pane last read or wrote it.
    private(set) var diskSignature: FileSignature?
    private var diskNotified = false

    /// The file's modification time, size and inode; `digestOf` adds the digest of the text that was read or written.
    static func signature(of url: URL, digestOf text: String? = nil) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return FileSignature(modified: modified, size: (attributes[.size] as? Int) ?? 0, identity: identity, digest: text.map(FileDigest.of))
    }

    /// Digest of the file's text as the editor reads it (UTF-8); nil when it cannot be read. Reads the whole file: ask only for open files.
    static func contentDigest(of url: URL) -> UInt64? {
        (try? String(contentsOf: url, encoding: .utf8)).map(FileDigest.of)
    }

    /// Remembers the file as it is now (with the digest of its text); call after the first load.
    func markDiskKnown() {
        diskSignature = Self.signature(of: editorFile.fileURL, digestOf: try? String(contentsOf: editorFile.fileURL, encoding: .utf8))
        diskNotified = false
    }

    /// Compares the file with what was read: a clean buffer reloads quietly, an edited one or a deleted file asks.
    /// Returns what it did.
    @discardableResult
    /// `verifyContent` also compares the content digest when the metadata is equal (after a file-system event); the slow poll leaves it off.
    func checkDisk(verifyContent: Bool = true) -> DiskAction {
        let current = Self.signature(of: editorFile.fileURL)
        let url = editorFile.fileURL
        let state = DiskCheck.state(known: diskSignature, current: current, digest: verifyContent ? { Self.contentDigest(of: url) } : nil)
        let action = DiskCheck.action(dirty: editorFile.isEdited, state: state, notified: diskNotified)
        let name = editorFile.fileURL.lastPathComponent
        switch action {
        case .none: break
        case .reload:
            reloadFromDisk()
        case .conflict:
            diskNotified = true
            editor.showNotice("\(name) changed on disk and you have unsaved edits.", style: .warning, actions: [
                NoticeAction(title: "Reload from Disk") { [weak self] in self?.reloadFromDisk() },
                NoticeAction(title: "Keep Mine") { [weak self] in self?.keepMine() },
            ])
        case .deleted:
            diskNotified = true
            editor.showNotice("\(name) was deleted on disk.", style: .error, actions: [
                NoticeAction(title: "Close Tab") { [weak self] in self?.onDeletedClose?() },
                NoticeAction(title: "Keep Open") { [weak self] in self?.keepMine() },
            ])
        }
        return action
    }

    /// Called when the person chooses Close Tab on the "deleted" notice.
    var onDeletedClose: (() -> Void)?
    /// Called after a quiet reload so the host can say "updated from disk".
    var onReloaded: (() -> Void)?

    /// Replaces the text with the file's, keeping the caret near where it was.
    func reloadFromDisk() {
        guard let text = try? String(contentsOf: editorFile.fileURL, encoding: .utf8), let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        if text != textView.string, textView.shouldChangeText(in: whole, replacementString: text) {
            storage.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        }
        editorFile.isEdited = false
        markDiskKnown()
        hideDiskNotice()
        onReloaded?()
    }

    /// Puts kept unsaved text back, marked as edited, with the notice bar saying so. The buffer file goes away when the edit mark
    /// clears (saved, reloaded or discarded).
    func restoreUnsaved(_ text: String, changedOnDisk: Bool, quiet: Bool = false) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: whole, replacementString: text) {
            storage.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
        }
        editorFile.isEdited = true
        markDiskKnown()
        let name = editorFile.fileURL.lastPathComponent
        if quiet { return }
        if changedOnDisk {
            diskNotified = true   // an automatic save waits for the answer
            editor.showNotice("Restored unsaved changes to \(name), but it changed on disk since.", style: .warning, actions: [
                NoticeAction(title: "Keep Mine") { [weak self] in self?.hideDiskNotice() },
                NoticeAction(title: "Reload from Disk") { [weak self] in self?.reloadFromDisk() },
            ])
        } else {
            editor.showNotice("Restored unsaved changes to \(name).", style: .info, actions: [
                NoticeAction(title: "Keep") { [weak self] in self?.hideDiskNotice() },
                NoticeAction(title: "Discard") { [weak self] in self?.reloadFromDisk() },
            ])
        }
    }

    /// Keeps the buffer; the next save overwrites the file. The state is remembered so the notice does not come back.
    private func keepMine() {
        diskSignature = Self.signature(of: editorFile.fileURL, digestOf: try? String(contentsOf: editorFile.fileURL, encoding: .utf8))
        hideDiskNotice()
    }

    private func hideDiskNotice() { diskNotified = false; editor.hideNotice() }

    // MARK: Markdown preview

    var previewMode: MarkdownPreviewMode { markdownHost?.mode ?? .source }

    /// Asks gobid's Markdown service for the HTML of the text it has and shows it.
    func refreshPreview() {
        guard let host = markdownHost, host.mode.showsPreview, let client = editorFile.client else { return }
        client.request("gobi/markdownPreview", params: ["textDocument": ["uri": editorFile.uri]]) { [weak host] result in
            guard case .success(let value) = result, let html = (value as? [String: Any])?["html"] as? String else { return }
            DispatchQueue.main.async { host?.preview.show(html: html) }
        }
    }

    // MARK: server connection

    /// Settings > Advanced applies to the open file at once: a new large-file limit re-judges the text (read-only past it, editable
    /// again under it), a new gopls path reconnects Go files so gobid serves them with that program.
    func applyAdvancedChanges() {
        let now = AppPreferences.advanced
        let before = appliedAdvanced
        appliedAdvanced = now
        if now.lineLimit != before.lineLimit, editor.applyLineLimit(now.lineLimit) { setStatus(lastStatus) }
        if now.goplsPath != before.goplsPath, editorFile.language == "go" { reconnect(reason: "Restarting the language server with the new gopls…") }
    }

    /// Drops the language server connection and makes a new one, for when the Go installation or the gopls program changes:
    /// gobid then starts (or shares) the gopls that runs with them.
    func reconnect(reason: String = "Restarting the language server with the new Go…") {
        guard let old = editorFile.client else { connect(); return }
        old.onDisconnect = nil
        old.didClose(uri: editorFile.uri)
        old.close()
        editorFile.client = nil
        isConnected = false
        show([])   // the old server's problems are stale; the new one reports its own
        setStatus(reason)
        connect()
    }

    /// Connects to gobid on a background thread so the window shows immediately.
    func connect() {
        let editorFile = self.editorFile
        let trusted = self.trusted
        let goRoot = self.goRoot
        let goplsPath = AppPreferences.advanced.goplsPath
        let initialText = textView.string
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try Gobid.connect(channel: "lsp", workspaceRoot: editorFile.workspaceRoot, language: editorFile.language, goRoot: editorFile.language == "go" ? goRoot : "", tool: editorFile.language == "go" ? goplsPath : "", trusted: trusted)
                let client = LSPClient(session: session)
                client.onDiagnostics = { uri, diagnostics in
                    guard uri == editorFile.uri else { return }
                    DispatchQueue.main.async { self?.show(diagnostics) }
                }
                client.onNotification = { method, _ in
                    if method == "gobi/lspRestarted" { DispatchQueue.main.async { self?.setStatus("Language server restarted"); self?.semanticTokens.schedule(after: 1.0) } }
                }
                client.onDisconnect = { DispatchQueue.main.async { self?.setStatus("Disconnected from gobid") } }
                client.start()
                try client.initialize(rootPath: editorFile.workspaceRoot)
                DispatchQueue.main.async {
                    editorFile.client = client
                    self?.connectedAt = Date()
                    self?.isConnected = true
                    self?.onConnected?()
                    self?.lens.schedule(after: 1.0)
                    self?.semanticTokens.schedule(after: 1.0)
                    // Anything typed while connecting is covered by sending the current text, not the original.
                    let current = self?.textView.string ?? initialText
                    client.didOpen(uri: editorFile.uri, languageID: editorFile.language, version: editorFile.version, text: current)
                    self?.refreshPreview()
                    self?.setStatus("Connected (\(editorFile.language), sync \(client.syncKind == 2 ? "incremental" : "full"))")
                }
            } catch {
                DispatchQueue.main.async { self?.setStatus("Cannot reach gobid: \(error)") }
            }
        }
    }

    /// What the user needs to know about the file's longest line: read-only, or colours off.
    private var lineLimitNotice: String {
        if editorFile.isReadOnlyByLineLength { return ", read-only: a line is over \(AppPreferences.advanced.lineLimit) characters" }
        if editorFile.hasOverlongLine { return ", colours off for a line over \(EditorDocument.overlongLineLimit) characters" }
        return ""
    }

    private func setStatus(_ text: String) {
        lastStatus = text
        statusLabel.stringValue = text + lineLimitNotice
        onStatus?(text + lineLimitNotice)
    }

    // MARK: diagnostics

    private func show(_ shown: [LSPDiagnostic]) {
        let diagnostics = editorFile.language == "json" && !WindowSettings.reportJSONErrors ? [] : shown
        diagnosticCount = diagnostics.count
        diagnosticsSeenAt = Date()
        if firstDiagnosticsAt == nil { firstDiagnosticsAt = Date() }
        let underlineStarted = Date()
        applyUnderlines(diagnostics)
        underlineMilliseconds = Date().timeIntervalSince(underlineStarted) * 1000

        let name = editorFile.fileURL.lastPathComponent
        let lines = diagnostics.map { diagnostic -> String in
            let severity = ["", "error", "warning", "info", "hint"][min(max(diagnostic.severity, 0), 4)]
            return "\(name):\(diagnostic.start.line + 1):\(diagnostic.start.character + 1) \(severity): \(diagnostic.message)"
        }
        problemsView.string = lines.isEmpty ? "No problems" : lines.joined(separator: "\n")
        onDiagnostics?(diagnostics)
        setStatus("\(diagnostics.count) problem\(diagnostics.count == 1 ? "" : "s")")
    }

    private func applyUnderlines(_ diagnostics: [LSPDiagnostic]) {
        DiagnosticUnderlines.apply(diagnostics, to: textView, lineIndex: editorFile.lineIndex)
    }

    // MARK: self test

    /// Waits for the first diagnostics, then checks highlighting, gutter, painting, mouse handling and Vietnamese
    /// composition, printing timings. Used by `--selftest`; `snapshotPath` also writes a PNG of the editor.
    func runSelfTest(timeout: TimeInterval, snapshotPath: String?, finish: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] timer in
            let settled = diagnosticsSeenAt.map { Date().timeIntervalSince($0) > 1.0 } ?? false
            guard settled || Date() > deadline else { return }
            timer.invalidate()

            var passed = true
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
                passed = passed && ok
            }
            func measure(_ label: String, _ samples: [Double]) {
                guard !samples.isEmpty else { return }
                let sorted = samples.sorted()
                print(String(format: "  time   %@: median %.2f ms, p95 %.2f ms, max %.2f ms (%d samples)", label, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!, sorted.count))
            }

            print("selftest \(editorFile.fileURL.lastPathComponent) (\(editorFile.lineIndex.lineCount) lines)")
            func since(_ date: Date?) -> String { date.map { String(format: "%.0f ms", $0.timeIntervalSince(createdAt) * 1000) } ?? "never" }
            print(String(format: "  load   text view filled in %.1f ms", editor.loadMilliseconds))
            print("  load   connected to gobid after \(since(connectedAt)), first diagnostics after \(since(firstDiagnosticsAt))")
            print(String(format: "  load   underlining %d diagnostic(s) took %.1f ms", diagnosticCount ?? 0, underlineMilliseconds))

            check("TextKit 2 is active", textView.textLayoutManager != nil)
            check("diagnostics arrived", diagnosticCount != nil, "count=\(diagnosticCount.map(String.init) ?? "none")")

            if editorFile.isReadOnlyByLineLength {
                // A file with a line over the limit opens read-only: no colours, no typing, a notice in the status line.
                check("the document is read-only", !textView.isEditable)
                let lengthBefore = (textView.string as NSString).length
                textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                check("typing changes nothing", (textView.string as NSString).length == lengthBefore)
                check("the status line says it is read-only", statusLabel.stringValue.contains("read-only"), statusLabel.stringValue)
                finish(passed)
                return
            }

            // Highlighting and gutter: lay out the first screen, look at the attributes, paint to a bitmap.
            layOutViewport()
            let clip = editor.scrollView.contentView
            print(String(format: "  layout clip bounds x=%.1f (view frame x=%.1f, ruler %.0f pt, clip frame x=%.1f, text view width %.0f)", clip.bounds.origin.x, textView.frame.origin.x, editor.scrollView.verticalRulerView?.ruleThickness ?? 0, clip.frame.origin.x, textView.frame.width))
            check("the view starts at the left edge of the text", abs(clip.bounds.origin.x) < 0.5, "x=\(clip.bounds.origin.x)")
            if let gutter = editor.gutterFrame {
                let scrollFrame = editor.scrollView.frame
                check("the text starts to the right of the gutter, not under it", scrollFrame.minX >= gutter.maxX - 0.5, "gutter \(gutter), text area \(scrollFrame)")
            }
            let colouredFirst = firstTokenColoured()
            check("first token is coloured, plain text is not", colouredFirst.token && !colouredFirst.plain, "paragraphs coloured so far: \(editor.paragraphsColoured)")
            let underlined = underlinedFirstToken()
            check("an underline on the first token keeps its colour and adds the underline", underlined.ok, underlined.detail)
            let snapshotURL = snapshotPath.map { URL(fileURLWithPath: $0) }
            var paint: [Double] = []
            for attempt in 0 ..< 5 { paint.append(editor.snapshot(to: attempt == 0 ? snapshotURL : nil)) }
            measure("paint the whole editor to a bitmap (CPU)", paint)
            check("gutter drew line numbers", editor.gutterDrawCount > 0, "draws=\(editor.gutterDrawCount), last \(String(format: "%.2f", editor.gutterLastDrawMilliseconds)) ms")
            if let snapshotURL { print("  image  wrote \(snapshotURL.path)") }

            check("mouse handling", mouseChecks())
            let order = ProcessInfo.processInfo.environment["GOBI_SCROLL_FIRST"] != nil
            if order { scrollChecks(measure: measure) }
            measure("100 keystrokes mid-file (layout only)", typingBenchmark(count: 100, paint: false))
            let drawsBeforePaintedTyping = editor.gutterDrawCount
            measure("50 keystrokes mid-file (layout + paint window)", typingBenchmark(count: 50, paint: true))
            let paintedDraws = editor.gutterDrawCount - drawsBeforePaintedTyping
            check("the gutter is painted about once per keystroke (50 keystrokes, \(paintedDraws) draws)", abs(paintedDraws - 50) <= 5)
            if !order { scrollChecks(measure: measure) }


            let result = simulateVietnameseTyping()
            check("Vietnamese composition leaves the text correct", result.text, result.detail)
            check("no marked text left after commit", result.committed)
            check("line index still matches the text", result.indexMatches)
            check("syntax index still matches the text", result.syntaxMatches)
            check("edits reached the server (changes sent: \(editorFile.changesSent))", editorFile.changesSent > 0 || editorFile.client == nil)
            finish(passed)
        }
    }

    private func layOutViewport() {
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// Rendering attributes of the run that starts at `location`.
    private func renderingAttributes(at location: NSTextLocation, in layout: NSTextLayoutManager) -> [NSAttributedString.Key: Any]? {
        var found: [NSAttributedString.Key: Any]?
        layout.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
            found = attributes
            return false
        }
        return found
    }

    /// Puts a diagnostic under the first coloured token, checks it keeps its colour and gets an underline, then clears it.
    private func underlinedFirstToken() -> (ok: Bool, detail: String) {
        guard let layout = textView.textLayoutManager,
              let start = layout.location(layout.documentRange.location, offsetBy: 0),
              let line = (0 ..< min(editorFile.lineIndex.lineCount, 60)).first(where: { !editorFile.syntaxIndex.tokens(line: $0).isEmpty }),
              let first = editorFile.syntaxIndex.tokens(line: line).first,
              let tokenLocation = layout.location(start, offsetBy: editorFile.lineIndex.lineRange(line).lowerBound + Int(first.start)) else {
            return (false, "no coloured token")
        }
        let diagnostic = LSPDiagnostic(start: LSPPosition(line: line, character: Int(first.start)),
                                       end: LSPPosition(line: line, character: Int(first.start + first.length)),
                                       severity: 1, message: "self-test", source: nil)
        DiagnosticUnderlines.apply([diagnostic], to: textView, lineIndex: editorFile.lineIndex)
        let attributes = renderingAttributes(at: tokenLocation, in: layout) ?? [:]
        DiagnosticUnderlines.apply([], to: textView, lineIndex: editorFile.lineIndex)
        let coloured = attributes[.foregroundColor] != nil
        let underlined = attributes[.underlineStyle] != nil
        return (coloured && underlined, "foreground \(coloured), underline \(underlined)")
    }

    /// Whether the first token in the file has a colour and a plain position on the same line does not.
    private func firstTokenColoured() -> (token: Bool, plain: Bool) {
        guard let layout = textView.textLayoutManager,
              let start = layout.location(layout.documentRange.location, offsetBy: 0),
              let line = (0 ..< min(editorFile.lineIndex.lineCount, 60)).first(where: { !editorFile.syntaxIndex.tokens(line: $0).isEmpty }),
              let first = editorFile.syntaxIndex.tokens(line: line).first else { return (false, false) }
        let lineStart = editorFile.lineIndex.lineRange(line).lowerBound
        guard let tokenLocation = layout.location(start, offsetBy: lineStart + Int(first.start)) else { return (false, false) }
        let tokenColoured = renderingAttributes(at: tokenLocation, in: layout)?[.foregroundColor] != nil
        let tokens = editorFile.syntaxIndex.tokens(line: line)
        let covered = Set(tokens.flatMap { Int($0.start) ..< Int($0.start + $0.length) })
        let lineLength = editorFile.lineIndex.lineRange(line).count
        guard let plainOffset = (0 ..< lineLength).first(where: { !covered.contains($0) && $0 > Int(first.start) + Int(first.length) }),
              let plainLocation = layout.location(start, offsetBy: lineStart + plainOffset) else { return (tokenColoured, false) }
        return (tokenColoured, renderingAttributes(at: plainLocation, in: layout)?[.foregroundColor] != nil)
    }

    // MARK: mouse

    private func mouseEvent(_ type: NSEvent.EventType, at windowPoint: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// The window point just right of the left edge of the character at `offset`.
    private func windowPoint(forCharacterAt offset: Int) -> NSPoint? {
        guard let window else { return nil }
        // A one-character range: TextKit 2 returns an empty rect for a zero-length one.
        let caret = textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
        guard caret.height > 0 else { return nil }
        return window.convertFromScreen(NSRect(x: caret.minX + 1, y: caret.midY, width: 0, height: 0)).origin
    }

    /// Plays a press, optional drags and a release through the text view's own tracking loop; returns milliseconds.
    @discardableResult
    private func mouse(from start: NSPoint, dragging path: [NSPoint] = [], clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> Double {
        guard let window else { return 0 }
        print("  step   mouse press (clickCount \(clickCount), \(path.count) drags, modifiers \(modifiers.rawValue))")
        let started = Date()
        let release = path.last ?? start
        for point in path { window.postEvent(mouseEvent(.leftMouseDragged, at: point, clickCount: clickCount, modifiers: modifiers), atStart: false) }
        window.postEvent(mouseEvent(.leftMouseUp, at: release, clickCount: clickCount, modifiers: modifiers), atStart: false)
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: start, clickCount: clickCount, modifiers: modifiers))
        return Date().timeIntervalSince(started) * 1000
    }

    /// Clicks, double and triple clicks, shift-click and a drag, each verified against the selection it should make.
    private func mouseChecks() -> Bool {
        window?.makeFirstResponder(textView)
        layOutViewport()
        let text = textView.string as NSString
        guard let line = (0 ..< min(editorFile.lineIndex.lineCount, 60)).first(where: { editorFile.lineIndex.lineRange($0).count >= 12 }) else {
            print("  FAIL mouse: no suitable line on screen")
            return false
        }
        let range = editorFile.lineIndex.lineRange(line)
        let lineText = text.substring(with: NSRange(location: range.lowerBound, length: range.count)) as NSString
        let wordStart = range.lowerBound + lineText.rangeOfCharacter(from: .alphanumerics).location
        let inWord = wordStart + 2
        let farther = range.lowerBound + 10
        guard let clickPoint = windowPoint(forCharacterAt: inWord), let fartherPoint = windowPoint(forCharacterAt: farther) else {
            print("  FAIL mouse: cannot locate characters on screen")
            return false
        }

        var allCorrect = true
        func expect(_ name: String, _ actual: NSRange, _ wanted: NSRange, _ elapsed: Double) {
            let ok = NSEqualRanges(actual, wanted)
            print("  \(ok ? "ok  " : "FAIL") mouse: \(name) -> \(NSStringFromRange(actual))\(ok ? "" : " expected \(NSStringFromRange(wanted))") in \(String(format: "%.2f", elapsed)) ms")
            allCorrect = allCorrect && ok
        }

        var elapsed = mouse(from: clickPoint)
        expect("single click", textView.selectedRange(), NSRange(location: inWord, length: 0), elapsed)

        elapsed = mouse(from: clickPoint, clickCount: 2)
        let wordRange = textView.selectionRange(forProposedRange: NSRange(location: inWord, length: 0), granularity: .selectByWord)
        expect("double click selects the word", textView.selectedRange(), wordRange, elapsed)

        elapsed = mouse(from: clickPoint, clickCount: 3)
        expect("triple click selects the line", textView.selectedRange(), text.paragraphRange(for: NSRange(location: inWord, length: 0)), elapsed)

        mouse(from: clickPoint)
        elapsed = mouse(from: fartherPoint, modifiers: .shift)
        expect("shift-click extends the selection", textView.selectedRange(), NSRange(location: inWord, length: farther - inWord), elapsed)

        elapsed = mouse(from: clickPoint, dragging: [fartherPoint])
        expect("drag selects", textView.selectedRange(), NSRange(location: inWord, length: farther - inWord), elapsed)
        return allCorrect
    }

    // MARK: scrolling

    private func scrollChecks(measure: (String, [Double]) -> Void) {
        let clip = editor.scrollView.contentView
        let totalHeight = textView.frame.height
        guard totalHeight > clip.bounds.height * 3 else { return }   // nothing worth scrolling in a small file

        // Wheel: 100 events of three lines each, laying out after each.
        var wheel: [Double] = []
        clip.scroll(to: .zero)
        editor.scrollView.reflectScrolledClipView(clip)
        for _ in 0 ..< 100 {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cgEvent) else { break }
            let started = Date()
            editor.scrollView.scrollWheel(with: event)
            layOutViewport()
            wheel.append(Date().timeIntervalSince(started) * 1000)
        }
        measure("scroll wheel, 100 events (layout)", wheel)
        let moved = clip.bounds.origin.y
        print("  \(moved > 0 ? "ok  " : "FAIL") scroll wheel moved the view to y=\(Int(moved)) of \(Int(totalHeight))")

        // Dragging the scroller knob: jumps to arbitrary positions, laying out and painting each time.
        var jumps: [Double] = []
        for step in 1 ... 20 {
            let fraction = Double((step * 37) % 100) / 100
            let started = Date()
            if ProcessInfo.processInfo.environment["GOBI_JUMP_BY_LINE"] != nil {
                // Jump by text position instead of by pixel position: the line is known, its y is not.
                let line = Int(Double(editorFile.lineIndex.lineCount - 1) * fraction)
                textView.scrollRangeToVisible(NSRange(location: editorFile.lineIndex.lineRange(line).lowerBound, length: 0))
            } else {
                clip.scroll(to: NSPoint(x: 0, y: (totalHeight - clip.bounds.height) * fraction))
                editor.scrollView.reflectScrolledClipView(clip)
            }
            layOutViewport()
            editor.snapshot(to: nil)
            jumps.append(Date().timeIntervalSince(started) * 1000)
            if jumps.last! > 200 { print(String(format: "  slow   jump %d to %.0f%% of the file took %.0f ms", step, fraction * 100, jumps.last!)) }
        }
        measure("scroller jump to a random place + paint, 20 jumps", jumps)
    }

    // MARK: typing

    /// Inserts characters mid-file, each followed by a synchronous viewport layout and optionally a window paint.
    private func typingBenchmark(count: Int, paint: Bool) -> [Double] {
        let middle = (textView.string as NSString).length / 2
        textView.scrollRangeToVisible(NSRange(location: middle, length: 0))
        layOutViewport()
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        var samples: [Double] = []
        for _ in 0 ..< count {
            let started = Date()
            textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            layOutViewport()
            if paint { flushPendingPaint() }
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        return samples
    }

    /// Types "tiếng " the way the built-in Vietnamese Telex input method drives a text view: a growing marked
    /// range for the word being composed, then a commit that replaces it.
    private func simulateVietnameseTyping() -> (text: Bool, committed: Bool, indexMatches: Bool, syntaxMatches: Bool, detail: String) {
        let start = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: 0))
        let nowhere = NSRange(location: NSNotFound, length: 0)
        var composing = ""
        for step in ["t", "ti", "tie", "tiê", "tiế", "tiến", "tiếng"] {
            composing = step
            textView.setMarkedText(step, selectedRange: NSRange(location: step.utf16.count, length: 0), replacementRange: nowhere)
        }
        textView.insertText(composing + " ", replacementRange: nowhere)

        let storage = textView.string as NSString
        let tail = storage.substring(from: start)
        let units = Array(textView.string.utf16)
        let rebuilt = LineIndex(utf16: units)
        let rebuiltSyntax = SyntaxIndex(language: editorFile.syntaxIndex.language, lineCount: rebuilt.lineCount) { Array(units[rebuilt.lineRange($0)]) }
        return (tail == "tiếng ", !textView.hasMarkedText(), rebuilt == editorFile.lineIndex, rebuiltSyntax == editorFile.syntaxIndex, "typed text: \"\(tail)\"")
    }
}
