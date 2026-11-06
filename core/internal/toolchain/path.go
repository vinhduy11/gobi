package toolchain

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// A program started from Finder or the Dock gets only the system PATH (/usr/bin:/bin:/usr/sbin:/sbin), so the go in
// /usr/local/go/bin or /opt/homebrew/bin is not found although a terminal finds it. ExtendPath adds the places Go tools
// usually live, after the entries already there so that a PATH the user set wins.

// KnownToolDirs lists the directories where go, gopls, dlv and git are usually installed on a Mac or Linux machine.
func KnownToolDirs(home string) []string {
	dirs := []string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/go/bin"}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, "go", "bin"))
	}
	return dirs
}

// SystemPathDirs reads the directories macOS adds to every login PATH: /etc/paths and the files in /etc/paths.d (the Go
// installer puts /usr/local/go/bin there).
func SystemPathDirs() []string {
	files := []string{"/etc/paths"}
	if more, err := filepath.Glob("/etc/paths.d/*"); err == nil {
		files = append(files, more...)
	}
	var dirs []string
	for _, name := range files {
		file, err := os.Open(name)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			if line := strings.TrimSpace(scanner.Text()); line != "" && !strings.HasPrefix(line, "#") {
				dirs = append(dirs, line)
			}
		}
		file.Close()
	}
	return dirs
}

// ExtendPath returns path followed by those of systemDirs and KnownToolDirs(home) that exist (per exists) and are not in
// path yet, each once, in that order.
func ExtendPath(path, home string, systemDirs []string, exists func(string) bool) string {
	parts := filepath.SplitList(path)
	have := make(map[string]bool, len(parts))
	for _, p := range parts {
		have[p] = true
	}
	for _, dir := range append(append([]string{}, systemDirs...), KnownToolDirs(home)...) {
		if dir == "" || have[dir] || !exists(dir) {
			continue
		}
		have[dir] = true
		parts = append(parts, dir)
	}
	return strings.Join(parts, string(os.PathListSeparator))
}

// ExtendProcessPath applies ExtendPath to this process's PATH, so every program gobid starts (go, gopls, dlv, git) and its own
// lookups see the same directories.
func ExtendProcessPath() {
	home, _ := os.UserHomeDir()
	exists := func(dir string) bool {
		info, err := os.Stat(dir)
		return err == nil && info.IsDir()
	}
	_ = os.Setenv("PATH", ExtendPath(os.Getenv("PATH"), home, SystemPathDirs(), exists))
}
