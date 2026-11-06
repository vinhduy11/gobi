import Testing
@testable import GobiModel

@Suite("Code lens")
struct CodeLensTests {
    private let source = """
    package main

    func countUses() int { return 1 }

    type Speaker interface {
    \tSpeak() string
    \tName() string
    }

    type Dog struct{}

    func (d *Dog) Speak() string { return "woof" }

    func TestDog(t *testing.T) {}
    """

    @Test func findsTopLevelDeclarationsAndInterfaceMethods() {
        let found = CodeLens.declarations(in: source)
        #expect(found.map(\.qualifiedName) == ["countUses", "Speaker", "Speaker.Speak", "Speaker.Name", "Dog", "Dog.Speak", "TestDog"])
        #expect(found.map(\.kind) == [.function, .interface, .interfaceMethod, .interfaceMethod, .type, .method, .test])
    }

    @Test func positionsPointAtTheName() {
        let found = CodeLens.declarations(in: source)
        #expect(found[0].position == LSPPosition(line: 2, character: 5))
        #expect(found[1].position == LSPPosition(line: 4, character: 5))
        #expect(found[2].position == LSPPosition(line: 5, character: 1))
        #expect(found[5].position == LSPPosition(line: 11, character: 14))
    }

    @Test func plainLinesAndStructFieldsAreNotDeclarations() {
        let text = "package a\n\nvar x = 1\ntype S struct {\n\tName() string\n}\n\t// func hidden() {}\n"
        #expect(CodeLens.declarations(in: text).map(\.qualifiedName) == ["S"])
    }

    @Test func atMostTheCapIsReturned() {
        let text = (0 ..< 300).map { "func f\($0)() {}" }.joined(separator: "\n")
        #expect(CodeLens.declarations(in: text).count == CodeLens.maximumPerFile)
        #expect(CodeLens.maximumPerFile == 200)
    }

    @Test func referencesAreCountedAndPluralised() {
        let plain = CodeLens.declarations(in: source)[0]
        #expect(CodeLens.segments(for: plain, references: 3, implementations: nil).map(\.text) == ["3 references"])
        #expect(CodeLens.segments(for: plain, references: 1, implementations: nil).map(\.text) == ["1 reference"])
        #expect(CodeLens.segments(for: plain, references: 0, implementations: nil).map(\.text) == ["0 references"])
    }

    @Test func onlyInterfacesGetImplementations() {
        let found = CodeLens.declarations(in: source)
        let segments = CodeLens.segments(for: found[2], references: 2, implementations: 1)
        #expect(segments.map(\.text) == ["2 references", "1 implementation"])
        #expect(segments.map(\.action) == [.references, .implementations])
        #expect(CodeLens.segments(for: found[0], references: 2, implementations: 1).map(\.text) == ["2 references"])
        #expect(CodeLens.segments(for: found[1], references: 0, implementations: 2).map(\.text) == ["0 references", "2 implementations"])
    }

    @Test func nothingIsShownUntilTheCountsArrive() {
        let plain = CodeLens.declarations(in: source)[0]
        #expect(CodeLens.segments(for: plain, references: nil, implementations: nil).isEmpty)
    }

    @Test func testsOfferRunTestAtOnce() {
        let test = CodeLens.declarations(in: source)[6]
        let segments = CodeLens.segments(for: test, references: nil, implementations: nil)
        #expect(segments.map(\.text) == ["run test"])
        #expect(segments.map(\.action) == [.runTest])
    }

    @Test func cacheIsKeyedByNameAndVersion() {
        var cache = LensCache()
        cache.store(name: "countUses", version: 4, references: 3, implementations: nil)
        #expect(cache.counts(name: "countUses", version: 4)?.references == 3)
        #expect(cache.counts(name: "countUses", version: 5) == nil)
        #expect(cache.counts(name: "other", version: 4) == nil)
        cache.store(name: "other", version: 5, references: 1, implementations: nil)
        #expect(cache.counts(name: "countUses", version: 4) == nil)   // older versions are dropped
    }

    @Test func settingIsOnByDefaultAndStored() {
        var settings = EditorSettings()
        #expect(settings.showCodeLens)
        settings.showCodeLens = false
        #expect(EditorSettings.decodeOrDefault(settings.encoded()).showCodeLens == false)
        #expect(EditorSettings.decodeOrDefault("fontSize=13").showCodeLens)
    }
}
