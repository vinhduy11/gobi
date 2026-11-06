import AppKit
import GobiClient
import GobiEditor
import GobiModel

/// Fills the editor's code lens: the declarations of a Go file, and gopls' reference and implementation counts for the ones
/// on screen. Everything waits for typing and scrolling to stop, and nothing here blocks the main thread.
final class CodeLensFeed {
    private unowned let pane: EditorPane
    private var timer: Timer?
    private var cache = LensCache()
    private var pending: Set<String> = []
    private var declarations: [LensDeclaration] = []
    private var declarationsVersion = 0
    private var observers: [NSObjectProtocol] = []
    /// How long typing must pause before the lens is refreshed.
    static let typingDelay: TimeInterval = 0.5
    static let scrollDelay: TimeInterval = 0.15
    /// Lines above and below the screen that also get counts, so a short scroll finds them ready.
    static let margin = 40
    /// How many gopls requests were sent (the self-test reads it to see the cache at work).
    private(set) var requestsSent = 0

    init(pane: EditorPane) {
        self.pane = pane
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: pane.textView, queue: .main) { [weak self] _ in self?.schedule(after: Self.typingDelay) })
        let clip = pane.editor.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.schedule(after: Self.scrollDelay) })
        observers.append(center.addObserver(forName: EditorPreferences.didChange, object: nil, queue: .main) { [weak self] _ in self?.schedule(after: 0.05) })
        pane.editor.onLensClick = { [weak self] line, action in self?.clicked(line: line, action: action) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); timer?.invalidate() }

    /// Called by the owner of the pane, which routes a click (it can run tests and open references).
    var onAction: ((LensAction, LensDeclaration) -> Void)?

    private var isGoFile: Bool { pane.editorFile.language == "go" }
    private var isTestFile: Bool { pane.editorFile.fileURL.lastPathComponent.hasSuffix("_test.go") }

    func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let editorFile = pane.editorFile
        guard isGoFile, EditorPreferences.current.showCodeLens, !editorFile.isReadOnlyByLineLength else {
            pane.editor.setCodeLenses([:], version: editorFile.version)
            return
        }
        let version = editorFile.version
        if declarationsVersion != version {
            declarations = CodeLens.declarations(in: pane.textView.string).map { declaration in
                var adjusted = declaration
                if declaration.kind == .test && !isTestFile { adjusted.kind = .function }
                return adjusted
            }
            declarationsVersion = version
        }
        publish()
        guard let client = editorFile.client else { return }
        let lines = pane.editor.visibleLines(margin: Self.margin)
        for declaration in declarations where lines.contains(declaration.position.line) && declaration.kind != .test {
            let known = cache.counts(name: declaration.qualifiedName, version: version)
            let wantsImplementations = declaration.kind == .interface || declaration.kind == .interfaceMethod
            if known?.references == nil { fetchReferences(declaration, client: client, version: version) }
            if wantsImplementations, known?.implementations == nil { fetchImplementations(declaration, client: client, version: version) }
        }
    }

    private func fetchReferences(_ declaration: LensDeclaration, client: LSPClient, version: Int) {
        let key = "r:" + declaration.qualifiedName + "@\(version)"
        guard pending.insert(key).inserted else { return }
        requestsSent += 1
        client.references(uri: pane.editorFile.uri, at: declaration.position) { [weak self] locations in
            DispatchQueue.main.async {
                self?.pending.remove(key)
                // The declaration itself is one of the locations gopls lists.
                let uses = max(0, locations.filter { URL(string: $0.uri)?.isFileURL == true }.count - 1)
                self?.arrived(declaration.qualifiedName, version: version, references: uses, implementations: nil)
            }
        }
    }

    private func fetchImplementations(_ declaration: LensDeclaration, client: LSPClient, version: Int) {
        let key = "i:" + declaration.qualifiedName + "@\(version)"
        guard pending.insert(key).inserted else { return }
        requestsSent += 1
        client.implementation(uri: pane.editorFile.uri, at: declaration.position) { [weak self] locations in
            DispatchQueue.main.async {
                self?.pending.remove(key)
                self?.arrived(declaration.qualifiedName, version: version, references: nil, implementations: locations.filter { URL(string: $0.uri)?.isFileURL == true }.count)
            }
        }
    }

    private func arrived(_ name: String, version: Int, references: Int?, implementations: Int?) {
        // The text moved on while gopls was working: the position it answered for no longer means this declaration.
        guard pane.editorFile.version == version else { return }
        cache.store(name: name, version: version, references: references, implementations: implementations)
        publish()
    }

    private func publish() {
        let version = pane.editorFile.version
        var lenses: [Int: [LensSegment]] = [:]
        for declaration in declarations {
            let counts = cache.counts(name: declaration.qualifiedName, version: version)
            let segments = CodeLens.segments(for: declaration, references: counts?.references, implementations: counts?.implementations)
            if !segments.isEmpty { lenses[declaration.position.line + 1] = segments }
        }
        pane.editor.setCodeLenses(lenses, version: version)
    }

    private func clicked(line: Int, action: LensAction) {
        guard let declaration = declarations.first(where: { $0.position.line + 1 == line }) else { return }
        onAction?(action, declaration)
    }
}
