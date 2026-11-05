import Testing
@testable import GobiModel

@Suite("New Project dialog model")
struct NewProjectModelTests {
    @Test func theCatalogFollowsTheMock() {
        let titles = TemplateCatalog.all.map(\.title)
        #expect(titles == ["Command-line tool", "Library", "HTTP service", "gRPC service", "Workspace go.work (multi-module)", "Empty module", "Custom templates…"])
        #expect(TemplateCatalog.all.prefix(5).allSatisfy { $0.group == "Go module" })
        #expect(TemplateCatalog.all.suffix(2).allSatisfy { $0.group == "Other" })
    }

    @Test func templatesTheCoreCannotBuildYetAreMarkedUnavailable() {
        let unavailable = TemplateCatalog.all.filter { !$0.isAvailable }.map(\.title)
        #expect(unavailable == ["gRPC service", "Custom templates…"])
    }

    @Test func everyAvailableTemplateHasACoreIdAndASummary() {
        for template in TemplateCatalog.all where template.isAvailable {
            #expect(!template.coreID.isEmpty)
            #expect(!template.summary.isEmpty)
        }
        #expect(TemplateCatalog.all.first?.summary == "A main package with a test, ready to run.")
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
