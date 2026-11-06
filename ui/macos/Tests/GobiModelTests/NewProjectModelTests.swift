import Testing
@testable import GobiModel

@Suite("New Project dialog model")
struct NewProjectModelTests {
    @Test func theOfflineCatalogFollowsTheMock() {
        let all = TemplateCatalog.fallback
        #expect(all.map(\.title) == ["Command-line tool", "Library", "HTTP service", "gRPC service", "Message consumer", "Scheduled job", "go.work (multi-module)", "Empty module", "Custom templates…"])
        #expect(all.map(\.group) == ["Go module", "Go module", "Service", "Service", "Service", "Service", "Workspace", "Other", "Other"])
    }

    @Test func templatesTheCoreCannotBuildYetAreMarkedUnavailable() {
        let unavailable = TemplateCatalog.fallback.filter { !$0.isAvailable }.map(\.title)
        #expect(unavailable == ["gRPC service", "Custom templates…"])
    }

    @Test func everyTemplateHasAnIdAndASummary() {
        for template in TemplateCatalog.fallback {
            #expect(!template.id.isEmpty)
            #expect(!template.summary.isEmpty)
        }
        #expect(TemplateCatalog.fallback.first?.summary == "A main package with a test, ready to run.")
    }

    private func entry(_ id: String, _ order: UInt64, _ group: String, _ title: String, _ summary: String, _ available: Bool) -> [UInt8] {
        var inner = WireWriter()
        inner.string(1, id); inner.uint(2, order); inner.string(3, group); inner.string(4, title); inner.string(5, summary); inner.bool(6, available)
        var outer = WireWriter()
        outer.message(1) { $0 = inner }
        return outer.bytes
    }

    @Test func decodesTheCatalogueFromCoreInOrder() throws {
        // The second entry arrives first: the order field decides, not the arrival order.
        let bytes = entry("job", 2, "Service", "Scheduled job", "Runs on a timer.", true) + entry("grpc", 1, "Service", "gRPC service", "Soon.", false)
        let templates = ProjectTemplate.parse(try WireField.parse(bytes))
        #expect(templates == [
            ProjectTemplate(id: "grpc", title: "gRPC service", group: "Service", summary: "Soon.", isAvailable: false),
            ProjectTemplate(id: "job", title: "Scheduled job", group: "Service", summary: "Runs on a timer.", isAvailable: true),
        ])
    }

    @Test func goldenBytesOfOneEntryMatchTheGoCodec() throws {
        // Same bytes as TestTemplateEntryGoldenBytes in core/internal/daemon, wrapped as field 1 of the result.
        let inner: [UInt8] = [0x0a, 0x03, 0x6a, 0x6f, 0x62, 0x10, 0x02, 0x1a, 0x07, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x22, 0x01, 0x54, 0x2a, 0x01, 0x53, 0x30, 0x01]
        let templates = ProjectTemplate.parse(try WireField.parse([0x0a, UInt8(inner.count)] + inner))
        #expect(templates == [ProjectTemplate(id: "job", title: "T", group: "Service", summary: "S", isAvailable: true)])
    }

    @Test func anEmptyCatalogueFromCoreKeepsTheOfflineList() {
        TemplateCatalog.use([])
        #expect(TemplateCatalog.all == TemplateCatalog.fallback)
    }

    @Test func moduleSuggestionUsesTheNameAndIsEmptyWithoutOne() {
        #expect(ProjectForm.suggestedModulePath(forName: "hello") == "example.com/hello")
        #expect(ProjectForm.suggestedModulePath(forName: "") == "")
    }

    @Test func theCommandLineIsExplained() {
        #expect(ProjectForm.commandSummary(modulePath: "example.com/hello") == "Runs go mod init example.com/hello with the selected toolchain.")
        #expect(ProjectForm.commandSummary(modulePath: "") == "Runs go mod init with the project name as the module path.")
    }

    @Test func theWillCreateTreeNestsFoldersAndSortsFoldersFirst() {
        let lines = PreviewTree.lines(root: "hello", files: ["go.mod", "app/main.go", "app/go.mod", "README.md", "go.work"])
        #expect(lines == ["hello/", "  app/", "    go.mod", "    main.go", "  go.mod", "  go.work", "  README.md"])
    }

    @Test func aFlatProjectListsItsFilesUnderTheRoot() {
        #expect(PreviewTree.lines(root: "x", files: ["main.go", "go.mod"]) == ["x/", "  go.mod", "  main.go"])
        #expect(PreviewTree.lines(root: "x", files: []) == ["x/"])
    }
}
