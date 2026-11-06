// Package search finds text in a project's files, for Find in Files and its replacements. It reads files and never writes them.
package search

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	defaultMaxResults = 2000
	maxFileSize       = 2 << 20
	maxQuery          = 1000
	previewMax        = 400
)

// Options describes one search. Without HasReplace no replacement texts are computed.
type Options struct {
	Query         string
	Regex         bool
	CaseSensitive bool
	WholeWord     bool
	Include       []string // globs matched against the file name and the relative path; empty means every file
	HasReplace    bool
	Replacement   string
	MaxResults    int
}

// Match is one occurrence. Line is 0-based; Start and End are UTF-16 columns of the whole line. Text is the line, shortened
// around the match when it is very long, and TextStart is the UTF-16 column where Text begins.
type Match struct {
	Path        string
	Line        int
	Start, End  int
	Text        string
	TextStart   int
	Replacement string
}

type Result struct {
	Matches   []Match
	Files     int  // files that have a match
	Skipped   int  // binary files and files over 2 MB
	Truncated bool // the result limit was reached
}

// Search looks through the files of root: the tracked and untracked files git reports (ignored ones left out), or every file
// outside .git, node_modules and hidden folders when root is not a repository.
func Search(ctx context.Context, root string, o Options) (Result, error) {
	if !filepath.IsAbs(root) {
		return Result{}, fmt.Errorf("the folder must be an absolute path: %q", root)
	}
	if o.Query == "" {
		return Result{}, errors.New("type something to search for")
	}
	if len(o.Query) > maxQuery {
		return Result{}, errors.New("the search text is too long")
	}
	pattern := o.Query
	if !o.Regex {
		pattern = regexp.QuoteMeta(pattern)
	}
	if o.WholeWord {
		pattern = `\b(?:` + pattern + `)\b`
	}
	if !o.CaseSensitive {
		pattern = "(?i)" + pattern
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return Result{}, fmt.Errorf("not a valid pattern: %w", err)
	}
	limit := o.MaxResults
	if limit <= 0 {
		limit = defaultMaxResults
	}
	files, err := listFiles(ctx, root)
	if err != nil {
		return Result{}, err
	}
	var result Result
	for _, rel := range files {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		if !included(rel, o.Include) {
			continue
		}
		// Lstat: a symlink could point outside the workspace, so only real files are read.
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		if info.Size() > maxFileSize {
			result.Skipped++
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		if bytes.IndexByte(data[:min(len(data), 8192)], 0) >= 0 {
			result.Skipped++
			continue
		}
		found := false
		for lineNumber, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSuffix(line, "\r")
			for _, loc := range re.FindAllStringSubmatchIndex(line, -1) {
				if loc[0] == loc[1] {
					continue // an empty match is not worth showing
				}
				if len(result.Matches) >= limit {
					result.Truncated = true
					if found {
						result.Files++
					}
					return result, nil
				}
				m := Match{Path: rel, Line: lineNumber, Start: utf16Column(line, loc[0]), End: utf16Column(line, loc[1])}
				m.Text, m.TextStart = preview(line, loc[0], loc[1])
				if o.HasReplace {
					if o.Regex {
						m.Replacement = string(re.ExpandString(nil, o.Replacement, line, loc))
					} else {
						m.Replacement = o.Replacement
					}
				}
				result.Matches = append(result.Matches, m)
				found = true
			}
		}
		if found {
			result.Files++
		}
	}
	return result, nil
}

func included(rel string, globs []string) bool {
	if len(globs) == 0 {
		return true
	}
	for _, glob := range globs {
		glob = strings.TrimSpace(glob)
		if glob == "" {
			continue
		}
		if ok, _ := path.Match(glob, path.Base(rel)); ok {
			return true
		}
		if ok, _ := path.Match(glob, rel); ok {
			return true
		}
	}
	return false
}

func utf16Column(line string, byteOffset int) int {
	units := 0
	for _, r := range line[:byteOffset] {
		if r > 0xFFFF {
			units += 2
		} else {
			units++
		}
	}
	return units
}

// preview shortens a very long line to a window around the match, on rune boundaries.
func preview(line string, start, end int) (string, int) {
	if len(line) <= previewMax {
		return line, 0
	}
	from, to := max(0, start-100), min(len(line), end+200)
	for from > 0 && !utf8.RuneStart(line[from]) {
		from--
	}
	for to < len(line) && !utf8.RuneStart(line[to]) {
		to++
	}
	return line[from:to], utf16Column(line, from)
}

func gitOutput(ctx context.Context, dir string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	return cmd.Output()
}

func runGit(dir string, args ...string) error {
	_, err := gitOutput(context.Background(), dir, args...)
	return err
}

// listFiles returns slash-separated relative paths, sorted.
func listFiles(ctx context.Context, root string) ([]string, error) {
	if out, err := gitOutput(ctx, root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"); err == nil {
		var files []string
		for _, name := range strings.Split(string(out), "\x00") {
			if name != "" {
				files = append(files, name)
			}
		}
		sort.Strings(files)
		return files, nil
	}
	var files []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && (strings.HasPrefix(name, ".") || name == "node_modules") {
				return filepath.SkipDir
			}
			return nil
		}
		if rel, err := filepath.Rel(root, p); err == nil {
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}
