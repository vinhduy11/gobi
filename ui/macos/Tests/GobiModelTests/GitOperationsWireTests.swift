import Testing
@testable import GobiModel

@Suite("Git operations on the wire")
struct GitOperationsWireTests {
    private func bytes(_ kind: UInt64, text: String? = nil, text2: String? = nil, flag: Bool = false) -> [UInt8] {
        var w = WireWriter()
        w.uint(1, kind)
        if let text { w.string(5, text) }
        if flag { w.bool(7, true) }
        if let text2 { w.string(9, text2) }
        return w.bytes
    }

    @Test func eachRequestUsesItsKindAndFields() {
        #expect(GitWire.request(.tag("v1")) == bytes(15, text: "v1"))
        #expect(GitWire.request(.reset(mode: "hard", target: "HEAD~1")) == bytes(16, text: "hard", text2: "HEAD~1"))
        #expect(GitWire.request(.stash("wip")) == bytes(17, text: "wip"))
        #expect(GitWire.request(.unstash) == bytes(18))
        #expect(GitWire.request(.abortMerge) == bytes(19))
        #expect(GitWire.request(.rebase("main")) == bytes(20, text: "main"))
        #expect(GitWire.request(.abortRebase) == bytes(21))
        #expect(GitWire.request(.continueRebase) == bytes(22))
        #expect(GitWire.request(.skipRebase) == bytes(23))
        #expect(GitWire.request(.patch) == bytes(24))
        #expect(GitWire.request(.applyPatch("/x/a.patch")) == bytes(25, text: "/x/a.patch"))
        #expect(GitWire.request(.continueRevert) == bytes(26))
        #expect(GitWire.request(.abortRevert) == bytes(27))
        #expect(GitWire.request(.continueCherryPick) == bytes(28))
        #expect(GitWire.request(.abortCherryPick) == bytes(29))
        #expect(GitWire.request(.remotes) == bytes(30))
        #expect(GitWire.request(.addRemote(name: "origin", url: "u")) == bytes(31, text: "origin", text2: "u"))
        #expect(GitWire.request(.removeRemote("origin")) == bytes(32, text: "origin"))
        #expect(GitWire.request(.worktrees) == bytes(33))
        #expect(GitWire.request(.addWorktree(path: "/w", branch: "b", create: true)) == bytes(34, text: "/w", text2: "b", flag: true))
        #expect(GitWire.request(.removeWorktree("/w")) == bytes(35, text: "/w"))
    }

    @Test func aListReplyCarriesItsEntries() throws {
        var w = WireWriter()
        w.uint(1, 8)
        w.string(3, "origin\u{1F}https://example.test/x.git")
        #expect(try GitWire.parse(w.bytes) == .list(["origin\u{1F}https://example.test/x.git"]))
    }

    @Test func statusCarriesTheOperationInProgress() throws {
        var w = WireWriter()
        w.uint(1, 1); w.string(2, "main"); w.string(7, "rebase")
        guard case .status(let status) = try GitWire.parse(w.bytes) else { Issue.record("not a status"); return }
        #expect(status.operation == .rebase)
        var none = WireWriter()
        none.uint(1, 1); none.string(2, "main")
        guard case .status(let plain) = try GitWire.parse(none.bytes) else { Issue.record("not a status"); return }
        #expect(plain.operation == nil)
        #expect(GitOperation(rawValue: "cherry-pick") == .cherryPick)
    }

    @Test func remotesAndWorktreesAreReadFromEntries() {
        #expect(GitRemote.parse(["origin\u{1F}u1", "bad"]) == [GitRemote(name: "origin", url: "u1")])
        let trees = GitWorktree.parse(["/a\u{1F}main\u{1F}abcdef1234", "/b\u{1F}\u{1F}1234567890"])
        #expect(trees == [GitWorktree(path: "/a", branch: "main", head: "abcdef1234"), GitWorktree(path: "/b", branch: "", head: "1234567890")])
        #expect(trees[1].title == "/b (detached 1234567)" && trees[0].title == "/a (main)")
    }

    @Test func conflictedFilesAreListedFromStatus() {
        let status = GitStatus(branch: "main", files: [GitFile(path: "a.go", mark: .conflict), GitFile(path: "b.go", mark: .modified), GitFile(path: "c.go", mark: .conflict)])
        #expect(status.conflictedFiles.map(\.path) == ["a.go", "c.go"])
    }
}
