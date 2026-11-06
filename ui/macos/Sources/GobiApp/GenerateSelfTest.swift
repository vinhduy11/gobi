import AppKit
import GobiClient
import GobiEditor
import GobiModel

extension AppDelegate {
    /// `GobiApp FIXTURE --selftest-generate`: the Generate popup, one-undo insertion, new files, the dropped reply for a changed
    /// buffer, Explorer folder items and gopls' fill struct, on a copy of the fixture project (a go.mod and a server.go with a struct,
    /// an interface and a function). Returns the number of failed checks.
    func runGenerateChecks(fixture: URL, addCleanup: (@escaping () -> Void) -> Void) -> Int {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "  ok   \(name)" : "  FAIL \(name)")
            if !passed { failures += 1 }
        }
        func settle(_ seconds: Double = 20, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        // Next to the fixture, not in the system temp folder (the caller keeps fixtures in its own scratch folder).
        let root = fixture.deletingLastPathComponent().appendingPathComponent("gobi-generate-\(UUID().uuidString)")
        guard (try? FileManager.default.copyItem(at: fixture, to: root)) != nil else { print("  FAIL cannot copy the fixture"); return 1 }
        addCleanup { try? FileManager.default.removeItem(at: root) }
        let savedPreferences = EditorPreferences.current
        EditorPreferences.update { $0.autoSave = .off }
        addCleanup { EditorPreferences.current = savedPreferences }

        let serverURL = root.appendingPathComponent("server.go")
        let original = (try? String(contentsOf: serverURL, encoding: .utf8)) ?? ""
        let controller = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        controller.presentsGenerateUI = false   // a pop-up menu or a sheet would hold the run loop; the same steps are driven directly
        controller.showWindow(nil)
        controller.openFile(serverURL)
        guard let pane = controller.currentPane else { print("  FAIL server.go did not open"); return failures + 1 }
        settle { pane.isConnected }
        RunLoop.current.run(until: Date().addingTimeInterval(3))   // let gopls load the package

        func placeCaret(inside marker: String, offset: Int = 0) {
            let range = (pane.textView.string as NSString).range(of: marker)
            pane.textView.setSelectedRange(NSRange(location: range.location + offset, length: 0))
        }
        func offer() -> GenerateOffer? {
            var result: GenerateOffer?
            var finished = false
            controller.loadGenerateOffer(in: pane) { result = $0; finished = true }
            settle { finished }
            return result
        }
        func insert(_ id: String, from offer: GenerateOffer, name: String = "", target: GenerateTarget = .current, values: [(String, String)] = []) -> Bool? {
            guard let item = offer.items.first(where: { $0.id == id }) else { return nil }
            var form = GenerateForm(item: item, fieldNames: item.needsFields ? offer.request.fields.map(\.name) : [])
            form.name = name
            form.target = target
            for (key, value) in values { form.set(key, to: value) }
            var outcome: Bool?
            controller.insertGenerated(form, base: offer.request, in: pane) { outcome = $0 }
            settle { outcome != nil }
            return outcome
        }
        func vet(_ folder: URL) -> (Bool, String) {
            let process = Process()
            let go = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("go").path }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/go/bin/go"
            process.executableURL = URL(fileURLWithPath: go)
            process.arguments = ["vet", "./..."]
            process.currentDirectoryURL = folder
            var environment = ProcessInfo.processInfo.environment
            environment["GOPROXY"] = "off"; environment["GOFLAGS"] = "-mod=mod"; environment["GOTOOLCHAIN"] = "local"
            process.environment = environment
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return (false, "cannot run go") }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus == 0, output)
        }
        func menuTitles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
        func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }

        // The popup for a caret in the struct.
        placeCaret(inside: "addr   string")
        guard let structOffer = offer() else { print("  FAIL no Generate answer for the struct"); return failures + 1 }
        let structIDs = structOffer.items.map(\.id)
        check("a caret in a struct offers the struct items (\(structIDs))", ["constructor", "options", "accessors", "string", "error-type", "implement"].allSatisfy(structIDs.contains) && structOffer.request.kind == "struct" && structOffer.request.name == "Server")
        check("the struct's fields come from the symbol model (\(structOffer.request.fields.map(\.name)))", structOffer.request.fields.map(\.name) == ["addr", "port", "logger"] && structOffer.request.fields[2].type == "*slog.Logger")
        let popup = controller.generateMenu(for: structOffer, in: pane)
        check("every popup item has an icon that exists on this macOS", allItems(popup).filter { !$0.isSectionHeader }.allSatisfy { $0.image != nil && $0.isEnabled })
        check("the struct popup has no Design Pattern entry (\(menuTitles(popup)))", !menuTitles(popup).contains("Design Pattern"))

        // Fill struct through gopls (codeAction/resolve).
        placeCaret(inside: "&Server{", offset: 8)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if let fill = offer() {
            check("gopls offers Fill struct inside the braces of a literal", fill.fillStruct != nil)
            let menuFill = controller.generateMenu(for: fill, in: pane)
            check("and the popup lists it (\(menuTitles(menuFill)))", menuTitles(menuFill).contains("Fill struct"))
            if let action = fill.fillStruct {
                controller.perform(action, named: "Fill struct")
                settle { pane.textView.string.contains("addr:") }
                check("choosing it resolves the edit and fills the literal", pane.textView.string.contains("addr:") && pane.textView.string.contains("port:"))
                pane.textView.undoManager?.undo()
                check("and one Undo takes it back", pane.textView.string == original)
            }
        } else { check("an offer inside a literal", false) }

        // Constructor: one insertion, one Undo restores the exact text.
        placeCaret(inside: "addr   string")
        let freshOffer = offer() ?? structOffer
        check("the constructor is inserted", insert("constructor", from: freshOffer) == true && pane.textView.string.contains("func NewServer(addr string, port int, logger *slog.Logger) *Server"))
        let caretLine = pane.editorFile.lineIndex.position(at: pane.textView.selectedRange().location).line
        let caretText = pane.textView.string.components(separatedBy: "\n")[safe: caretLine] ?? ""
        check("the caret is on the first line of the inserted code (\(caretText))", caretText.hasPrefix("// NewServer"))
        pane.textView.undoManager?.undo()
        check("one Undo restores the exact original text", pane.textView.string == original)

        // The imports: String() needs fmt; the file must still compile with everything applied.
        placeCaret(inside: "addr   string")
        let afterUndo = offer()
        check("after Undo the popup offers the constructor again", afterUndo?.items.contains { $0.id == "constructor" } == true)
        for id in ["constructor", "string", "accessors"] {
            placeCaret(inside: "addr   string")
            guard let current = offer() else { check("\(id): offer", false); continue }
            check("\(id) inserts", insert(id, from: current) == true)
        }
        check("the text has the import block edit and the three items", pane.textView.string.contains("\"fmt\"") && pane.textView.string.contains("func (s *Server) String() string") && pane.textView.string.contains("func (s *Server) Addr() string"))
        _ = pane.save()
        let compiled = vet(root)
        check("the file compiles (go vet through the toolchain)\(compiled.0 ? "" : ": " + compiled.1)", compiled.0)

        // A reply for a changed buffer is dropped.
        let beforeDrop = pane.textView.string
        placeCaret(inside: "addr   string")
        if let current = offer(), let item = current.items.first(where: { $0.id == "error-type" }) {
            var form = GenerateForm(item: item, fieldNames: [])
            form.name = "Parse"
            var outcome: Bool?
            controller.insertGenerated(form, base: current.request, in: pane) { outcome = $0 }
            pane.textView.insertText("// typed meanwhile\n", replacementRange: NSRange(location: 0, length: 0))
            settle { outcome != nil }
            check("a reply for a buffer that changed meanwhile is dropped", outcome == false && pane.textView.string == "// typed meanwhile\n" + beforeDrop)
            // The same for a result applied directly to a newer buffer.
            let staleVersion = UInt64(pane.editorFile.version)
            pane.textView.insertText("// and again\n", replacementRange: NSRange(location: 0, length: 0))
            var stale = GenerateResult()
            stale.version = staleVersion
            stale.text = "x"
            stale.edits = [TextEdit(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0), newText: "x")]
            let textBefore = pane.textView.string
            check("applying a result made for an older version changes nothing", !controller.applyGenerated(stale, title: "x", in: pane) && pane.textView.string == textBefore)
            check("a request made from facts of an older version is refused too", { () -> Bool in
                var refused: Bool?
                controller.insertGenerated(form, base: current.request, in: pane) { refused = $0 }
                return refused == false
            }())
        } else { check("error-type offered", false) }

        // A design pattern as a new file, from a caret between declarations.
        placeCaret(inside: "// Divide divides")
        if let fileOffer = offer() {
            let ids = fileOffer.items.map(\.id)
            check("between declarations the patterns are offered (\(ids.count) items)", ids.contains("strategy") && ids.contains("visitor") && fileOffer.request.kind == "file")
            let menu = controller.generateMenu(for: fileOffer, in: pane)
            let patterns = menu.items.first { $0.title == "Design Pattern" }?.submenu
            check("Design Pattern ▸ has the three groups (\(patterns.map(menuTitles) ?? []))", patterns.map { menuTitles($0).filter { ["CREATIONAL", "STRUCTURAL", "BEHAVIORAL"].contains($0) } } == ["CREATIONAL", "STRUCTURAL", "BEHAVIORAL"])
            let created = insert("strategy", from: fileOffer, target: .file, values: [("strategy", "Compressor"), ("method", "Compress(data []byte) ([]byte, error)"), ("strategies", "Gzip, Zstd")])
            let strategy = root.appendingPathComponent("strategy.go")
            check("a pattern is created as a new file and opened", created == true && FileManager.default.fileExists(atPath: strategy.path) && controller.currentPane?.editorFile.fileURL == strategy)
            check("the new file holds the pattern", ((try? String(contentsOf: strategy, encoding: .utf8)) ?? "").contains("type Compressor interface"))
            let again = insert("strategy", from: fileOffer, target: .file)
            check("creating it twice is refused and nothing is overwritten", again == false)
            let both = vet(root)
            check("the project still compiles with the new file\(both.0 ? "" : ": " + both.1)", both.0)
            controller.openFile(serverURL)
        } else { check("an offer between declarations", false) }

        // Test item: a new _test.go for the function under the caret.
        if let current = controller.currentPane, current === pane {
            placeCaret(inside: "func Divide", offset: 6)
            if let functionOffer = offer() {
                check("a caret in a function offers its test (\(functionOffer.items.map(\.id)))", functionOffer.items.contains { $0.id == "test" } && functionOffer.request.name == "Divide")
                let created = insert("test", from: functionOffer)
                let testFile = root.appendingPathComponent("server_test.go")
                check("the test goes to a new server_test.go that is opened", created == true && FileManager.default.fileExists(atPath: testFile.path) && controller.currentPane?.editorFile.fileURL == testFile)
                controller.openFile(serverURL)
            }
        }

        // Explorer: Generate ▸ on a folder.
        controller.generateInFolder(root, itemID: "folder-config")
        let configFile = root.appendingPathComponent("config_loader.go")
        settle { FileManager.default.fileExists(atPath: configFile.path) }
        check("Generate ▸ Config Loader… creates config_loader.go in the folder (\(controller.statusBarTexts))", FileManager.default.fileExists(atPath: configFile.path))
        let loader = vet(root)
        check("and the folder still compiles\(loader.0 ? "" : ": " + loader.1)", loader.0)

        // The menus.
        let editor = controller.editorMenu(for: pane)
        let generate = editor.items.first { $0.title == "Generate…" }
        check("the editor's menu has Generate… on ⌃N, enabled", generate?.isEnabled == true && generate?.keyEquivalent == "n" && generate?.keyEquivalentModifierMask == [.control])
        let explorer = controller.explorerMenu(row: -1)
        let folderItems = explorer?.items.first { $0.title == "Generate" }?.submenu
        check("the Explorer's Generate ▸ lists the five folder items, all enabled (\(folderItems.map(menuTitles) ?? []))", folderItems.map(menuTitles) == ["HTTP Handler…", "Message Consumer…", "Repository…", "Config Loader…", "Worker with Graceful Shutdown…"] && folderItems?.items.allSatisfy { $0.isEnabled && $0.image != nil } == true)
        return failures
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
