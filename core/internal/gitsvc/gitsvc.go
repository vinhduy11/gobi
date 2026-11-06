// Package gitsvc reads the state of a project's git repository by running the git command. It only reads.
package gitsvc

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Mark is how git sees one path; the explorer colours names by it.
type Mark int

const (
	Modified Mark = iota + 1
	Added
	Deleted
	Renamed
	Untracked
	Ignored
	Conflict
)

type File struct {
	Path string // relative to the repository root, slash separated; a trailing slash means a whole folder
	Mark Mark
	// Staged is true when part of the change is in the index; Unstaged when part is only in the working tree.
	Staged, Unstaged bool
}

type Result struct {
	Branch string // empty outside a repository; "HEAD" on a detached head
	Ahead  int    // commits not yet pushed to the upstream
	Behind int
	// Operation is the multi-step operation waiting in the repository: merge, rebase, revert, cherry-pick or empty.
	Operation string
	Files     []File
}

func (r Result) hasStaged(path string) bool {
	for _, f := range r.Files {
		if f.Path == path && f.Staged {
			return true
		}
	}
	return false
}

// Status returns the branch and every changed, untracked or ignored path of the repository that contains dir.
// Outside a repository the result is empty and there is no error.
func (g Git) Status(dir string) (Result, error) {
	if !filepath.IsAbs(dir) {
		return Result{}, fmt.Errorf("directory must be absolute: %q", dir)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, g.Executable(), "-C", dir, "status", "--porcelain=v1", "-z", "--branch", "--ignored")
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 128 {
			return Result{}, nil // not a repository
		}
		return Result{}, fmt.Errorf("git status: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	result := parse(out.String())
	if result.Branch != "" {
		result.Operation = g.Operation(dir)
	}
	return result, nil
}

func parse(text string) Result {
	var result Result
	records := strings.Split(text, "\x00")
	for i := 0; i < len(records); i++ {
		record := records[i]
		switch {
		case strings.HasPrefix(record, "## "):
			result.Branch = branchOf(record[3:])
			result.Ahead, result.Behind = countsOf(record[3:])
		case len(record) > 3:
			x, y, path := record[0], record[1], record[3:]
			if x == 'R' || x == 'C' {
				i++ // the next record is the old name
			}
			if mark := markOf(x, y); mark != 0 {
				result.Files = append(result.Files, File{Path: path, Mark: mark, Staged: mark != Untracked && mark != Ignored && x != ' ', Unstaged: mark != Untracked && mark != Ignored && y != ' '})
			}
		}
	}
	return result
}

func branchOf(header string) string {
	switch {
	case strings.HasPrefix(header, "No commits yet on "):
		return strings.TrimPrefix(header, "No commits yet on ")
	case strings.HasPrefix(header, "HEAD (no branch)"):
		return "HEAD"
	}
	if i := strings.Index(header, "..."); i >= 0 {
		header = header[:i]
	}
	if i := strings.Index(header, " ["); i >= 0 {
		header = header[:i]
	}
	return header
}

func markOf(x, y byte) Mark {
	switch {
	case x == '?':
		return Untracked
	case x == '!':
		return Ignored
	case x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D'):
		return Conflict
	case x == 'R' || y == 'R':
		return Renamed
	case x == 'D' || y == 'D':
		return Deleted
	case x == 'A':
		return Added
	case x == 'M' || y == 'M' || x == 'T' || y == 'T':
		return Modified
	}
	return 0
}

// countsOf reads "[ahead 1, behind 2]" from a branch header.
func countsOf(header string) (ahead, behind int) {
	start := strings.Index(header, " [")
	end := strings.LastIndex(header, "]")
	if start < 0 || end < start {
		return 0, 0
	}
	for _, part := range strings.Split(header[start+2:end], ", ") {
		var n int
		if _, err := fmt.Sscanf(part, "ahead %d", &n); err == nil {
			ahead = n
		} else if _, err := fmt.Sscanf(part, "behind %d", &n); err == nil {
			behind = n
		}
	}
	return ahead, behind
}
