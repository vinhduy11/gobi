// Which of the newer menu items can be used right now. The app fills a `MenuContext` from the front project window and asks
// here by action id; an id with no rule answers nil and the caller decides (older items keep their own checks).

public struct MenuContext: Equatable {
    public var hasProject = false
    public var isTrusted = false
    /// The front project's folder is a git repository.
    public var isRepository = false
    public var hasEditor = false
    /// Changed files (ignored ones left out) and files in conflict.
    public var changedCount = 0
    public var conflictCount = 0
    public var operation: GitOperation?
    public var branchCount = 0
    /// The file open in the editor has a change git knows about.
    public var currentFileChanged = false
    public var debugActive = false
    public var debugPaused = false
    public var isRunning = false
    public var projectWindowCount = 0

    public init() {}
}

public enum MenuAvailability {
    public static func isEnabled(_ action: String, in context: MenuContext) -> Bool? {
        let git = context.hasProject && context.isTrusted && context.isRepository
        let project = context.hasProject && context.isTrusted
        switch action {
        case "gitClone", "newWindow": return true
        case "gitPush", "gitPull", "gitUpdate", "gitFetch", "gitBranches", "gitNewBranch", "gitNewTag", "gitResetHead", "gitNewWorktree", "gitWorktrees",
             "gitShowLog", "gitManageRemotes", "gitApplyPatch", "gitUnstash":
            return git
        case "gitCommit", "gitStash", "gitRollBackAll", "gitCreatePatch": return git && context.changedCount > 0
        case "gitMerge", "gitRebase": return git && context.operation == nil && context.branchCount > 1
        case "gitAbortMerge": return git && context.operation == .merge
        case "gitAbortRebase", "gitContinueRebase", "gitSkipCommit": return git && context.operation == .rebase
        case "gitContinueRevert", "gitAbortRevert": return git && context.operation == .revert
        case "gitContinueCherryPick", "gitAbortCherryPick": return git && context.operation == .cherryPick
        case "gitResolveConflicts": return git && context.conflictCount > 0
        case "gitFileDiff", "gitFileStage", "gitFileRollBack": return git && context.hasEditor && context.currentFileChanged
        case "buildProject", "buildModule", "rebuildProject": return project
        case "stop": return context.debugActive || context.isRunning
        case "evaluateExpression": return context.debugPaused
        case "viewBreakpoints", "copyPath", "recentFiles": return context.hasProject
        case "sortLines", "reverseLines", "pastePlain": return context.hasEditor
        case "nextProjectWindow", "previousProjectWindow": return context.projectWindowCount > 1
        default: return nil
        }
    }
}
