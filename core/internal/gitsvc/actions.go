package gitsvc

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	gitTimeout     = 30 * time.Second
	networkTimeout = 2 * time.Minute
)

// Git runs git operations with one program. Each session owns its own value, so sessions never share a setting.
type Git struct {
	Exe string // absolute path of the git program; empty means git on PATH
}

// Executable is the git program in use.
func (g Git) Executable() string {
	if g.Exe != "" {
		return g.Exe
	}
	return "git"
}

// run runs git in dir and returns its output. okExit lists exit codes that are not failures (diff --no-index exits 1).
func (g Git) run(dir string, okExit []int, args ...string) (string, error) {
	return g.runFor(gitTimeout, dir, okExit, args...)
}

// runFor is run with its own time limit. git never asks for a password on the terminal: without a credential helper a push
// fails with git's message instead of waiting for input nobody can give.
func (g Git) runFor(timeout time.Duration, dir string, okExit []int, args ...string) (string, error) {
	if !filepath.IsAbs(dir) {
		return "", fmt.Errorf("directory must be absolute: %q", dir)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, g.Executable(), append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true") // no editor ever opens (rebase --continue, revert --continue)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			for _, code := range okExit {
				if exit.ExitCode() == code {
					return out.String(), nil
				}
			}
			message := strings.TrimSpace(stderr.String())
			if message == "" {
				message = strings.TrimSpace(out.String())
			}
			return "", errors.New(RedactURL(message))
		}
		return "", err
	}
	return out.String(), nil
}

// cleanPath accepts only a path inside the repository: relative, not climbing out, and not shaped like an option.
func cleanPath(path string) (string, error) {
	if path == "" || filepath.IsAbs(path) || strings.HasPrefix(path, "-") {
		return "", fmt.Errorf("not a path inside the repository: %q", path)
	}
	clean := filepath.Clean(path)
	if clean == ".." || strings.HasPrefix(clean, "../") || strings.Contains(path, "..") && clean != path {
		return "", fmt.Errorf("not a path inside the repository: %q", path)
	}
	return clean, nil
}

func cleanPaths(paths []string) ([]string, error) {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		clean, err := cleanPath(p)
		if err != nil {
			return nil, err
		}
		out = append(out, clean)
	}
	return out, nil
}

// Diff returns the unified diff of one file: the staged change, or the working tree change (an untracked file shows as new).
func (g Git) Diff(dir, path string, staged bool) (string, error) {
	clean, err := cleanPath(path)
	if err != nil {
		return "", err
	}
	if staged {
		return g.run(dir, nil, "diff", "--cached", "--no-color", "--", clean)
	}
	if !g.tracked(dir, clean) {
		if _, statErr := os.Stat(filepath.Join(dir, clean)); statErr != nil {
			return "", nil
		}
		return g.run(dir, []int{1}, "diff", "--no-index", "--no-color", "--", os.DevNull, clean)
	}
	return g.run(dir, nil, "diff", "--no-color", "--", clean)
}

func (g Git) tracked(dir, path string) bool {
	_, err := g.run(dir, nil, "ls-files", "--error-unmatch", "--", path)
	return err == nil
}

func (g Git) Stage(dir string, paths []string) error {
	clean, err := cleanPaths(paths)
	if err != nil || len(clean) == 0 {
		return firstError(err, "nothing to stage")
	}
	_, err = g.run(dir, nil, append([]string{"add", "--"}, clean...)...)
	return err
}

func (g Git) Unstage(dir string, paths []string) error {
	clean, err := cleanPaths(paths)
	if err != nil || len(clean) == 0 {
		return firstError(err, "nothing to unstage")
	}
	_, err = g.run(dir, nil, append([]string{"reset", "-q", "--"}, clean...)...)
	return err
}

// Discard throws away the changes of the given files: a tracked file goes back to HEAD (staged and unstaged edits both), a
// file added but never committed is removed from the index and the disk, an untracked file is deleted. Cannot be undone.
func (g Git) Discard(dir string, paths []string) error {
	clean, err := cleanPaths(paths)
	if err != nil || len(clean) == 0 {
		return firstError(err, "nothing to discard")
	}
	for _, path := range clean {
		if _, err := g.run(dir, nil, "cat-file", "-e", "HEAD:"+path); err == nil {
			if _, err := g.run(dir, nil, "restore", "--source=HEAD", "--staged", "--worktree", "--", path); err != nil {
				return err
			}
			continue
		}
		if tracked, _ := g.run(dir, nil, "ls-files", "--", path); strings.TrimSpace(tracked) != "" {
			if _, err := g.run(dir, nil, "rm", "-f", "-q", "--", path); err != nil {
				return err
			}
			continue
		}
		if _, err := g.run(dir, nil, "clean", "-f", "-q", "--", path); err != nil {
			return err
		}
	}
	return nil
}

// Push sends the current branch to its upstream; a branch without one is published to the first remote and tracked.
func (g Git) Push(dir string) error {
	if _, err := g.run(dir, nil, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"); err == nil {
		_, err := g.runFor(networkTimeout, dir, nil, "push", "-q")
		return err
	}
	remotes, err := g.run(dir, nil, "remote")
	if err != nil {
		return err
	}
	fields := strings.Fields(remotes)
	if len(fields) == 0 {
		return errors.New("this repository has no remote to push to")
	}
	_, err = g.runFor(networkTimeout, dir, nil, "push", "-q", "-u", fields[0], "HEAD")
	return err
}

// Pull brings in the upstream's commits, fast-forward only: a diverged branch is reported, never merged behind the person's back.
func (g Git) Pull(dir string) error {
	_, err := g.runFor(networkTimeout, dir, nil, "pull", "-q", "--ff-only")
	return err
}

// Merge merges a branch into the current one. A merge commit is made when needed (no editor opens). On a conflict the merge is
// aborted so the working tree is left as it was, and the error says so.
func (g Git) Merge(dir, branch string) error {
	if !branchName.MatchString(branch) || strings.Contains(branch, "..") || strings.HasSuffix(branch, "/") || strings.HasSuffix(branch, ".lock") {
		return fmt.Errorf("%q is not a usable branch name", branch)
	}
	_, err := g.run(dir, nil, "merge", "--no-ff", "--no-edit", "--no-stat", "-q", branch, "--")
	if err == nil {
		return nil
	}
	if conflicts, _ := g.run(dir, nil, "diff", "--name-only", "--diff-filter=U"); strings.TrimSpace(conflicts) != "" {
		_, _ = g.run(dir, nil, "merge", "--abort")
		return fmt.Errorf("merging %s has conflicts in %s; the merge was aborted and nothing changed", branch, strings.Join(strings.Fields(conflicts), ", "))
	}
	if _, inProgress := g.run(dir, nil, "rev-parse", "-q", "--verify", "MERGE_HEAD"); inProgress == nil {
		_, _ = g.run(dir, nil, "merge", "--abort")
		return fmt.Errorf("the merge of %s failed and was aborted: %w", branch, err)
	}
	return err
}

// Fetch updates the remote-tracking branches from every remote. A repository without a remote has nothing to fetch.
func (g Git) Fetch(dir string) error {
	remotes, err := g.run(dir, nil, "remote")
	if err != nil || strings.TrimSpace(remotes) == "" {
		return err
	}
	_, err = g.runFor(networkTimeout, dir, nil, "fetch", "-q", "--all")
	return err
}

func firstError(err error, otherwise string) error {
	if err != nil {
		return err
	}
	return errors.New(otherwise)
}

// Commit commits what is staged. email and name, when not empty, are used as the author for this commit only.
func (g Git) Commit(dir, message, email, name string) error {
	if strings.TrimSpace(message) == "" {
		return errors.New("write a commit message first")
	}
	args := []string{}
	if email != "" {
		args = append(args, "-c", "user.email="+email)
	}
	if name != "" {
		args = append(args, "-c", "user.name="+name)
	}
	args = append(args, "commit", "-q", "-m", message)
	_, err := g.run(dir, nil, args...)
	return err
}

type Commitment struct {
	Hash, Author, When, Subject string
}

// Log returns the newest commits first.
func (g Git) Log(dir string, limit int) ([]Commitment, error) {
	if limit < 1 || limit > 500 {
		limit = 50
	}
	out, err := g.run(dir, nil, "log", "-n", strconv.Itoa(limit), "--format=%H%x1f%an%x1f%ar%x1f%s")
	if err != nil {
		if strings.Contains(err.Error(), "does not have any commits") {
			return nil, nil
		}
		return nil, err
	}
	var commits []Commitment
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		parts := strings.Split(line, "\x1f")
		if len(parts) == 4 {
			commits = append(commits, Commitment{Hash: parts[0], Author: parts[1], When: parts[2], Subject: parts[3]})
		}
	}
	return commits, nil
}

type Branch struct {
	Name    string
	Current bool
}

func (g Git) Branches(dir string) ([]Branch, error) {
	out, err := g.run(dir, nil, "branch", "--format=%(HEAD)%(refname:short)")
	if err != nil {
		return nil, err
	}
	var branches []Branch
	// No TrimSpace on the whole output: a branch that is not current starts with a space (%(HEAD)).
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if len(line) < 2 || strings.HasPrefix(line[1:], "(") {
			continue // a detached head is not a branch
		}
		branches = append(branches, Branch{Name: line[1:], Current: line[0] == '*'})
	}
	return branches, nil
}

var branchName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*$`)

// Checkout switches to a branch, creating it first when create is true.
func (g Git) Checkout(dir, name string, create bool) error {
	if !branchName.MatchString(name) || strings.Contains(name, "..") || strings.HasSuffix(name, "/") || strings.HasSuffix(name, ".lock") {
		return fmt.Errorf("%q is not a usable branch name", name)
	}
	args := []string{"switch"}
	if create {
		args = append(args, "-c")
	}
	_, err := g.run(dir, nil, append(args, name)...)
	return err
}

// LinesKind says how a range of lines differs from the last commit.
type LinesKind int

const (
	LinesAdded LinesKind = iota + 1
	LinesModified
	LinesDeleted // Count is 0 and Start is the line the removed lines followed
)

type LineChange struct {
	Start, Count int
	Kind         LinesKind
}

var hunkHeader = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

// ChangedLines compares a file with the last commit: which lines were added, changed, or follow removed lines (1-based).
func (g Git) ChangedLines(dir, path string) ([]LineChange, error) {
	clean, err := cleanPath(path)
	if err != nil {
		return nil, err
	}
	data, readErr := os.ReadFile(filepath.Join(dir, clean))
	if readErr != nil {
		return nil, nil
	}
	if !g.tracked(dir, clean) {
		count := strings.Count(string(data), "\n")
		if len(data) > 0 && !strings.HasSuffix(string(data), "\n") {
			count++
		}
		if count == 0 {
			return nil, nil
		}
		return []LineChange{{Start: 1, Count: count, Kind: LinesAdded}}, nil
	}
	out, err := g.run(dir, nil, "diff", "-U0", "--no-color", "HEAD", "--", clean)
	if err != nil {
		return nil, nil // no HEAD yet (nothing committed): there is nothing to compare with
	}
	var changes []LineChange
	for _, line := range strings.Split(out, "\n") {
		m := hunkHeader.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		oldCount, newStart, newCount := atoiDefault(m[2], 1), atoiDefault(m[3], 0), atoiDefault(m[4], 1)
		switch {
		case oldCount == 0:
			changes = append(changes, LineChange{Start: newStart, Count: newCount, Kind: LinesAdded})
		case newCount == 0:
			changes = append(changes, LineChange{Start: newStart, Count: 0, Kind: LinesDeleted})
		case newCount > oldCount:
			changes = append(changes, LineChange{Start: newStart, Count: oldCount, Kind: LinesModified}, LineChange{Start: newStart + oldCount, Count: newCount - oldCount, Kind: LinesAdded})
		default:
			changes = append(changes, LineChange{Start: newStart, Count: newCount, Kind: LinesModified})
		}
	}
	return changes, nil
}

func atoiDefault(text string, fallback int) int {
	if text == "" {
		return fallback
	}
	n, err := strconv.Atoi(text)
	if err != nil {
		return fallback
	}
	return n
}
