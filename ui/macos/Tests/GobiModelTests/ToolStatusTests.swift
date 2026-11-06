import Testing
@testable import GobiModel

@Suite("Tool status")
struct ToolStatusTests {
    private func entry(name: String, required: Bool, found: Bool, version: String = "", installable: Bool = false, hint: String = "") -> [UInt8] {
        var inner = WireWriter()
        inner.string(1, name)
        inner.bool(2, required)
        inner.bool(3, found)
        inner.string(4, version)
        inner.bool(7, installable)
        inner.string(8, hint)
        var outer = WireWriter()
        outer.message(1) { $0 = inner }
        return outer.bytes
    }

    @Test func parsesEveryEntryOfTheReply() throws {
        let fields = try WireField.parse(entry(name: "go", required: true, found: true, version: "go1.26.5") + entry(name: "dlv", required: false, found: false, installable: true))
        let tools = ToolStatus.parse(fields)
        #expect(tools.map(\.name) == ["go", "dlv"])
        #expect(tools[0].found && tools[0].required && tools[0].version == "go1.26.5")
        #expect(!tools[1].found && tools[1].installable)
    }

    @Test func missingRequiredToolsAreReportedFirst() {
        let tools = [ToolStatus(name: "dlv", required: false, found: false), ToolStatus(name: "gopls", required: true, found: false), ToolStatus(name: "go", required: true, found: true)]
        #expect(ToolStatus.missing(tools).map(\.name) == ["gopls", "dlv"])
        #expect(ToolStatus.needsAttention(tools))
        #expect(!ToolStatus.needsAttention([ToolStatus(name: "go", required: true, found: true), ToolStatus(name: "dlv", required: false, found: false)]))
    }

    @Test func installAllLeavesOutWhatCannotBeInstalled() {
        let tools = [ToolStatus(name: "gopls", required: true, found: false, installable: true), ToolStatus(name: "git", required: false, found: false, installable: false), ToolStatus(name: "go", required: true, found: true)]
        #expect(ToolStatus.installable(tools).map(\.name) == ["gopls"])
    }
}
