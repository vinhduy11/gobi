import Testing
@testable import GobiModel

@Suite("Go module and single-file run") struct GoModuleTests {
    @Test func moduleNameFromFolder() {
        #expect(GoModule.moduleName(fromFolder: "test_go") == "test_go")
        #expect(GoModule.moduleName(fromFolder: "My Shop App") == "my-shop-app")
        #expect(GoModule.moduleName(fromFolder: "  Odd!!Name@@ ") == "odd-name")
        #expect(GoModule.moduleName(fromFolder: "...") == "app")
        #expect(GoModule.moduleName(fromFolder: "") == "app")
        #expect(GoModule.moduleName(fromFolder: "api.v2") == "api.v2")
    }

    @Test func goDirectiveIsMajorMinor() {
        #expect(GoModule.majorMinor(of: "1.26.5") == "1.26")
        #expect(GoModule.majorMinor(of: "go1.25.1") == "1.25")
        #expect(GoModule.majorMinor(of: "1.24") == "1.24")
        #expect(GoModule.majorMinor(of: "1.25rc1") == "1.25")
        #expect(GoModule.majorMinor(of: "devel") == nil)
        #expect(GoModule.majorMinor(of: "") == nil)
    }

    @Test func goModText() {
        #expect(GoModule.source(module: "test_go", goVersion: "1.26.5") == "module test_go\n\ngo 1.26\n")
        #expect(GoModule.source(module: "app", goVersion: nil) == "module app\n")
    }

    @Test func lookupFoldersWalkUpToTheRoot() {
        #expect(GoModule.lookupFolders(forDirectory: "") == [""])
        #expect(GoModule.lookupFolders(forDirectory: "a/b") == ["a/b", "a", ""])
    }

    @Test func packageIdentifier() {
        #expect(GoModule.isValidPackageName("pkg"))
        #expect(GoModule.isValidPackageName("my_pkg2"))
        #expect(!GoModule.isValidPackageName(""))
        #expect(!GoModule.isValidPackageName("2pkg"))
        #expect(!GoModule.isValidPackageName("my-pkg"))
        #expect(!GoModule.isValidPackageName("func"))
        #expect(!GoModule.isValidPackageName("a b"))
    }

    @Test func packageLine() {
        #expect(SingleFileRun.packageName(inSource: "package main\n\nfunc main() {}") == "main")
        #expect(SingleFileRun.packageName(inSource: "// c\n/* x */\npackage shop // y\n") == "shop")
        #expect(SingleFileRun.packageName(inSource: "func x() {}") == nil)
    }

    private let files: [SingleFileRun.Sibling] = [
        .init(name: "util.go", package: "main"), .init(name: "main.go", package: "main"), .init(name: "other.go", package: "tools"),
        .init(name: "main_test.go", package: "main"), .init(name: "notes.txt", package: ""),
    ]

    @Test func aFolderWithTwoMainFilesRunsBoth() {
        #expect(SingleFileRun.arguments(currentFile: "main.go", directory: "", siblings: files, includeTests: false) == ["main.go", "util.go"])
        #expect(SingleFileRun.arguments(currentFile: "main.go", directory: "cmd/x", siblings: files, includeTests: false) == ["cmd/x/main.go", "cmd/x/util.go"])
    }

    @Test func aDifferentPackageIsNotRunTogether() {
        #expect(SingleFileRun.arguments(currentFile: "other.go", directory: "", siblings: files, includeTests: false) == ["other.go"])
    }

    @Test func testsIncludeTheTestFilesOfThePackage() {
        #expect(SingleFileRun.arguments(currentFile: "main.go", directory: "", siblings: files, includeTests: true) == ["main.go", "main_test.go", "util.go"])
    }

    @Test func aSingleFileIsTheCommonCase() {
        #expect(SingleFileRun.arguments(currentFile: "test.go", directory: "", siblings: [.init(name: "test.go", package: "main")], includeTests: false) == ["test.go"])
    }

    @Test func theMainFileIsPickedWhenNoMainFileIsOpen() {
        #expect(SingleFileRun.mainFile(current: "other.go", siblings: files) == "main.go")
        #expect(SingleFileRun.mainFile(current: "util.go", siblings: files) == "util.go")
        #expect(SingleFileRun.mainFile(current: nil, siblings: [.init(name: "a.go", package: "x")]) == nil)
    }

    @Test func aTestFilePackageUsesItsBaseName() {
        let siblings: [SingleFileRun.Sibling] = [.init(name: "a.go", package: "shop"), .init(name: "a_test.go", package: "shop_test")]
        #expect(SingleFileRun.arguments(currentFile: "a.go", directory: "", siblings: siblings, includeTests: true) == ["a.go", "a_test.go"])
    }

    @Test func noticeRememberedPerProject() {
        #expect(GoModule.noticeKey(project: "/p/x") == "gobi.noGoModNotice./p/x")
    }
}
