//go:build unix

package runner

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// NoEnvFile in Request.EnvFile turns the environment file off.
const NoEnvFile = "-"

const maxEnvFile = 1 << 20

var envKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// loadEnvFile returns KEY=VALUE pairs for a run. An empty choice means the project's own .env when it exists; NoEnvFile means
// none; anything else names a file inside the project folder, which must exist. Values are never logged.
func loadEnvFile(dir, choice string) ([]string, error) {
	switch choice {
	case NoEnvFile:
		return nil, nil
	case "":
		choice = ".env"
		if _, err := os.Stat(filepath.Join(dir, choice)); errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
	}
	if filepath.IsAbs(choice) || strings.HasPrefix(filepath.Clean(choice), "..") {
		return nil, fmt.Errorf("the environment file must be inside the project: %q", choice)
	}
	path := filepath.Join(dir, choice)
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the environment file %q: %w", choice, err)
	}
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, err
	}
	if rel, err := filepath.Rel(root, real); err != nil || strings.HasPrefix(rel, "..") {
		return nil, fmt.Errorf("the environment file must be inside the project: %q", choice)
	}
	info, err := os.Stat(real)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxEnvFile {
		return nil, fmt.Errorf("cannot use %q as an environment file", choice)
	}
	data, err := os.ReadFile(real)
	if err != nil {
		return nil, err
	}
	return parseEnvFile(string(data)), nil
}

// parseEnvFile reads the common .env dialect: KEY=VALUE lines, optional `export `, # comments, and single or double quotes
// around a value. There is no variable expansion. Lines that are not assignments are skipped.
func parseEnvFile(text string) []string {
	var pairs []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		key, value, found := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !found || !envKey.MatchString(key) {
			continue
		}
		value = strings.TrimSpace(value)
		if n := len(value); n >= 2 && (value[0] == '"' || value[0] == '\'') && value[n-1] == value[0] {
			value = value[1 : n-1]
		} else if i := strings.Index(value, " #"); i >= 0 {
			value = strings.TrimSpace(value[:i])
		}
		pairs = append(pairs, key+"="+value)
	}
	return pairs
}
