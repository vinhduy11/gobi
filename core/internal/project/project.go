//go:build unix

// Package project creates, inspects, imports and clones Go projects for the IDE. It runs the user's own go and git
// binaries, so a project made here behaves exactly like one made in a terminal.
package project

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Kinds of project folder.
const (
	KindWorkspace = "workspace" // has go.work
	KindModule    = "module"    // has go.mod
	KindFolder    = "folder"    // neither
)

const commandTimeout = 2 * time.Minute

var (
	namePattern      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	modulePattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._~/-]*$`)
	goVersionPattern = regexp.MustCompile(`^1\.\d{1,2}(\.\d{1,2})?$`)
	scpPattern       = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+$`)
)

// ValidateName accepts names that are safe to use as a single folder name.
func ValidateName(name string) error {
	if len(name) > 100 {
		return errors.New("name is longer than 100 characters")
	}
	if !namePattern.MatchString(name) {
		return fmt.Errorf("name %q must start with a letter or digit and use only letters, digits, '.', '_' and '-'", name)
	}
	return nil
}

// NewRequest describes a project to create.
type NewRequest struct {
	Template   string `json:"template"`
	Name       string `json:"name"`
	Location   string `json:"location"`    // absolute parent folder
	ModulePath string `json:"module_path"` // defaults to Name
	GoVersion  string `json:"go_version"`  // "" keeps what `go mod init` writes
	GitInit    bool   `json:"git_init"`
	SampleTest bool   `json:"sample_test"` // add a small passing test
	Scaffold   bool   `json:"scaffold"`    // README.md, .gitignore and .env.example
	WorkDir    string `json:"work_dir"`    // a folder with go.work to add the new module to; "" for none
}

// Info says what a project folder is.
type Info struct {
	Root       string `json:"root"`
	Kind       string `json:"kind"`
	ModulePath string `json:"module_path,omitempty"`
}

// plan is everything Create will write, worked out from the request without touching the disk. Preview and Create both
// use it, so the list a dialog shows is the list that ends up on disk.
type plan struct {
	root        string
	moduleDir   string // where go.mod and the template files go
	modulePath  string
	kind        string
	moduleFiles map[string]string // relative to moduleDir
	rootFiles   map[string]string // relative to root
	workspace   bool
}

func makePlan(request NewRequest) (plan, error) {
	if err := ValidateName(request.Name); err != nil {
		return plan{}, err
	}
	if !filepath.IsAbs(request.Location) {
		return plan{}, errors.New("location must be an absolute path")
	}
	modulePath := request.ModulePath
	if modulePath == "" {
		modulePath = request.Name
	}
	if !modulePattern.MatchString(modulePath) {
		return plan{}, fmt.Errorf("module path %q is not valid", modulePath)
	}
	if request.GoVersion != "" && !goVersionPattern.MatchString(request.GoVersion) {
		return plan{}, fmt.Errorf("go version %q is not valid", request.GoVersion)
	}
	workspace := request.Template == TemplateWorkspace
	moduleTemplate := request.Template
	if workspace {
		moduleTemplate = TemplateCLI
	}
	files, err := Render(moduleTemplate, modulePath, request.Name, request.SampleTest)
	if err != nil {
		return plan{}, err
	}
	root := filepath.Join(request.Location, request.Name)
	result := plan{root: root, moduleDir: root, modulePath: modulePath, kind: KindModule, moduleFiles: files, rootFiles: map[string]string{}, workspace: workspace}
	if workspace {
		result.moduleDir = filepath.Join(root, "app")
		result.kind = KindWorkspace
		if request.WorkDir != "" {
			return plan{}, errors.New("a new workspace cannot also be added to another workspace")
		}
	}
	if request.Scaffold {
		result.rootFiles["README.md"] = "# " + request.Name + "\n"
		result.rootFiles[".gitignore"] = ".env\n*.test\n*.out\n/bin/\n"
		result.rootFiles[".env.example"] = "# Copy this file to .env and fill in the values. .env is ignored by git.\n"
	}
	if request.WorkDir != "" {
		if _, err := os.Stat(filepath.Join(request.WorkDir, "go.work")); err != nil {
			return plan{}, fmt.Errorf("%s has no go.work", request.WorkDir)
		}
		if relative, err := filepath.Rel(request.WorkDir, root); err != nil || strings.HasPrefix(relative, "..") {
			return plan{}, fmt.Errorf("%s is not inside the workspace folder %s", root, request.WorkDir)
		}
	}
	return result, nil
}

// Preview lists the files Create would write, relative to the project folder and sorted. A .git folder is not listed.
func Preview(request NewRequest) ([]string, error) {
	p, err := makePlan(request)
	if err != nil {
		return nil, err
	}
	var paths []string
	relativeModule, _ := filepath.Rel(p.root, p.moduleDir)
	prefix := ""
	if relativeModule != "." {
		prefix = filepath.ToSlash(relativeModule) + "/"
	}
	paths = append(paths, prefix+"go.mod")
	for path := range p.moduleFiles {
		paths = append(paths, prefix+path)
	}
	for path := range p.rootFiles {
		paths = append(paths, path)
	}
	if p.workspace {
		paths = append(paths, "go.work")
	}
	sort.Strings(paths)
	return paths, nil
}

// Create makes a new project folder under Location. It refuses a destination that already has files.
func Create(request NewRequest) (Info, error) {
	p, err := makePlan(request)
	if err != nil {
		return Info{}, err
	}
	created, err := prepareEmptyFolder(p.root)
	if err != nil {
		return Info{}, err
	}
	info, err := populate(request, p)
	if err != nil {
		if created {
			os.RemoveAll(p.root) // only a folder this call made; an existing empty one is left in place
		}
		return Info{}, err
	}
	return info, nil
}

func populate(request NewRequest, p plan) (Info, error) {
	if err := os.MkdirAll(p.moduleDir, 0o755); err != nil {
		return Info{}, err
	}
	if err := goModInit(p.moduleDir, p.modulePath, request.GoVersion); err != nil {
		return Info{}, err
	}
	for path, content := range p.moduleFiles {
		if err := writeNew(filepath.Join(p.moduleDir, path), content); err != nil {
			return Info{}, err
		}
	}
	if p.workspace {
		if err := run(p.root, "go", "work", "init", "./app"); err != nil {
			return Info{}, err
		}
	}
	for path, content := range p.rootFiles {
		if err := writeNew(filepath.Join(p.root, path), content); err != nil {
			return Info{}, err
		}
	}
	if request.WorkDir != "" {
		relative, _ := filepath.Rel(request.WorkDir, p.root)
		if err := run(request.WorkDir, "go", "work", "use", "./"+filepath.ToSlash(relative)); err != nil {
			return Info{}, err
		}
	}
	if request.GitInit {
		if err := run(p.root, "git", "init", "--quiet"); err != nil {
			return Info{}, err
		}
		// `git init -b` needs git 2.28; pointing HEAD works on every version.
		if err := run(p.root, "git", "symbolic-ref", "HEAD", "refs/heads/master"); err != nil {
			return Info{}, err
		}
	}
	return Info{Root: p.root, Kind: p.kind, ModulePath: p.modulePath}, nil
}

// prepareEmptyFolder makes root if needed and reports whether it created it.
func prepareEmptyFolder(root string) (created bool, err error) {
	entries, readErr := os.ReadDir(root)
	switch {
	case readErr == nil && len(entries) > 0:
		return false, fmt.Errorf("%s already has files; choose an empty folder or another name", root)
	case readErr == nil:
		return false, nil
	case errors.Is(readErr, os.ErrNotExist):
		return true, os.MkdirAll(root, 0o755)
	default:
		return false, readErr
	}
}

func writeNew(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

// goModInit runs `go mod init` with GOTOOLCHAIN=local so that making a project never downloads a toolchain.
func goModInit(dir, modulePath, goVersion string) error {
	if err := run(dir, "go", "mod", "init", modulePath); err != nil {
		return err
	}
	if goVersion != "" {
		return run(dir, "go", "mod", "edit", "-go="+goVersion)
	}
	return nil
}

func run(dir string, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = append(os.Environ(), "GOTOOLCHAIN=local", "GIT_TERMINAL_PROMPT=0")
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

// Inspect reports the kind of a folder and, for a module, its module path.
func Inspect(dir string) Info {
	info := Info{Root: dir, Kind: KindFolder}
	if _, err := os.Stat(filepath.Join(dir, "go.work")); err == nil {
		info.Kind = KindWorkspace
	}
	if content, err := os.ReadFile(filepath.Join(dir, "go.mod")); err == nil {
		if info.Kind == KindFolder {
			info.Kind = KindModule
		}
		info.ModulePath = moduleLine(string(content))
	}
	return info
}

func moduleLine(goMod string) string {
	for _, line := range strings.Split(goMod, "\n") {
		if fields := strings.Fields(line); len(fields) == 2 && fields[0] == "module" {
			return strings.Trim(fields[1], `"`)
		}
	}
	return ""
}

// Import turns a folder that has no go.mod into a module. An empty modulePath is taken from the git remote, or else
// from the folder name.
func Import(dir, modulePath string) (Info, error) {
	if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
		return Info{}, fmt.Errorf("%s already has a go.mod", dir)
	}
	if modulePath == "" {
		modulePath = ModulePathFromRemote(gitRemote(dir))
	}
	if modulePath == "" {
		modulePath = filepath.Base(dir)
	}
	if !modulePattern.MatchString(modulePath) {
		return Info{}, fmt.Errorf("module path %q is not valid", modulePath)
	}
	if err := goModInit(dir, modulePath, ""); err != nil {
		return Info{}, err
	}
	return Inspect(dir), nil
}

func gitRemote(dir string) string {
	command := exec.Command("git", "config", "--get", "remote.origin.url")
	command.Dir = dir
	output, err := command.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

// ModulePathFromRemote turns a git remote URL into a module path ("github.com/acme/widget"); "" when it is not one.
func ModulePathFromRemote(remote string) string {
	remote = strings.TrimSuffix(strings.TrimSpace(remote), ".git")
	switch {
	case strings.HasPrefix(remote, "https://"), strings.HasPrefix(remote, "ssh://"), strings.HasPrefix(remote, "git://"):
		rest := remote[strings.Index(remote, "://")+3:]
		if at := strings.Index(rest, "@"); at >= 0 {
			rest = rest[at+1:]
		}
		return rest
	case scpPattern.MatchString(remote):
		at := strings.Index(remote, "@")
		return strings.Replace(remote[at+1:], ":", "/", 1)
	}
	return ""
}

// ValidateCloneURL accepts https, ssh and git URLs and scp-style addresses. It refuses local paths, file:// and
// transports such as ext:: (which run commands), and anything that could be read as a git option.
func ValidateCloneURL(url string) error {
	if url == "" || strings.HasPrefix(url, "-") || strings.ContainsAny(url, " \t\r\n") {
		return fmt.Errorf("%q is not a clone URL", url)
	}
	for _, scheme := range []string{"https://", "ssh://", "git://"} {
		if strings.HasPrefix(url, scheme) && len(url) > len(scheme) {
			return nil
		}
	}
	if scpPattern.MatchString(url) {
		return nil
	}
	return fmt.Errorf("%q is not an https, ssh or git URL", url)
}

// CloneRequest describes a repository to clone into Location/Name.
type CloneRequest struct {
	URL      string `json:"url"`
	Location string `json:"location"`
	Name     string `json:"name"` // defaults to the repository name
}

// Clone runs `git clone` with the user's git, so credential helpers and ssh config behave as in a terminal.
func Clone(ctx context.Context, request CloneRequest) (Info, error) {
	if err := ValidateCloneURL(request.URL); err != nil {
		return Info{}, err
	}
	return cloneInto(ctx, request, "https:ssh:git")
}

// cloneInto clones with only the given transports allowed (git's GIT_ALLOW_PROTOCOL); tests add "file".
func cloneInto(ctx context.Context, request CloneRequest, protocols string) (Info, error) {
	name := request.Name
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(strings.ReplaceAll(request.URL, ":", "/")), ".git")
	}
	if err := ValidateName(name); err != nil {
		return Info{}, err
	}
	if !filepath.IsAbs(request.Location) {
		return Info{}, errors.New("location must be an absolute path")
	}
	root := filepath.Join(request.Location, name)
	created, err := prepareEmptyFolder(root)
	if err != nil {
		return Info{}, err
	}
	command := exec.CommandContext(ctx, "git", "clone", "--quiet", "--", request.URL, root)
	// Only the transports a user expects; ext:: and friends stay off even if a URL slips past validation.
	command.Env = append(os.Environ(), "GIT_ALLOW_PROTOCOL="+protocols, "GIT_TERMINAL_PROMPT=0")
	if output, err := command.CombinedOutput(); err != nil {
		if created {
			os.RemoveAll(root)
		}
		return Info{}, fmt.Errorf("git clone: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return Inspect(root), nil
}
