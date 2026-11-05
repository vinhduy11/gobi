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
}

// Info says what a project folder is.
type Info struct {
	Root       string `json:"root"`
	Kind       string `json:"kind"`
	ModulePath string `json:"module_path,omitempty"`
}

// Create makes a new project folder under Location. It refuses a destination that already has files.
func Create(request NewRequest) (Info, error) {
	if err := ValidateName(request.Name); err != nil {
		return Info{}, err
	}
	if !filepath.IsAbs(request.Location) {
		return Info{}, errors.New("location must be an absolute path")
	}
	modulePath := request.ModulePath
	if modulePath == "" {
		modulePath = request.Name
	}
	if !modulePattern.MatchString(modulePath) {
		return Info{}, fmt.Errorf("module path %q is not valid", modulePath)
	}
	if request.GoVersion != "" && !goVersionPattern.MatchString(request.GoVersion) {
		return Info{}, fmt.Errorf("go version %q is not valid", request.GoVersion)
	}
	moduleTemplate := request.Template
	if moduleTemplate == TemplateWorkspace {
		moduleTemplate = TemplateCLI
	}
	files, err := Render(moduleTemplate, modulePath, request.Name)
	if err != nil && request.Template != TemplateWorkspace {
		return Info{}, err
	}

	root := filepath.Join(request.Location, request.Name)
	created, err := prepareEmptyFolder(root)
	if err != nil {
		return Info{}, err
	}
	info, err := populate(request, root, modulePath, files)
	if err != nil {
		if created {
			os.RemoveAll(root) // only a folder this call made; an existing empty one is left in place
		}
		return Info{}, err
	}
	return info, nil
}

func populate(request NewRequest, root, modulePath string, files map[string]string) (Info, error) {
	moduleDir := root
	kind := KindModule
	if request.Template == TemplateWorkspace {
		moduleDir = filepath.Join(root, "app")
		if err := os.MkdirAll(moduleDir, 0o755); err != nil {
			return Info{}, err
		}
		kind = KindWorkspace
	}
	if err := goModInit(moduleDir, modulePath, request.GoVersion); err != nil {
		return Info{}, err
	}
	for path, content := range files {
		if err := writeNew(filepath.Join(moduleDir, path), content); err != nil {
			return Info{}, err
		}
	}
	if request.Template == TemplateWorkspace {
		if err := run(root, "go", "work", "init", "./app"); err != nil {
			return Info{}, err
		}
	}
	if err := writeNew(filepath.Join(root, "README.md"), "# "+request.Name+"\n"); err != nil {
		return Info{}, err
	}
	if err := writeNew(filepath.Join(root, ".gitignore"), ".env\n*.test\n*.out\n/bin/\n"); err != nil {
		return Info{}, err
	}
	if request.GitInit {
		if err := run(root, "git", "init", "--quiet"); err != nil {
			return Info{}, err
		}
		// `git init -b` needs git 2.28; pointing HEAD works on every version.
		if err := run(root, "git", "symbolic-ref", "HEAD", "refs/heads/master"); err != nil {
			return Info{}, err
		}
	}
	return Info{Root: root, Kind: kind, ModulePath: modulePath}, nil
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
