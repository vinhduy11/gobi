//go:build unix

package daemon

import (
	"log/slog"
	"strconv"
	"strings"

	"gobi/core/internal/gitsvc"
	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

// Field numbers of the git channel messages (protobuf wire format, see package wire). Never reuse a number.
//
//	client to server: 1 kind (1 status, 2 diff, 3 branches, 4 checkout, 5 stage, 6 unstage, 7 commit, 8 log, 9 changed lines,
//	  10 discard, 11 push, 12 pull, 13 merge (text: the branch), 14 fetch)
//	  5 text argument (a path, a branch name or a commit message), 6 path (repeated), 7 flag (diff: staged; checkout: create),
//	  8 number (log: how many commits)
//	  15 tag, 16 reset, 17 stash, 18 unstash, 19 abort merge, 20 rebase, 21 abort rebase, 22 continue rebase, 23 skip rebase,
//	  24 patch, 25 apply patch, 26/27 continue/abort revert, 28/29 continue/abort cherry-pick, 30 remotes, 31 add remote,
//	  32 remove remote, 33 worktrees, 34 add worktree, 35 remove worktree; 9 second text argument
//	server to client: 1 kind (1 status, 2 error, 3 text, 4 branches, 5 log, 6 lines, 7 done, 8 list)
//	  list:     3 entry (repeated; remotes: name and address, worktrees: folder, branch and head, separated by 0x1f)
//	  status:   2 branch, 3 entry (repeated: one digit for the mark, one digit for the stage state (0 none, 1 staged, 2 unstaged,
//	            3 both), then the path), 5 ahead, 6 behind, 7 operation in progress (merge, rebase, revert, cherry-pick)
//	  error:    4 message
//	  text:     8 text (a diff)
//	  branches: 3 entry (repeated: "1" or "0" for the current branch, then the name)
//	  log:      3 entry (repeated: hash, author, when and subject separated by 0x1f)
//	  lines:    3 entry (repeated: "kind start count", kind 1 added, 2 modified, 3 deleted)
//
// Marks are the digits of gitsvc.Mark. workspace_root in the handshake is the repository folder. Requests are answered in order.
const (
	gitKind   = 1
	gitBranch = 2
	gitEntry  = 3
	gitError  = 4
	gitText   = 5
	gitPaths  = 6
	gitFlag   = 7
	gitNumber = 8
	gitAhead  = 5
	gitBehind = 6
	gitBody   = 8
	gitText2  = 9 // second text argument
	// gitOperation is the status reply's multi-step operation: merge, rebase, revert, cherry-pick or empty.
	gitOperation = 7

	gitStatusRequest   = 1
	gitDiffRequest     = 2
	gitBranchesRequest = 3
	gitCheckoutRequest = 4
	gitStageRequest    = 5
	gitUnstageRequest  = 6
	gitCommitRequest   = 7
	gitLogRequest      = 8
	gitLinesRequest    = 9
	gitDiscardRequest  = 10
	gitPushRequest     = 11
	gitPullRequest     = 12
	gitMergeRequest    = 13
	gitFetchRequest    = 14

	gitTagRequest                = 15 // text: the name
	gitResetRequest              = 16 // text: soft, mixed or hard; text2: the revision (empty: HEAD)
	gitStashRequest              = 17 // text: the message
	gitUnstashRequest            = 18
	gitAbortMergeRequest         = 19
	gitRebaseRequest             = 20 // text: the branch to rebase onto
	gitAbortRebaseRequest        = 21
	gitContinueRebaseRequest     = 22
	gitSkipRebaseRequest         = 23
	gitPatchRequest              = 24 // answered with a text reply holding git diff HEAD
	gitApplyPatchRequest         = 25 // text: absolute path of the patch file
	gitContinueRevertRequest     = 26
	gitAbortRevertRequest        = 27
	gitContinueCherryPickRequest = 28
	gitAbortCherryPickRequest    = 29
	gitRemotesRequest            = 30 // answered with a list reply
	gitAddRemoteRequest          = 31 // text: name; text2: address
	gitRemoveRemoteRequest       = 32 // text: name
	gitWorktreesRequest          = 33 // answered with a list reply
	gitAddWorktreeRequest        = 34 // text: absolute folder; text2: branch; flag: create the branch
	gitRemoveWorktreeRequest     = 35 // text: absolute folder

	gitStatusReply   = 1
	gitErrorReply    = 2
	gitTextReply     = 3
	gitBranchesReply = 4
	gitLogReply      = 5
	gitLinesReply    = 6
	gitDoneReply     = 7
	gitListReply     = 8
)

// gitAdmit refuses the git channel for a workspace the user has not trusted: git runs hooks and filters the repository names.
func gitAdmit(hello ipc.Hello) string {
	if hello.Channel == "git" && !hello.Trusted {
		return "git is off in Restricted Mode; trust the project first"
	}
	return terminalAdmit(hello)
}

type gitRequest struct {
	kind   uint64
	text   string
	text2  string
	paths  []string
	flag   bool
	number int
}

func parseGitRequest(payload []byte) (gitRequest, error) {
	fields, err := wire.Parse(payload)
	if err != nil {
		return gitRequest{}, err
	}
	var request gitRequest
	for _, field := range fields {
		switch field.Number {
		case gitKind:
			request.kind = field.Uint
		case gitText:
			request.text = string(field.Bytes)
		case gitText2:
			request.text2 = string(field.Bytes)
		case gitPaths:
			request.paths = append(request.paths, string(field.Bytes))
		case gitFlag:
			request.flag = field.Uint != 0
		case gitNumber:
			request.number = int(field.Uint)
		}
	}
	return request, nil
}

func gitFailure(err error) []byte {
	var reply wire.Writer
	reply.Uint(gitKind, gitErrorReply)
	reply.String(gitError, err.Error())
	return reply.Bytes()
}

func gitDone() []byte {
	var reply wire.Writer
	reply.Uint(gitKind, gitDoneReply)
	return reply.Bytes()
}

// answerGit runs one request in the repository and returns the reply.
func answerGit(git gitsvc.Git, dir string, request gitRequest) []byte {
	var reply wire.Writer
	switch request.kind {
	case gitStatusRequest:
		result, err := git.Status(dir)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitStatusReply)
		reply.String(gitBranch, result.Branch)
		for _, file := range result.Files {
			state := 0
			if file.Staged {
				state |= 1
			}
			if file.Unstaged {
				state |= 2
			}
			reply.String(gitEntry, strconv.Itoa(int(file.Mark))+strconv.Itoa(state)+file.Path)
		}
		reply.Uint(gitAhead, uint64(result.Ahead))
		reply.Uint(gitBehind, uint64(result.Behind))
		if result.Operation != "" {
			reply.String(gitOperation, result.Operation)
		}
	case gitDiffRequest:
		text, err := git.Diff(dir, request.text, request.flag)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitTextReply)
		reply.String(gitBody, text)
	case gitBranchesRequest:
		branches, err := git.Branches(dir)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitBranchesReply)
		for _, branch := range branches {
			current := "0"
			if branch.Current {
				current = "1"
			}
			reply.String(gitEntry, current+branch.Name)
		}
	case gitCheckoutRequest:
		if err := git.Checkout(dir, request.text, request.flag); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitStageRequest:
		if err := git.Stage(dir, request.paths); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitUnstageRequest:
		if err := git.Unstage(dir, request.paths); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitDiscardRequest:
		if err := git.Discard(dir, request.paths); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitPushRequest:
		if err := git.Push(dir); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitPullRequest:
		if err := git.Pull(dir); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitMergeRequest:
		if err := git.Merge(dir, request.text); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitFetchRequest:
		if err := git.Fetch(dir); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitCommitRequest:
		if err := git.Commit(dir, request.text, "", ""); err != nil {
			return gitFailure(err)
		}
		return gitDone()
	case gitPatchRequest:
		text, err := git.Patch(dir)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitTextReply)
		reply.String(gitBody, text)
	case gitRemotesRequest:
		remotes, err := git.Remotes(dir)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitListReply)
		for _, remote := range remotes {
			reply.String(gitEntry, remote.Name+"\x1f"+remote.URL)
		}
	case gitWorktreesRequest:
		worktrees, err := git.Worktrees(dir)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitListReply)
		for _, w := range worktrees {
			reply.String(gitEntry, strings.Join([]string{w.Path, w.Branch, w.Head}, "\x1f"))
		}
	case gitLogRequest:
		commits, err := git.Log(dir, request.number)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitLogReply)
		for _, c := range commits {
			reply.String(gitEntry, strings.Join([]string{c.Hash, c.Author, c.When, c.Subject}, "\x1f"))
		}
	case gitLinesRequest:
		changes, err := git.ChangedLines(dir, request.text)
		if err != nil {
			return gitFailure(err)
		}
		reply.Uint(gitKind, gitLinesReply)
		for _, change := range changes {
			reply.String(gitEntry, strconv.Itoa(int(change.Kind))+" "+strconv.Itoa(change.Start)+" "+strconv.Itoa(change.Count))
		}
	default:
		if do := gitOperations[request.kind]; do != nil {
			if err := do(git, dir, request); err != nil {
				return gitFailure(err)
			}
			return gitDone()
		}
		return gitFailure(strconvError("unknown git request"))
	}
	return reply.Bytes()
}

// gitOperations are the requests that answer "done" or an error.
var gitOperations = map[uint64]func(git gitsvc.Git, dir string, r gitRequest) error{
	gitTagRequest:                func(git gitsvc.Git, d string, r gitRequest) error { return git.Tag(d, r.text) },
	gitResetRequest:              func(git gitsvc.Git, d string, r gitRequest) error { return git.Reset(d, r.text, r.text2) },
	gitStashRequest:              func(git gitsvc.Git, d string, r gitRequest) error { return git.Stash(d, r.text) },
	gitUnstashRequest:            func(git gitsvc.Git, d string, r gitRequest) error { return git.Unstash(d) },
	gitAbortMergeRequest:         func(git gitsvc.Git, d string, r gitRequest) error { return git.AbortMerge(d) },
	gitRebaseRequest:             func(git gitsvc.Git, d string, r gitRequest) error { return git.Rebase(d, r.text) },
	gitAbortRebaseRequest:        func(git gitsvc.Git, d string, r gitRequest) error { return git.AbortRebase(d) },
	gitContinueRebaseRequest:     func(git gitsvc.Git, d string, r gitRequest) error { return git.ContinueRebase(d) },
	gitSkipRebaseRequest:         func(git gitsvc.Git, d string, r gitRequest) error { return git.SkipRebase(d) },
	gitApplyPatchRequest:         func(git gitsvc.Git, d string, r gitRequest) error { return git.ApplyPatch(d, r.text) },
	gitContinueRevertRequest:     func(git gitsvc.Git, d string, r gitRequest) error { return git.ContinueSequence(d, "revert") },
	gitAbortRevertRequest:        func(git gitsvc.Git, d string, r gitRequest) error { return git.AbortSequence(d, "revert") },
	gitContinueCherryPickRequest: func(git gitsvc.Git, d string, r gitRequest) error { return git.ContinueSequence(d, "cherry-pick") },
	gitAbortCherryPickRequest:    func(git gitsvc.Git, d string, r gitRequest) error { return git.AbortSequence(d, "cherry-pick") },
	gitAddRemoteRequest:          func(git gitsvc.Git, d string, r gitRequest) error { return git.AddRemote(d, r.text, r.text2) },
	gitRemoveRemoteRequest:       func(git gitsvc.Git, d string, r gitRequest) error { return git.RemoveRemote(d, r.text) },
	gitAddWorktreeRequest:        func(git gitsvc.Git, d string, r gitRequest) error { return git.AddWorktree(d, r.text, r.text2, r.flag) },
	gitRemoveWorktreeRequest:     func(git gitsvc.Git, d string, r gitRequest) error { return git.RemoveWorktree(d, r.text) },
}

type strconvError string

func (e strconvError) Error() string { return string(e) }

func serveGit(session *ipc.Session, logger *slog.Logger) {
	git := gitsvc.Git{Exe: session.Hello.Tool}
	for {
		payload, err := session.Reader.Read()
		if err != nil {
			return
		}
		request, err := parseGitRequest(payload)
		if err != nil {
			return
		}
		reply := answerGit(git, session.Hello.WorkspaceRoot, request)
		if request.kind == gitCommitRequest || request.kind == gitCheckoutRequest || request.kind >= gitDiscardRequest {
			logger.Info("git request", "kind", request.kind, "root", session.Hello.WorkspaceRoot)
		}
		if session.Writer.Write(reply) != nil {
			return
		}
	}
}
