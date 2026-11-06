import Testing
@testable import GobiModel

struct SaveGuardTests {
    @Test func anAutomaticSaveNeedsADirtyBufferAndAnUnchangedFile() {
        #expect(SaveGuard.allowed(dirty: true, state: .same, userInitiated: false, conflictPending: false))
        #expect(!SaveGuard.allowed(dirty: false, state: .same, userInitiated: false, conflictPending: false))
        #expect(!SaveGuard.allowed(dirty: true, state: .changed, userInitiated: false, conflictPending: false))
        #expect(!SaveGuard.allowed(dirty: true, state: .deleted, userInitiated: false, conflictPending: false))
    }

    @Test func anAutomaticSaveWaitsForTheConflictNoticeToBeAnswered() {
        #expect(!SaveGuard.allowed(dirty: true, state: .same, userInitiated: false, conflictPending: true))
    }

    @Test func gitRequestsThatRewriteFilesAreNamed() {
        for request in [GitRequest.discard(["a"]), .reset(mode: "hard", target: ""), .stash(""), .unstash, .merge("x"), .pull, .checkout("x", create: false), .rebase("x"), .abortMerge, .applyPatch("p")] {
            #expect(request.changesWorkingTree, "\(request)")
        }
        for request in [GitRequest.status, .stage(["a"]), .commit("m"), .push, .fetch, .log(5), .remotes] {
            #expect(!request.changesWorkingTree, "\(request)")
        }
    }

    @Test func anExplicitSaveAlwaysWrites() {
        for state in [DiskState.same, .changed, .deleted] {
            #expect(SaveGuard.allowed(dirty: true, state: state, userInitiated: true, conflictPending: true))
        }
    }
}
