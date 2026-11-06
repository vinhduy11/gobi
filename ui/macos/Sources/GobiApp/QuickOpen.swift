import AppKit
import GobiClient
import GobiModel

/// Go to File, the Command Palette and the symbol searches, built on `QuickOpenPanel`.
extension ProjectWindowController {
    private static let skippedFolders: Set<String> = [".git", "node_modules", ".build", "dist", ".idea", ".vscode"]

    /// Every file of the project as a path relative to the root, found on first use. Large trees stop at 30,000 files.
    private func projectFiles() -> [String] {
        var found: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if Self.skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false {
                found.append(StatusBar.relativePath(projectRoot: root.path, file: url.path))
                if found.count >= 30_000 { break }
            }
        }
        return found.sorted()
    }

    // MARK: Go to File (⌘P)

    func goToFile() {
        let files = projectFiles()
        present(placeholder: "Go to file", rowsFor: { query in
            Fuzzy.rank(query, in: files).prefix(60).map { index -> QuickItem in
                let path = files[index]
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                let kind = FileKind.classify(name: name, isDirectory: false)
                return QuickItem(title: name, detail: folder, symbol: kind.look.symbol.isEmpty ? "doc" : kind.look.symbol) { [weak self] in
                    self?.openFile(self!.root.appendingPathComponent(path))
                }
            }
        })
    }

    // MARK: Command Palette (⇧⌘P)

    func commandPalette(perform: @escaping (String) -> Void) {
        present(placeholder: "Type a command", rowsFor: { query in
            CommandList.search(query).prefix(60).map { command in
                QuickItem(title: command.title, detail: command.menu, symbol: "command", shortcut: AppPreferences.keymap.shortcut(for: command.menu + " ▸ " + command.title, default: command.shortcut)) { perform(command.action) }
            }
        })
    }

    // MARK: Go to Symbol in File (⇧⌘O)

    func goToFileSymbol() {
        guard let pane = currentPane, let client = pane.editorFile.client else { NSSound.beep(); return }
        client.documentSymbols(uri: pane.editorFile.uri) { [weak self] symbols in
            DispatchQueue.main.async {
                let flat = OutlineSymbol.flatten(symbols)
                self?.present(placeholder: "Go to symbol in file", rowsFor: { query in
                    Fuzzy.rank(query, in: flat.map(\.displayName)).prefix(60).map { index -> QuickItem in
                        let symbol = flat[index]
                        return QuickItem(title: symbol.displayName, detail: "line \(symbol.line + 1)", symbol: Self.symbolName(symbol.kind)) { [weak self] in
                            self?.currentPane?.reveal(line: symbol.line, character: 0)
                        }
                    }
                })
            }
        }
    }

    // MARK: Go to Symbol in Workspace (⌘T)

    func goToWorkspaceSymbol() {
        guard let client = currentPane?.editorFile.client else { NSSound.beep(); return }
        presentAsync(placeholder: "Go to symbol in project") { [weak self] query, deliver in
            guard let self else { return }
            guard !query.isEmpty else { deliver([]); return }
            client.workspaceSymbols(query: query) { symbols in
                let rows = symbols.prefix(60).map { symbol -> QuickItem in
                    let file = URL(string: symbol.location.uri).map { StatusBar.relativePath(projectRoot: self.root.path, file: $0.path) } ?? ""
                    return QuickItem(title: symbol.name, detail: file + ":\(symbol.location.start.line + 1)", symbol: Self.symbolName(symbol.kind)) { [weak self] in
                        self?.open(location: symbol.location)
                    }
                }
                deliver(Array(rows))
            }
        }
    }

    private static func symbolName(_ kind: OutlineSymbol.Kind) -> String {
        switch kind {
        case .function, .method: return "function"
        case .type: return "cube"
        case .variable, .constant: return "v.circle"
        case .field: return "list.bullet"
        case .module: return "shippingbox"
        case .other: return "circle"
        }
    }

    // MARK: showing

    private func present(placeholder: String, rowsFor: @escaping (String) -> [QuickItem]) {
        presentAsync(placeholder: placeholder) { query, deliver in deliver(rowsFor(query)) }
    }

    private func presentAsync(placeholder: String, source: @escaping (String, @escaping ([QuickItem]) -> Void) -> Void) {
        guard let window else { return }
        quickOpen?.close()
        let panel = QuickOpenPanel(placeholder: placeholder)
        panel.source = source
        quickOpen = panel
        panel.present(over: window)
    }

    /// The open panel's rows and a way to type into it, for the self-test.
    var quickOpenTitles: [String] { quickOpen?.rowTitles ?? [] }
    func quickOpenType(_ text: String) { quickOpen?.setQuery(text) }
    func quickOpenChoose() { quickOpen?.choose() }
    var isQuickOpenVisible: Bool { quickOpen?.isVisible ?? false }
}
