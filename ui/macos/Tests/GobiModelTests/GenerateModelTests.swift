import Testing
@testable import GobiModel

@Suite("Generate: context from the symbol model")
struct GenerateContextTests {
    private func pos(_ l: Int, _ c: Int = 0) -> LSPPosition { LSPPosition(line: l, character: c) }

    private func symbol(_ name: String, _ kind: OutlineSymbol.Kind, detail: String, from: Int, to: Int, children: [DocumentSymbolInfo] = []) -> DocumentSymbolInfo {
        DocumentSymbolInfo(uri: "file:///p/s.go", name: name, detail: detail, kind: kind, range: (pos(from), pos(to)), selection: (pos(from, 5), pos(from, 9)), children: children, version: 4)
    }

    private let source = "package demo\n\ntype Server struct {\n\taddr string\n\tlog *slog.Logger\n}\n\nfunc (s *Server) Run(ctx context.Context, n int) (string, error) { return \"\", nil }\n"

    private var symbols: [DocumentSymbolInfo] {
        [
            symbol("Server", .type, detail: "struct{...}", from: 2, to: 6, children: [
                symbol("addr", .field, detail: "string", from: 3, to: 4), symbol("log", .field, detail: "*slog.Logger", from: 4, to: 5),
            ]),
            symbol("(*Server).Run", .method, detail: "func(ctx context.Context, n int) (string, error)", from: 7, to: 8),
        ]
    }

    private func make(line: Int, source: String? = nil, symbols: [DocumentSymbolInfo]? = nil) -> GenerateRequest {
        GenerateContext.make(path: "/p/s.go", package: "demo", source: source ?? self.source, caret: pos(line, 1), symbols: symbols ?? self.symbols, version: 4, goVersion: "1.23")
    }

    @Test func aCaretInAStructGivesTheStructAndItsFields() {
        for line in [2, 3, 4] {
            let r = make(line: line)
            #expect(r.kind == "struct" && r.name == "Server" && r.version == 4 && r.goVersion == "1.23" && r.package == "demo")
            #expect(r.fields == [GenerateField(name: "addr", type: "string"), GenerateField(name: "log", type: "*slog.Logger")])
            #expect(r.line == line && r.column == 1 && r.source == source && r.path == "/p/s.go")
        }
    }

    @Test func aCaretInAMethodGivesItsReceiverNameAndSignature() {
        let r = make(line: 7)
        #expect(r.kind == "func" && r.name == "Run" && r.receiver == "Server")
        #expect(r.params == [GenerateField(name: "ctx", type: "context.Context"), GenerateField(name: "n", type: "int")])
        #expect(r.results == ["string", "error"])
    }

    @Test func aCaretBetweenDeclarationsIsTheFile() {
        let r = make(line: 6)
        #expect(r.kind == "file" && r.name == "" && r.fields.isEmpty)
    }

    @Test func aFileWithOnlyAPackageClauseIsEmpty() {
        #expect(make(line: 0, source: "package demo\n", symbols: []).kind == "empty")
        #expect(make(line: 0, source: "", symbols: []).kind == "empty")
        #expect(make(line: 0, source: "// Package demo does x.\npackage demo\n", symbols: []).kind == "empty")
    }

    @Test func anInterfaceGivesItsMethods() {
        let iface = symbol("Store", .type, detail: "interface{...}", from: 0, to: 4, children: [
            symbol("Get", .method, detail: "func(key string) ([]byte, error)", from: 1, to: 2),
            symbol("Close", .method, detail: "func() error", from: 2, to: 3),
        ])
        let r = make(line: 1, symbols: [iface])
        #expect(r.kind == "interface" && r.name == "Store")
        #expect(r.methods == [GenerateMethod(name: "Get", params: [GenerateField(name: "key", type: "string")], results: ["[]byte", "error"]),
                              GenerateMethod(name: "Close", params: [], results: ["error"])])
    }

    @Test func aPlainFunctionHasNoReceiver() {
        let f = symbol("Divide", .function, detail: "func(a int, b int) int", from: 0, to: 2)
        let r = make(line: 1, symbols: [f])
        #expect(r.kind == "func" && r.name == "Divide" && r.receiver == "" && r.results == ["int"])
    }
}

@Suite("Generate: signatures")
struct GoSignatureTests {
    @Test func parametersAreSplitAtTopLevelCommas() {
        let s = GoSignature.parse("func(m map[string]int, f func(a, b int) error, rest ...string) (n int, err error)")
        #expect(s.params == [GenerateField(name: "m", type: "map[string]int"), GenerateField(name: "f", type: "func(a, b int) error"), GenerateField(name: "rest", type: "...string")])
        #expect(s.results == ["int", "error"])
    }

    @Test func groupedNamesShareTheType() {
        #expect(GoSignature.parse("func(a, b int, s string)").params.map(\.type) == ["int", "int", "string"])
    }

    @Test func unnamedParametersKeepOnlyTheirType() {
        let s = GoSignature.parse("func(int, []byte, chan int, <-chan string)")
        #expect(s.params == [GenerateField(name: "", type: "int"), GenerateField(name: "", type: "[]byte"), GenerateField(name: "", type: "chan int"), GenerateField(name: "", type: "<-chan string")])
    }

    @Test func noResultsAndOneResult() {
        #expect(GoSignature.parse("func()").results.isEmpty)
        #expect(GoSignature.parse("func() error").results == ["error"])
        #expect(GoSignature.parse("not a signature").params.isEmpty)
    }
}

@Suite("Generate: popup and dialog state")
struct GeneratePopupTests {
    private let items = [
        GenerateItem(id: "constructor", title: "Constructor", detail: "NewServer", needsFields: true),
        GenerateItem(id: "error-type", title: "Error type…", needsName: true),
        GenerateItem(id: "singleton", title: "Singleton", group: "creational"),
        GenerateItem(id: "adapter", title: "Adapter", group: "structural"),
        GenerateItem(id: "factory-method", title: "Factory Method", group: "creational"),
    ]

    @Test func plainItemsComeFirstThenDesignPatternsByGroup() {
        let entries = GeneratePopup.entries(from: items, fillStruct: false)
        #expect(entries == [
            .item(items[0]), .item(items[1]),
            .submenu("Design Pattern", [.heading("CREATIONAL"), .item(items[2]), .item(items[4]), .heading("STRUCTURAL"), .item(items[3])]),
        ])
    }

    @Test func fillStructIsOfferedAfterTheItemsWhenGoplsHasIt() {
        let entries = GeneratePopup.entries(from: Array(items.prefix(2)), fillStruct: true)
        #expect(entries.last == .fillStruct && entries.count == 3)
        #expect(GeneratePopup.entries(from: [], fillStruct: false).isEmpty)
    }

    private let strategy = GenerateItem(id: "strategy", title: "Strategy", group: "behavioral", params: [
        GenerateParam(key: "strategy", label: "Interface", defaults: ["Compressor"], kind: "type", multi: false),
        GenerateParam(key: "method", label: "Method", defaults: ["Compress(data []byte) ([]byte, error)"], kind: "signature", multi: false),
        GenerateParam(key: "strategies", label: "Strategies", defaults: ["Gzip", "Zstd"], kind: "names", multi: true),
        GenerateParam(key: "fields", label: "Fields", defaults: ["a int", "b string"], kind: "fields", multi: true),
    ])

    @Test func theFormStartsFromTheDefaultsAndSendsNothingForUntouchedOnes() {
        let form = GenerateForm(item: strategy, fieldNames: [])
        #expect(form.text(of: "strategies") == "Gzip, Zstd" && form.text(of: "fields") == "a int\nb string" && form.text(of: "strategy") == "Compressor")
        var request = GenerateRequest()
        form.apply(to: &request)
        #expect(request.item == "strategy" && request.target == "current")
        #expect(request.answers.first { $0.key == "strategies" }?.values == ["Gzip", "Zstd"])
        #expect(request.answers.first { $0.key == "fields" }?.values == ["a int", "b string"])
    }

    @Test func aBlankAnswerIsLeftOutSoCoreUsesTheDefault() {
        var form = GenerateForm(item: strategy, fieldNames: [])
        form.set("strategy", to: "  ")
        var request = GenerateRequest()
        form.apply(to: &request)
        #expect(request.answers.contains { $0.key == "strategy" } == false)
        #expect(form.hint(for: "strategy") == nil)
    }

    @Test func hintsExplainWhatIsWrong() {
        var form = GenerateForm(item: strategy, fieldNames: [])
        form.set("strategy", to: "two words")
        form.set("method", to: "Compress")
        form.set("strategies", to: "Gzip, Gzip")
        form.set("fields", to: "a int\nb")
        #expect(form.hint(for: "strategy") == "Not a valid Go name")
        #expect(form.hint(for: "method") == "Write a method signature, like Run(ctx context.Context) error")
        #expect(form.hint(for: "strategies") == "Gzip is given twice")
        #expect(form.hint(for: "fields") == "Each line needs a name and a type, like addr string")
        #expect(!form.canGenerate)
        form.set("strategy", to: "fast")
        #expect(form.hint(for: "strategy") == nil)
    }

    @Test func theTargetFileIsNamedAfterThePattern() {
        var form = GenerateForm(item: GenerateItem(id: "chain-of-responsibility", title: "Chain of Responsibility", group: "behavioral"), fieldNames: [])
        #expect(form.newFileName == "chain_of_responsibility.go")
        form.target = .file
        var request = GenerateRequest()
        form.apply(to: &request)
        #expect(request.target == "file")
    }

    @Test func tickedFieldsAreSentOnlyWhenNotAll() {
        var form = GenerateForm(item: GenerateItem(id: "accessors", title: "Getters and Setters…", needsFields: true), fieldNames: ["addr", "log"])
        var request = GenerateRequest()
        form.apply(to: &request)
        #expect(request.selected.isEmpty)
        form.setTicked("log", false)
        form.apply(to: &request)
        #expect(request.selected == ["addr"])
        form.setTicked("addr", false)
        #expect(form.hint(for: "fields") == "Tick at least one field" && !form.canGenerate)
    }

    @Test func theNameIsRequiredWhenTheItemAsksForOne() {
        var form = GenerateForm(item: items[1], fieldNames: [])
        #expect(!form.canGenerate)
        form.name = "Parse"
        #expect(form.canGenerate)
        var request = GenerateRequest()
        form.apply(to: &request)
        #expect(request.askedName == "Parse")
        form.name = "1bad"
        #expect(form.hint(for: "name") == "Not a valid Go name")
    }
}

@Suite("Generate: applying the answer")
struct GenerateInsertionTests {
    private func position(_ text: String, _ start: Int) -> LSPPosition {
        let units = Array(text.utf16)
        return LineIndex(utf16: units).position(at: start)
    }

    @Test func theCaretGoesToTheStartOfTheInsertedCodeBehindAnImportEdit() {
        let original = "package demo\n\ntype T struct{ a string }\n"
        let imports = TextEdit(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 0), newText: "\nimport \"fmt\"\n")
        let end = position(original, original.utf16.count)
        let body = TextEdit(start: end, end: end, newText: "\nfunc (t *T) String() string {\n\treturn fmt.Sprint(t.a)\n}\n")
        let snippet = "func (t *T) String() string {\n\treturn fmt.Sprint(t.a)\n}"
        let at = GenerateInsertion.caret(of: snippet, edits: [imports, body], in: original)
        // the import adds two lines, the blank line of the body edit adds one before the snippet
        #expect(at == LSPPosition(line: 6, character: 0))
    }

    @Test func aWholeFileEditPlacesTheCaretInsideTheNewText() {
        let edit = TextEdit(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0), newText: "package demo\n\nfunc main() {}\n")
        #expect(GenerateInsertion.caret(of: "func main() {}", edits: [edit], in: "") == LSPPosition(line: 2, character: 0))
    }

    @Test func noEditHoldingTheSnippetGivesNoCaret() {
        #expect(GenerateInsertion.caret(of: "x", edits: [], in: "package a\n") == nil)
    }
}

@Suite("Generate: the module's Go version")
struct GoDirectiveTests {
    @Test func theGoLineOfAGoModIsRead() {
        #expect(GoModule.goDirective(in: "module example.com/x\n\ngo 1.23\n") == "1.23")
        #expect(GoModule.goDirective(in: "module x\ngo 1.24.1\ntoolchain go1.24.3\n") == "1.24.1")
        #expect(GoModule.goDirective(in: "module x\n// go 1.10\n") == nil)
        #expect(GoModule.goDirective(in: "") == nil)
    }
}

@Suite("Generate: small helpers")
struct GenerateHelperTests {
    @Test func thePackageClauseIsFound() {
        #expect(GenerateContext.packageClause(in: "// Package x.\npackage x_test // c\n\nimport \"a\"\n") == "x_test")
        #expect(GenerateContext.packageClause(in: "") == nil)
    }

    @Test func everyItemHasAnIcon() {
        for id in ["constructor", "options", "accessors", "string", "error-type", "test", "main", "http-handler", "mock", "strategy"] {
            #expect(!GenerateIcons.symbol(forItem: id, group: "").isEmpty)
        }
        #expect(GenerateIcons.symbol(forItem: "singleton", group: "creational") == "plus.square")
    }
}
