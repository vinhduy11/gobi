import Testing
@testable import GobiModel

@Suite("Git status")
struct GitStatusTests {
    @Test func requestAndReplyUseTheChannelLayout() throws {
        #expect(GitWire.request(.status) == [0x08, 0x01])
        var writer = WireWriter()
        writer.uint(1, 1)
        writer.string(2, "main")
        writer.string(3, "13src/a.go")
        writer.string(3, "50new dir/b.go")
        writer.uint(5, 1)
        writer.uint(6, 2)
        guard case .status(let status) = try GitWire.parse(writer.bytes) else { Issue.record("not a status reply"); return }
        #expect(status == GitStatus(branch: "main", files: [GitFile(path: "src/a.go", mark: .modified, staged: true, unstaged: true), GitFile(path: "new dir/b.go", mark: .untracked)], ahead: 1, behind: 2))
    }

    @Test func anErrorReplyGivesAnEmptyStatus() throws {
        var writer = WireWriter()
        writer.uint(1, 2)
        writer.string(4, "boom")
        #expect(try GitWire.parse(writer.bytes) == .failure("boom"))
    }

    @Test func aFileTakesItsOwnMark() {
        let status = GitStatus(branch: "main", files: [GitFile(path: "a.go", mark: .modified), GitFile(path: "b.go", mark: .added)])
        #expect(status.mark(of: "a.go", isDirectory: false) == .modified)
        #expect(status.mark(of: "b.go", isDirectory: false) == .added)
        #expect(status.mark(of: "c.go", isDirectory: false) == nil)
    }

    @Test func aWholeUntrackedOrIgnoredFolderMarksEverythingInsideIt() {
        let status = GitStatus(branch: "main", files: [GitFile(path: "tmp/", mark: .untracked), GitFile(path: "out/", mark: .ignored)])
        #expect(status.mark(of: "tmp", isDirectory: true) == .untracked)
        #expect(status.mark(of: "tmp/deep/x.go", isDirectory: false) == .untracked)
        #expect(status.mark(of: "out/x.bin", isDirectory: false) == .ignored)
        #expect(status.mark(of: "tmpx/x.go", isDirectory: false) == nil)
    }

    @Test func aFolderIsModifiedWhenSomethingInsideIsChangedButNotWhenOnlyIgnored() {
        let status = GitStatus(branch: "main", files: [GitFile(path: "pkg/a.go", mark: .modified), GitFile(path: "gen/x.go", mark: .ignored)])
        #expect(status.mark(of: "pkg", isDirectory: true) == .modified)
        #expect(status.mark(of: "gen", isDirectory: true) == nil)
        #expect(status.mark(of: "pk", isDirectory: true) == nil)
    }
}


@Suite("Git replies and diffs")
struct GitRepliesTests {
    @Test func requestsCarryTheirArguments() {
        var w = WireWriter()
        w.uint(1, 2); w.string(5, "a.go"); w.bool(7, true)
        #expect(GitWire.request(.diff(path: "a.go", staged: true)) == w.bytes)
        var s = WireWriter()
        s.uint(1, 5); s.string(6, "a.go"); s.string(6, "b.go")
        #expect(GitWire.request(.stage(["a.go", "b.go"])) == s.bytes)
        var c = WireWriter()
        c.uint(1, 4); c.string(5, "topic"); c.bool(7, true)
        #expect(GitWire.request(.checkout("topic", create: true)) == c.bytes)
        var l = WireWriter()
        l.uint(1, 8); l.uint(8, 20)
        #expect(GitWire.request(.log(20)) == l.bytes)
        var d = WireWriter()
        d.uint(1, 10); d.string(6, "a.go")
        #expect(GitWire.request(.discard(["a.go"])) == d.bytes)
        var push = WireWriter(); push.uint(1, 11)
        #expect(GitWire.request(.push) == push.bytes)
        var pull = WireWriter(); pull.uint(1, 12)
        #expect(GitWire.request(.pull) == pull.bytes)
        var merge = WireWriter(); merge.uint(1, 13); merge.string(5, "topic")
        #expect(GitWire.request(.merge("topic")) == merge.bytes)
        var fetch = WireWriter(); fetch.uint(1, 14)
        #expect(GitWire.request(.fetch) == fetch.bytes)
    }

    @Test func eachReplyKindIsRead() throws {
        var text = WireWriter(); text.uint(1, 3); text.string(8, "diff --git")
        #expect(try GitWire.parse(text.bytes) == .text("diff --git"))
        var branches = WireWriter(); branches.uint(1, 4); branches.string(3, "0main"); branches.string(3, "1topic")
        #expect(try GitWire.parse(branches.bytes) == .branches([GitBranch(name: "main", isCurrent: false), GitBranch(name: "topic", isCurrent: true)]))
        var log = WireWriter(); log.uint(1, 5); log.string(3, "abc\u{1F}Duy\u{1F}2 hours ago\u{1F}Shut down")
        #expect(try GitWire.parse(log.bytes) == .log([GitCommit(hash: "abc", author: "Duy", when: "2 hours ago", subject: "Shut down")]))
        var lines = WireWriter(); lines.uint(1, 6); lines.string(3, "1 5 2"); lines.string(3, "3 9 0")
        #expect(try GitWire.parse(lines.bytes) == .lines([GitLineChange(start: 5, count: 2, kind: .added), GitLineChange(start: 9, count: 0, kind: .deleted)]))
        var done = WireWriter(); done.uint(1, 7)
        #expect(try GitWire.parse(done.bytes) == .done)
    }

    @Test func gutterKindsPerLine() {
        let changes = [GitLineChange(start: 2, count: 2, kind: .modified), GitLineChange(start: 7, count: 1, kind: .added), GitLineChange(start: 4, count: 0, kind: .deleted)]
        let marks = GitLineChange.marks(for: changes)
        #expect(marks.added == [7] && marks.modified == [2, 3] && marks.deletedAfter == [4])
    }

    @Test func diffLinesAreClassified() {
        let text = "diff --git a/a.go b/a.go\nindex 1..2 100644\n--- a/a.go\n+++ b/a.go\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
        let kinds = DiffLine.parse(text).map(\.kind)
        #expect(kinds == [.header, .header, .header, .header, .hunk, .context, .removed, .added])
        #expect(DiffLine.parse(text)[6].text == "-two")
        #expect(DiffLine.parse("").isEmpty)
    }

    @Test func changedFilesAreGroupedIntoStagedAndChanges() {
        let status = GitStatus(branch: "main", files: [
            GitFile(path: "a.go", mark: .modified, staged: true, unstaged: false), GitFile(path: "b.go", mark: .modified, staged: true, unstaged: true),
            GitFile(path: "c.go", mark: .untracked), GitFile(path: "d.go", mark: .modified, staged: false, unstaged: true), GitFile(path: "gen/", mark: .ignored),
        ], ahead: 0, behind: 0)
        #expect(status.stagedFiles.map(\.path) == ["a.go", "b.go"])
        #expect(status.unstagedFiles.map(\.path) == ["b.go", "c.go", "d.go"])
        #expect(status.changedFiles.map(\.path) == ["a.go", "b.go", "c.go", "d.go"])
    }

    @Test func badgeLettersMatchTheMock() {
        #expect(GitMark.modified.badge == "M" && GitMark.added.badge == "A" && GitMark.deleted.badge == "D" && GitMark.untracked.badge == "?" && GitMark.renamed.badge == "R" && GitMark.conflict.badge == "!")
    }
}
