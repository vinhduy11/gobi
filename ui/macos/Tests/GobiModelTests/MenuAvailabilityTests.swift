import Testing
@testable import GobiModel

@Suite("Which menu items are enabled")
struct MenuAvailabilityTests {
    private func enabled(_ action: String, _ change: (inout MenuContext) -> Void = { _ in }) -> Bool {
        var context = MenuContext()
        context.hasProject = true
        context.isTrusted = true
        context.isRepository = true
        change(&context)
        return MenuAvailability.isEnabled(action, in: context) ?? true
    }

    @Test func gitItemsNeedARepository() {
        for action in ["gitPush", "gitPull", "gitFetch", "gitBranches", "gitNewTag", "gitResetHead", "gitWorktrees", "gitManageRemotes", "gitShowLog"] {
            #expect(enabled(action), "\(action)")
            #expect(!enabled(action) { $0.isRepository = false }, "\(action) without a repository")
        }
        #expect(!enabled("gitPush") { $0.isTrusted = false })
        #expect(enabled("gitClone") { $0.hasProject = false } == true)
    }

    @Test func commitAndStashNeedChanges() {
        #expect(!enabled("gitCommit") && !enabled("gitStash") && !enabled("gitRollBackAll") && !enabled("gitCreatePatch"))
        #expect(enabled("gitCommit") { $0.changedCount = 2 } && enabled("gitStash") { $0.changedCount = 2 })
        #expect(enabled("gitUnstash"))
    }

    @Test func operationItemsFollowTheOperationInProgress() {
        #expect(!enabled("gitAbortMerge") && !enabled("gitContinueRebase") && !enabled("gitAbortRevert") && !enabled("gitAbortCherryPick"))
        #expect(enabled("gitAbortMerge") { $0.operation = .merge })
        for action in ["gitAbortRebase", "gitContinueRebase", "gitSkipCommit"] {
            #expect(enabled(action) { $0.operation = .rebase } && !enabled(action) { $0.operation = .merge }, "\(action)")
        }
        #expect(enabled("gitContinueRevert") { $0.operation = .revert } && enabled("gitAbortRevert") { $0.operation = .revert })
        #expect(enabled("gitContinueCherryPick") { $0.operation = .cherryPick } && !enabled("gitContinueRevert") { $0.operation = .cherryPick })
    }

    @Test func mergeAndRebaseNeedAnotherBranchAndNothingInProgress() {
        #expect(!enabled("gitMerge") && !enabled("gitRebase"))
        #expect(enabled("gitMerge") { $0.branchCount = 2 } && enabled("gitRebase") { $0.branchCount = 2 })
        #expect(!enabled("gitMerge") { $0.branchCount = 2; $0.operation = .rebase })
    }

    @Test func resolveConflictsNeedsConflicts() {
        #expect(!enabled("gitResolveConflicts"))
        #expect(enabled("gitResolveConflicts") { $0.conflictCount = 1 })
    }

    @Test func currentFileItemsNeedAChangedOpenFile() {
        #expect(!enabled("gitFileDiff") && !enabled("gitFileStage") && !enabled("gitFileRollBack"))
        #expect(enabled("gitFileDiff") { $0.hasEditor = true; $0.currentFileChanged = true })
        #expect(!enabled("gitFileDiff") { $0.currentFileChanged = true })
    }

    @Test func runItemsFollowTheRunAndTheDebugger() {
        #expect(!enabled("stop"))
        #expect(enabled("stop") { $0.isRunning = true } && enabled("stop") { $0.debugActive = true })
        #expect(!enabled("evaluateExpression") && enabled("evaluateExpression") { $0.debugPaused = true })
        #expect(enabled("buildProject") && !enabled("buildProject") { $0.isTrusted = false } && !enabled("rebuildProject") { $0.hasProject = false })
    }

    @Test func editorItemsNeedAnEditorAndWindowItemsNeedWindows() {
        for action in ["sortLines", "reverseLines", "pastePlain"] {
            #expect(!enabled(action) && enabled(action) { $0.hasEditor = true }, "\(action)")
        }
        #expect(enabled("copyPath") && !enabled("copyPath") { $0.hasProject = false })
        #expect(!enabled("nextProjectWindow") && enabled("nextProjectWindow") { $0.projectWindowCount = 2 })
        #expect(enabled("newWindow") { $0.hasProject = false })
    }

    @Test func actionsWithoutARuleAreLeftToTheCaller() {
        #expect(MenuAvailability.isEnabled("save", in: MenuContext()) == nil)
    }
}
