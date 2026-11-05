import Testing
@testable import GobiModel

@Suite("File kinds for the explorer icons")
struct FileKindTests {
    @Test(arguments: [
        ("main.go", FileKind.goSource), ("main_test.go", .goTest), ("go.mod", .goMod), ("go.sum", .goSum), ("go.work", .goWork), ("go.work.sum", .goSum),
        ("README.md", .markdown), ("notes.markdown", .markdown), ("ci.yml", .yaml), ("ci.yaml", .yaml), (".gitlab-ci.yml", .yaml),
        (".mcp.json", .json), ("package.json", .json), ("config.toml", .toml), ("Makefile", .makefile), ("GNUmakefile", .makefile),
        (".gitignore", .git), (".gitattributes", .git), (".env", .env), (".env.example", .env), (".env.local", .env),
        ("run.sh", .shell), ("Dockerfile", .docker), ("api.proto", .proto), ("query.sql", .sql), ("logo.png", .image), ("icon.SVG", .image),
        ("LICENSE", .text), ("notes.txt", .text), (".ai-init", .generic), ("data.bin", .generic),
    ])
    func filesAreClassifiedByName(name: String, expected: FileKind) {
        #expect(FileKind.classify(name: name, isDirectory: false) == expected)
    }

    @Test func foldersAreFolders() {
        #expect(FileKind.classify(name: "cmd", isDirectory: true) == .folder)
        #expect(FileKind.classify(name: "go.mod", isDirectory: true) == .folder)
        #expect(FileKind.classify(name: ".git", isDirectory: true) == .folder)
    }

    @Test func everyKindHasABadgeLabelOrASymbol() {
        for kind in FileKind.allCases {
            let look = kind.look
            #expect(!look.badge.isEmpty || !look.symbol.isEmpty, "\(kind)")
        }
    }

    @Test func goFilesAreEasyToTellApartFromOtherFiles() {
        #expect(FileKind.goSource.look.badge == "GO")
        #expect(FileKind.goTest.look.badge == "GO")
        #expect(FileKind.goSource.look.color != FileKind.goTest.look.color)
        #expect(FileKind.goMod.look.color != FileKind.goSource.look.color)
    }
}
