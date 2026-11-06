// Package toolchain locates the Go tools Gobi drives (go, gopls, dlv) and reports their versions.
// Finding only reports; installing happens only through Install, which a caller runs after the user agreed.
package toolchain

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Tool describes a binary Gobi expects to find.
type Tool struct {
	Name        string
	VersionArgs []string
	Required    bool
}

// DefaultTools are the tools slice 1 checks. dlv is optional: it is only needed for debugging.
var DefaultTools = []Tool{
	{Name: "go", VersionArgs: []string{"version"}, Required: true},
	{Name: "gopls", VersionArgs: []string{"version"}, Required: true},
	{Name: "dlv", VersionArgs: []string{"version"}},
	{Name: "git", VersionArgs: []string{"--version"}},
}

// Report is the result of looking for one tool.
type Report struct {
	Name     string
	Path     string
	Version  string
	Found    bool
	Required bool
	Problem  string
}

// Finder resolves tool names using the GOBIN, GOPATH and PATH entries of Env.
type Finder struct {
	Env map[string]string
}

// FromOS builds a Finder from the process environment.
// ponytail: GOBIN/GOPATH come from process env only; `go env -w` values are not read yet.
func FromOS() Finder {
	env := map[string]string{
		"GOBIN":  os.Getenv("GOBIN"),
		"GOPATH": os.Getenv("GOPATH"),
		"PATH":   os.Getenv("PATH"),
	}
	if env["GOPATH"] == "" {
		if home, err := os.UserHomeDir(); err == nil {
			env["GOPATH"] = filepath.Join(home, "go")
		}
	}
	return Finder{Env: env}
}

// Find returns the first executable named name in GOBIN, then each GOPATH/bin, then PATH.
func (f Finder) Find(name string) (string, error) {
	var searchDirs []string
	if gobin := f.Env["GOBIN"]; gobin != "" {
		searchDirs = append(searchDirs, gobin)
	}
	for _, gopathEntry := range filepath.SplitList(f.Env["GOPATH"]) {
		searchDirs = append(searchDirs, filepath.Join(gopathEntry, "bin"))
	}
	searchDirs = append(searchDirs, filepath.SplitList(f.Env["PATH"])...)

	for _, dir := range searchDirs {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s not found in GOBIN, GOPATH/bin or PATH", name)
}

// Check looks up every tool and asks it for its version.
func Check(finder Finder, tools []Tool) []Report {
	reports := make([]Report, 0, len(tools))
	for _, tool := range tools {
		report := Report{Name: tool.Name, Required: tool.Required}
		path, err := finder.Find(tool.Name)
		if err != nil {
			report.Problem = err.Error()
			reports = append(reports, report)
			continue
		}
		report.Path, report.Found = path, true
		report.Version, err = versionOf(path, tool.VersionArgs)
		if err != nil {
			report.Problem = err.Error()
		}
		reports = append(reports, report)
	}
	return reports
}

// HasMissingRequired reports whether any required tool was not found.
func HasMissingRequired(reports []Report) bool {
	for _, report := range reports {
		if report.Required && !report.Found {
			return true
		}
	}
	return false
}

func versionOf(path string, args []string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, path, args...).Output()
	if err != nil {
		return "", fmt.Errorf("version check failed: %w", err)
	}
	firstLine, _, _ := strings.Cut(strings.TrimSpace(string(output)), "\n")
	return firstLine, nil
}

// installPackages are the tools `go install` can fetch.
var installPackages = map[string]string{
	"gopls": "golang.org/x/tools/gopls@latest",
	"dlv":   "github.com/go-delve/delve/cmd/dlv@latest",
}

// InstallArgs are the arguments to `go` that install name, or false when go install cannot provide it.
func InstallArgs(name string) ([]string, bool) {
	pkg, ok := installPackages[name]
	if !ok {
		return nil, false
	}
	return []string{"install", pkg}, true
}

// Hint says how to get a tool Gobi cannot install itself.
func Hint(name string) string {
	switch name {
	case "go":
		return "Install Go from https://go.dev/dl, or run: brew install go"
	case "git":
		return "Install the command line tools with: xcode-select --install"
	}
	return ""
}

// Install fetches name with `go install`. It needs go to be installed already.
func Install(ctx context.Context, finder Finder, name string) error {
	args, ok := InstallArgs(name)
	if !ok {
		return fmt.Errorf("%s cannot be installed automatically. %s", name, Hint(name))
	}
	goPath, err := finder.Find("go")
	if err != nil {
		return fmt.Errorf("go is needed to install %s, and it was not found. %s", name, Hint("go"))
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(ctx, goPath, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("go %s failed: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
