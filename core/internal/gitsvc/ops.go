package gitsvc

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// validRef accepts a branch or tag name git can use and nothing shaped like an option.
func validRef(name string) bool {
	return branchName.MatchString(name) && !strings.Contains(name, "..") && !strings.HasSuffix(name, "/") && !strings.HasSuffix(name, ".lock")
}

var (
	revisionName = regexp.MustCompile(`^[A-Za-z0-9_@{}~^./-]+$`)
	remoteName   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

// Operation says which multi-step git operation is waiting in the repository: "merge", "rebase", "revert", "cherry-pick" or "".
func (g Git) Operation(dir string) string {
	for _, probe := range []struct{ name, path string }{
		{"rebase", "rebase-merge"}, {"rebase", "rebase-apply"}, {"merge", "MERGE_HEAD"}, {"revert", "REVERT_HEAD"}, {"cherry-pick", "CHERRY_PICK_HEAD"},
	} {
		out, err := g.run(dir, nil, "rev-parse", "--git-path", probe.path)
		if err != nil {
			return ""
		}
		path := strings.TrimSpace(out)
		if !filepath.IsAbs(path) {
			path = filepath.Join(dir, path)
		}
		if _, err := os.Stat(path); err == nil {
			return probe.name
		}
	}
	return ""
}

// Tag marks HEAD with a lightweight tag.
func (g Git) Tag(dir, name string) error {
	if !validRef(name) {
		return fmt.Errorf("%q is not a usable tag name", name)
	}
	_, err := g.run(dir, nil, "tag", name)
	return err
}

// Reset moves HEAD to target (empty means HEAD). mode is soft, mixed or hard; hard throws away working tree changes.
func (g Git) Reset(dir, mode, target string) error {
	if mode != "soft" && mode != "mixed" && mode != "hard" {
		return fmt.Errorf("%q is not a reset mode", mode)
	}
	if target == "" {
		target = "HEAD"
	}
	if !revisionName.MatchString(target) || strings.HasPrefix(target, "-") {
		return fmt.Errorf("%q is not a usable revision", target)
	}
	_, err := g.run(dir, nil, "reset", "-q", "--"+mode, target, "--")
	return err
}

// Stash saves the changes, new files included, and cleans the working tree.
func (g Git) Stash(dir, message string) error {
	args := []string{"stash", "push", "--include-untracked"}
	if strings.TrimSpace(message) != "" {
		args = append(args, "-m", message)
	}
	out, err := g.run(dir, nil, args...)
	if err != nil {
		return err
	}
	if strings.Contains(out, "No local changes") {
		return errors.New("there are no changes to stash")
	}
	return nil
}

// Unstash applies the newest stash and drops it.
func (g Git) Unstash(dir string) error {
	_, err := g.run(dir, nil, "stash", "pop", "-q")
	return err
}

func (g Git) AbortMerge(dir string) error {
	_, err := g.run(dir, nil, "merge", "--abort")
	return err
}

// Rebase replays the current branch onto another. On a conflict the rebase is left in progress (continue, skip or abort it).
func (g Git) Rebase(dir, onto string) error {
	if !validRef(onto) {
		return fmt.Errorf("%q is not a usable branch name", onto)
	}
	_, err := g.run(dir, nil, "rebase", onto, "--")
	if err != nil && g.Operation(dir) == "rebase" {
		return fmt.Errorf("the rebase stopped on a conflict and is in progress: resolve it, then continue, skip or abort (%s)", firstLine(err.Error()))
	}
	return err
}

func firstLine(text string) string { return strings.SplitN(strings.TrimSpace(text), "\n", 2)[0] }

func (g Git) AbortRebase(dir string) error {
	_, err := g.run(dir, nil, "rebase", "--abort")
	return err
}
func (g Git) SkipRebase(dir string) error { _, err := g.run(dir, nil, "rebase", "--skip"); return err }

func (g Git) ContinueRebase(dir string) error {
	_, err := g.run(dir, nil, "rebase", "--continue")
	return err
}

func sequenceName(name string) error {
	if name != "revert" && name != "cherry-pick" {
		return fmt.Errorf("%q is not a revert or cherry-pick", name)
	}
	return nil
}

// ContinueSequence continues a stopped "revert" or "cherry-pick".
func (g Git) ContinueSequence(dir, name string) error {
	if err := sequenceName(name); err != nil {
		return err
	}
	_, err := g.run(dir, nil, name, "--continue")
	return err
}

// AbortSequence abandons a stopped "revert" or "cherry-pick".
func (g Git) AbortSequence(dir, name string) error {
	if err := sequenceName(name); err != nil {
		return err
	}
	_, err := g.run(dir, nil, name, "--abort")
	return err
}

// Patch returns every change since HEAD (staged and unstaged, binary included) as a patch. New untracked files are not in it.
func (g Git) Patch(dir string) (string, error) {
	return g.run(dir, nil, "diff", "HEAD", "--binary", "--no-color")
}

// ApplyPatch applies a patch file (an absolute path) to the working tree.
func (g Git) ApplyPatch(dir, file string) error {
	if !filepath.IsAbs(file) {
		return fmt.Errorf("patch file must be an absolute path: %q", file)
	}
	if info, err := os.Stat(file); err != nil || info.IsDir() {
		return fmt.Errorf("cannot read the patch file %q", file)
	}
	_, err := g.run(dir, nil, "apply", "--whitespace=nowarn", "--", file)
	return err
}

type Remote struct{ Name, URL string }

func (g Git) Remotes(dir string) ([]Remote, error) {
	out, err := g.run(dir, nil, "remote", "-v")
	if err != nil {
		return nil, err
	}
	var remotes []Remote
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && !seen[fields[0]] {
			seen[fields[0]] = true
			remotes = append(remotes, Remote{Name: fields[0], URL: RedactURL(fields[1])})
		}
	}
	return remotes, nil
}

func (g Git) AddRemote(dir, name, url string) error {
	if !remoteName.MatchString(name) {
		return fmt.Errorf("%q is not a usable remote name", name)
	}
	if url = strings.TrimSpace(url); url == "" || strings.HasPrefix(url, "-") || strings.ContainsAny(url, " \t\n") {
		return fmt.Errorf("%q is not a usable remote address", url)
	}
	_, err := g.run(dir, nil, "remote", "add", name, url)
	return err
}

func (g Git) RemoveRemote(dir, name string) error {
	if !remoteName.MatchString(name) {
		return fmt.Errorf("%q is not a usable remote name", name)
	}
	_, err := g.run(dir, nil, "remote", "remove", name)
	return err
}

type Worktree struct {
	Path   string
	Branch string // empty for a detached head
	Head   string
}

func (g Git) Worktrees(dir string) ([]Worktree, error) {
	out, err := g.run(dir, nil, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	var list []Worktree
	for _, block := range strings.Split(strings.TrimSpace(out), "\n\n") {
		var w Worktree
		for _, line := range strings.Split(block, "\n") {
			switch {
			case strings.HasPrefix(line, "worktree "):
				w.Path = strings.TrimPrefix(line, "worktree ")
			case strings.HasPrefix(line, "HEAD "):
				w.Head = strings.TrimPrefix(line, "HEAD ")
			case strings.HasPrefix(line, "branch "):
				w.Branch = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
			}
		}
		if w.Path != "" {
			list = append(list, w)
		}
	}
	return list, nil
}

// AddWorktree checks a branch out in a new folder (an absolute path), creating the branch first when create is true.
func (g Git) AddWorktree(dir, path, branch string, create bool) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("worktree folder must be an absolute path: %q", path)
	}
	if !validRef(branch) {
		return fmt.Errorf("%q is not a usable branch name", branch)
	}
	if create {
		_, err := g.run(dir, nil, "worktree", "add", "-q", "-b", branch, "--", path)
		return err
	}
	_, err := g.run(dir, nil, "worktree", "add", "-q", "--", path, branch)
	return err
}

func (g Git) RemoveWorktree(dir, path string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("worktree folder must be an absolute path: %q", path)
	}
	_, err := g.run(dir, nil, "worktree", "remove", "--", path)
	return err
}
