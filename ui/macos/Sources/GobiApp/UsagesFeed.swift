import AppKit
import GobiClient
import GobiModel

/// Runs Find Usages for a project window: asks gopls for the references, finds the enclosing declaration of each (open files from a
/// versioned snapshot, closed files through a bounded queue), reads the source lines off the main thread into a cache and hands
/// the grouped result to the Usages tab. Everything here runs on the main thread except the file reads, which publish back to it.
final class UsagesFeed {
    private unowned let owner: ProjectWindowController
    private var requestGate = RequestGate()
    private var pipelineGate = RequestGate()
    private let queue = SymbolFetchQueue(limit: 4)
    /// The symbols of open documents, one snapshot per document and version.
    private var snapshots: [String: (version: Int, symbols: [DocumentSymbolInfo])] = [:]

    private(set) var locations: [SourceLocation] = []
    private(set) var symbols: [String: [DocumentSymbolInfo]] = [:]
    private(set) var context: UsageContext?
    private(set) var result: UsageResult?
    private(set) var cache = UsageLineCache()
    private var client: LSPClient?
    private var includeTests = true
    private var limit = UsageGroups.pageSize
    private var watcher: NSObjectProtocol?

    /// Instrumentation for the self-test: reads per file path, reads that ran on the main thread, symbol requests per uri.
    private(set) var diskReads: [String: Int] = [:]
    private(set) var mainThreadReads = 0
    private(set) var symbolRequests: [String: Int] = [:]
    private(set) var isStale = false
    /// How long a closed file may take to answer documentSymbol before it is shown as file scope.
    var symbolTimeout: TimeInterval = 10

    init(owner: ProjectWindowController) { self.owner = owner }

    deinit { if let watcher { NotificationCenter.default.removeObserver(watcher) } }

    func attach(_ panel: UsagesPanelView) {
        panel.lineText = { [weak self] line in self?.text(of: line) }
        panel.displayPath = { [weak self] uri in self?.displayPath(uri) ?? uri }
        panel.onOpen = { [weak self] line in self?.open(line) }
        panel.onRerun = { [weak self] in self?.rerun() }
        panel.onTestsChanged = { [weak self] on in self?.includeTests = on; self?.publish() }
        panel.onShowMore = { [weak self] in self?.limit += UsageGroups.pageSize; self?.publish() }
        watcher = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkStale() }
    }

    private var panel: UsagesPanelView { owner.usagesPanel }

    // MARK: request

    /// Asks for the references of the symbol at `position` in the document `uri`. With `alwaysPanel` the tab opens even for a
    /// single hit; otherwise one hit is opened at once and several open the tab.
    func start(uri: String, position: LSPPosition, symbol: String, client: LSPClient, alwaysPanel: Bool) {
        self.client = client
        let version = versionOf(uri) ?? 0
        let ticket = requestGate.begin(version: version)
        var body: [String: Any] = ["textDocument": ["uri": uri], "position": ["line": position.line, "character": position.character]]
        body["context"] = ["includeDeclaration": true]
        _ = client.request("textDocument/references", params: body) { [weak self] reply in
            let found: [SourceLocation] = { if case .success(let value) = reply { return LSPResults.locations(value) } else { return [] } }()
            DispatchQueue.main.async {
                guard let self, self.requestGate.accepts(ticket, version: self.versionOf(uri) ?? 0) else { return }
                self.answered(found, uri: uri, position: position, symbol: symbol, alwaysPanel: alwaysPanel)
            }
        }
    }

    private func answered(_ found: [SourceLocation], uri: String, position: LSPPosition, symbol: String, alwaysPanel: Bool) {
        var seen = Set<String>()
        let inProject = found.filter { location in
            URL(string: location.uri)?.isFileURL == true && seen.insert("\(location.uri):\(location.start.line):\(location.start.character)").inserted
        }
        owner.lastListedLocations = inProject.count
        if inProject.isEmpty { owner.showNote("No \(alwaysPanel ? "usages" : "references") found"); NSSound.beep(); return }
        if !alwaysPanel {
            if inProject.count == 1 { owner.open(location: inProject[0]); return }
            if !owner.presentsLocationMenus { return }
        }
        present(inProject, origin: uri, position: position, symbol: symbol)
    }

    private func present(_ found: [SourceLocation], origin: String, position: LSPPosition, symbol: String) {
        queue.cancel()
        let uris = Array(Set(found.map(\.uri))).sorted()
        var versions: [String: Int] = [:]
        for uri in uris + [origin] { if let version = versionOf(uri) { versions[uri] = version } }
        context = UsageContext(originURI: origin, position: position, symbol: symbol, versions: versions, files: Set(uris))
        locations = found
        symbols = [:]
        result = nil
        cache = UsageLineCache()
        limit = UsageGroups.pageSize
        isStale = false
        panel.markStale(false)
        owner.bottomPanel.isHidden = false
        owner.bottomPanel.select(tab: .usages)
        panel.showMessage("Finding usages of \(symbol)…")
        let ticket = pipelineGate.begin(version: 0)
        queue.run(uris: uris, fetch: { [weak self] uri, done in self?.fetchSymbols(uri, done: done) ?? done(nil) }) { [weak self] outcome in
            guard let self, self.pipelineGate.accepts(ticket, version: 0) else { return }
            self.symbols = outcome.symbols
            self.readLines(of: uris, ticket: ticket)
        }
    }

    /// Runs the search again for the symbol it was made for.
    func rerun() {
        guard let context, let client = client ?? owner.currentPane?.editorFile.client else { return }
        start(uri: context.originURI, position: context.position, symbol: context.symbol, client: client, alwaysPanel: true)
    }

    // MARK: symbols

    private func fetchSymbols(_ uri: String, done: @escaping ([DocumentSymbolInfo]?) -> Void) {
        let pane = path(of: uri).flatMap { owner.panes[$0] }
        let version = pane?.editorFile.version ?? 0
        if let pane, let snapshot = snapshots[uri], snapshot.version == pane.editorFile.version { done(snapshot.symbols); return }
        guard let client else { done(nil); return }
        symbolRequests[uri, default: 0] += 1
        client.documentSymbolInfos(uri: uri, version: version) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                if let pane, pane.editorFile.version != version { done(nil); return }   // the document moved on: its positions no longer fit
                if pane != nil { self.snapshots[uri] = (version, found) }
                done(found)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + symbolTimeout) { done(nil) }
    }

    // MARK: source lines

    private func readLines(of uris: [String], ticket: RequestGate.Ticket) {
        var wanted: [String: Set<Int>] = [:]
        for location in locations { wanted[location.uri, default: []].insert(location.start.line) }
        // Open files come from the live buffer (memory); closed files from disk, off the main thread.
        var closed: [String] = []
        for uri in uris {
            guard let path = path(of: uri) else { continue }
            if let pane = owner.panes[path] {
                var lines: [Int: String] = [:]
                for line in wanted[uri] ?? [] { if let text = liveLine(pane, line) { lines[line] = text } }
                cache.store(path: uri, lines: lines)
            } else {
                closed.append(uri)
            }
        }
        let batches = stride(from: 0, to: closed.count, by: 20).map { Array(closed[$0 ..< min($0 + 20, closed.count)]) }
        func next(_ index: Int) {
            guard pipelineGate.accepts(ticket, version: 0) else { return }
            guard index < batches.count else { publish(); return }
            let batch = batches[index]
            let needed = wanted
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let onMain = Thread.isMainThread
                var read: [(String, [Int: String]?)] = []
                for uri in batch { read.append((uri, Self.readLines(uri: uri, lines: needed[uri] ?? []))) }
                DispatchQueue.main.async {
                    guard let self, self.pipelineGate.accepts(ticket, version: 0) else { return }
                    if onMain { self.mainThreadReads += 1 }
                    for (uri, lines) in read { self.cache.store(path: uri, lines: lines); self.diskReads[uri, default: 0] += 1 }
                    next(index + 1)
                }
            }
        }
        next(0)
    }

    /// The wanted lines of a file on disk; nil when it cannot be read.
    private static func readLines(uri: String, lines: Set<Int>) -> [Int: String]? {
        guard let url = URL(string: uri), let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var found: [Int: String] = [:]
        var number = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.contains(number) { found[number] = String(line) }
            number += 1
            if number > (lines.max() ?? -1) { break }
        }
        return found
    }

    private func liveLine(_ pane: EditorPane, _ number: Int) -> String? {
        let index = pane.editorFile.lineIndex
        guard number >= 0, number < index.lineCount else { return nil }
        let range = index.lineRange(number), text = pane.textView.string as NSString
        guard range.upperBound <= text.length else { return nil }
        return text.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    // MARK: publishing

    private func publish() {
        guard let context else { return }
        let built = UsageGroups.build(locations: locations, symbols: symbols, includeTests: includeTests, limit: limit)
        result = built
        if built.total == 0 { panel.showMessage("No usages of \(context.symbol)" + (includeTests ? "" : " outside tests")); return }
        panel.show(built, symbol: context.symbol)
        panel.markStale(isStale)
    }

    /// Called after every text change in the app: a changed document the result came from makes the result stale.
    func checkStale() {
        guard let context, result != nil, !isStale else { return }
        if context.isStale(currentVersion: { versionOf($0) }) {
            isStale = true
            panel.markStale(true)
        }
    }

    private func text(of line: UsageLine) -> String? { cache.line(path: line.uri, line.line) }

    private func displayPath(_ uri: String) -> String {
        guard let path = path(of: uri) else { return uri }
        return StatusBar.relativePath(projectRoot: owner.root.path, file: path)
    }

    // MARK: opening

    /// Opens a usage after checking it is still there: an open file is checked against its live text, a closed one against the
    /// disk (read off the main thread). A deleted file or a line that moved marks the result stale instead of landing elsewhere.
    func open(_ line: UsageLine) {
        let location = SourceLocation(uri: line.uri, start: LSPPosition(line: line.line, character: line.start), end: LSPPosition(line: line.line, character: line.end))
        guard let path = path(of: line.uri) else { return }
        let cached = cache.peek(path: line.uri, line.line) ?? ""
        if let pane = owner.panes[path] {
            finishOpen(line, location, current: liveLine(pane, line.line), cached: cached)
            return
        }
        let uri = line.uri, number = line.line
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let current = Self.readLines(uri: uri, lines: [number])?[number]
            DispatchQueue.main.async { self?.finishOpen(line, location, current: current, cached: cached) }
        }
    }

    private func finishOpen(_ line: UsageLine, _ location: SourceLocation, current: String?, cached: String) {
        guard UsageGroups.isStillThere(cached: cached, current: current) else {
            isStale = true
            panel.markStale(true)
            owner.showNote(current == nil ? "That file or line is gone: rerun the search" : "That line has changed: rerun the search")
            NSSound.beep()
            return
        }
        owner.open(location: location)
    }

    // MARK: helpers

    private func path(of uri: String) -> String? { URL(string: uri).flatMap { $0.isFileURL ? $0.path : nil } }
    private func versionOf(_ uri: String) -> Int? { path(of: uri).flatMap { owner.panes[$0]?.editorFile.version } }
}
