import Testing
@testable import GobiModel

@Suite("go.mod facts")
struct GoModTests {
    @Test func moduleAndGoVersionAreRead() {
        let facts = GoModFacts.parse("module example.com/hello\n\ngo 1.26\n\nrequire x v1.0.0\n")
        #expect(facts.module == "example.com/hello" && facts.goVersion == "1.26")
    }

    @Test func aQuotedModulePathAndCommentsAreHandled() {
        let facts = GoModFacts.parse("// header\nmodule \"example.com/q\" // trailing\ngo 1.22.3\ntoolchain go1.23.1\n")
        #expect(facts.module == "example.com/q" && facts.goVersion == "1.22.3" && facts.toolchain == "go1.23.1")
    }

    @Test func missingLinesGiveEmptyValues() {
        let facts = GoModFacts.parse("")
        #expect(facts.module.isEmpty && facts.goVersion.isEmpty && facts.toolchain.isEmpty)
    }

    @Test func theModuleNameShownIsTheLastPathPart() {
        #expect(GoModFacts.parse("module example.com/acme/hello\n").shortName == "hello")
        #expect(GoModFacts.parse("module hello\n").shortName == "hello")
    }

    @Test func requireBlocksDoNotConfuseTheParser() {
        let facts = GoModFacts.parse("module m\n\nrequire (\n\tgo.example/x v1\n)\n\ngo 1.21\n")
        #expect(facts.module == "m" && facts.goVersion == "1.21")
    }
}

@Suite("Toolbar text")
struct ToolbarTextTests {
    @Test func theRunTargetNamesTheProjectAndTheCommand() {
        #expect(ToolbarText.runTarget(project: "hello", package: "./cmd/hello") == "hello › go run ./cmd/hello")
        #expect(ToolbarText.runTarget(project: "hello", package: ".") == "hello › go run .")
        #expect(ToolbarText.runTarget(project: "hello", package: nil) == "hello")
    }

    @Test func theStatusJoinsGoplsGoAndThePlatform() {
        #expect(ToolbarText.status(goplsReady: true, goVersion: "1.26.5", platform: "darwin/arm64") == "gopls ready · Go 1.26.5 · darwin/arm64")
        #expect(ToolbarText.status(goplsReady: false, goVersion: "1.26.5", platform: "darwin/arm64") == "gopls starting… · Go 1.26.5 · darwin/arm64")
        #expect(ToolbarText.status(goplsReady: true, goVersion: nil, platform: "darwin/arm64") == "gopls ready · darwin/arm64")
    }

    @Test func thePlatformIsGoStyle() {
        #expect(ToolbarText.platform(system: "Darwin", machine: "arm64") == "darwin/arm64")
        #expect(ToolbarText.platform(system: "Darwin", machine: "x86_64") == "darwin/amd64")
        #expect(ToolbarText.platform(system: "Linux", machine: "aarch64") == "linux/arm64")
    }
}
