import Testing
@testable import GobiModel

@Suite("Commit tool window model")
struct CommitPanelTests {
    // MARK: commit button

    @Test func commitNeedsAMessageAndSomethingToCommit() {
        #expect(CommitButtonState(message: "fix", hasChanges: true, amend: false, warnLongSubject: true).enabled)
        #expect(!CommitButtonState(message: "  \n", hasChanges: true, amend: false, warnLongSubject: true).enabled)
        #expect(!CommitButtonState(message: "fix", hasChanges: false, amend: false, warnLongSubject: true).enabled)
        // amending only rewords the last commit, so it needs no changes
        #expect(CommitButtonState(message: "fix", hasChanges: false, amend: true, warnLongSubject: true).enabled)
    }

    @Test func longSubjectWarningFollowsTheSetting() {
        let long = String(repeating: "x", count: 60)
        #expect(CommitButtonState(message: long, hasChanges: true, amend: false, warnLongSubject: true).warning != nil)
        #expect(CommitButtonState(message: long, hasChanges: true, amend: false, warnLongSubject: false).warning == nil)
        #expect(CommitButtonState(message: "short", hasChanges: true, amend: false, warnLongSubject: true).warning == nil)
    }

    @Test func amendPrefillsOnlyAnEmptyMessage() {
        let last = GitCommit(hash: "abcdef0123", author: "t", when: "now", subject: "previous")
        #expect(CommitButtonState.amendPrefill(message: "", last: last) == "previous")
        #expect(CommitButtonState.amendPrefill(message: " \n", last: last) == "previous")
        #expect(CommitButtonState.amendPrefill(message: "mine", last: last) == nil)
        #expect(CommitButtonState.amendPrefill(message: "", last: nil) == nil)
    }

    // MARK: changes tree

    private let files = [
        GitFile(path: "cart/cart.go", mark: .modified, staged: false, unstaged: true),
        GitFile(path: "main.go", mark: .modified, staged: true, unstaged: false),
        GitFile(path: "notes.txt", mark: .untracked, staged: false, unstaged: true),
        GitFile(path: "gone.go", mark: .deleted, staged: true, unstaged: false),
        GitFile(path: "vendor_cache/", mark: .ignored),
    ]

    @Test func filesFallIntoChangesAndUnversioned() {
        let tree = ChangesTree(files: files)
        #expect(tree.sections.map(\.title) == ["Changes", "Unversioned Files"])
        #expect(tree.sections[0].files.map(\.path) == ["cart/cart.go", "main.go", "gone.go"])
        #expect(tree.sections[1].files.map(\.path) == ["notes.txt"])
        #expect(tree.sections[0].countText == "3 files" && tree.sections[1].countText == "1 file")
        #expect(!tree.isEmpty)
    }

    @Test func noChangesIsEmptyAndHasNoSections() {
        let tree = ChangesTree(files: [GitFile(path: "x/", mark: .ignored)])
        #expect(tree.isEmpty && tree.sections.isEmpty && tree.rows.isEmpty)
        #expect(ChangesTree.emptyText == "No local changes")
    }

    @Test func checkedMeansStagedAndGroupsSummariseTheirFiles() {
        let tree = ChangesTree(files: files)
        #expect(tree.sections[0].checkState == .mixed)
        #expect(tree.sections[1].checkState == .unchecked)
        let all = ChangesTree(files: [GitFile(path: "a", mark: .added, staged: true)])
        #expect(all.sections[0].checkState == .checked)
    }

    @Test func togglingAGroupStagesTheRestOrUnstagesAll() {
        let tree = ChangesTree(files: files)
        #expect(tree.sections[0].toggle() == ChangesTree.Toggle(stage: ["cart/cart.go"], unstage: []))
        let all = ChangesTree(files: [GitFile(path: "a", mark: .added, staged: true), GitFile(path: "b", mark: .modified, staged: true)])
        #expect(all.sections[0].toggle() == ChangesTree.Toggle(stage: [], unstage: ["a", "b"]))
        #expect(ChangesTree.toggle(file: files[0]) == ChangesTree.Toggle(stage: ["cart/cart.go"], unstage: []))
        #expect(ChangesTree.toggle(file: files[1]) == ChangesTree.Toggle(stage: [], unstage: ["main.go"]))
    }

    @Test func collapsedSectionsHideTheirFilesAndExpandAllShowsThem() {
        var tree = ChangesTree(files: files)
        #expect(tree.rows.count == 2 + 4)
        tree.collapseAll()
        #expect(tree.rows.count == 2)
        tree.toggleCollapsed(.unversioned)
        #expect(tree.rows.count == 3)
        tree.expandAll()
        #expect(tree.rows.count == 6)
        // collapse state survives a new status
        tree.collapseAll()
        let again = tree.updated(files: files)
        #expect(again.rows.count == 2)
    }

    @Test func rowNamesShowTheFileThenItsFolder() {
        #expect(ChangesTree.nameAndFolder("cart/cart.go") == ("cart.go", "cart"))
        #expect(ChangesTree.nameAndFolder("main.go") == ("main.go", ""))
        #expect(ChangesTree.nameAndFolder("a/b/c.go") == ("c.go", "a/b"))
        #expect(ChangesTree.nameAndFolder("vendor/") == ("vendor/", ""))
    }

    // MARK: stashes

    @Test func stashEntriesAreParsedAndTitled() {
        let entries = StashEntry.parse(["0\u{1F}On main: saved work", "1\u{1F}WIP on main: abc first", "bad", "x\u{1F}no"])
        #expect(entries == [StashEntry(index: 0, message: "On main: saved work"), StashEntry(index: 1, message: "WIP on main: abc first")])
        #expect(entries[0].title == "stash@{0}: On main: saved work")
    }

    @Test func aPartlyStagedFileIsMixedAndIsStagedWholeWhenFlipped() {
        let partly = GitFile(path: "p.go", mark: .modified, staged: true, unstaged: true)
        #expect(ChangesTree.checkState(of: partly) == .mixed)
        #expect(ChangesTree.toggle(file: partly) == ChangesTree.Toggle(stage: ["p.go"], unstage: []))
        #expect(ChangesTree(files: [partly]).sections[0].checkState == .mixed)
    }

    // MARK: wire

    @Test func commitRequestCarriesTheAmendFlag() {
        var plain = WireWriter(); plain.uint(1, 7); plain.string(5, "m")
        #expect(GitWire.request(.commit("m", amend: false)) == plain.bytes)
        #expect(GitWire.request(.commit("m")) == plain.bytes)
        var amend = WireWriter(); amend.uint(1, 7); amend.string(5, "m"); amend.bool(7, true)
        #expect(GitWire.request(.commit("m", amend: true)) == amend.bytes)
    }

    @Test func stashRequestsUseTheirKindsAndIndex() {
        func bytes(_ kind: UInt64, _ index: UInt64? = nil) -> [UInt8] {
            var w = WireWriter(); w.uint(1, kind)
            if let index { w.uint(8, index) }
            return w.bytes
        }
        #expect(GitWire.request(.stashList) == bytes(36))
        #expect(GitWire.request(.stashApply(2)) == bytes(37, 2))
        #expect(GitWire.request(.stashPop(0)) == bytes(38, 0))
        #expect(GitWire.request(.stashDrop(1)) == bytes(39, 1))
        #expect(GitRequest.stashPop(0).changesWorkingTree && GitRequest.stashApply(0).changesWorkingTree && !GitRequest.stashDrop(0).changesWorkingTree)
    }
}
