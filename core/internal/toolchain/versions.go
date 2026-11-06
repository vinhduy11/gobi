package toolchain

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ReleasesURL lists the Go releases as JSON when asked with ?mode=json.
const ReleasesURL = "https://go.dev/dl/"

var versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+(\.[0-9]+)?$`)

// ValidVersion accepts "1.25" and "1.25.10": numbers only, so a version can never smuggle anything into a command.
func ValidVersion(version string) bool { return versionPattern.MatchString(version) }

// Available returns the newest stable patch release of each of the last `count` minor versions, newest first.
func Available(ctx context.Context, releasesURL string, count int) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, releasesURL+"?mode=json", nil)
	if err != nil {
		return nil, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("cannot reach the Go release list: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the Go release list answered %s", response.Status)
	}
	var releases []struct {
		Version string `json:"version"`
		Stable  bool   `json:"stable"`
	}
	if err := json.NewDecoder(response.Body).Decode(&releases); err != nil {
		return nil, fmt.Errorf("unreadable Go release list: %w", err)
	}
	newest := map[string]string{} // "1.25" -> "1.25.10"
	for _, release := range releases {
		version := strings.TrimPrefix(release.Version, "go")
		if !release.Stable || !ValidVersion(version) {
			continue
		}
		minor := strings.Join(strings.SplitN(version, ".", 3)[:2], ".")
		if current, ok := newest[minor]; !ok || newer(version, current) {
			newest[minor] = version
		}
	}
	versions := make([]string, 0, len(newest))
	for _, version := range newest {
		versions = append(versions, version)
	}
	sort.Slice(versions, func(i, j int) bool { return newer(versions[i], versions[j]) })
	if len(versions) > count {
		versions = versions[:count]
	}
	return versions, nil
}

// newer compares dotted numbers part by part ("1.25.10" is newer than "1.25.9").
func newer(a, b string) bool {
	x, y := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(x) || i < len(y); i++ {
		left, right := -1, -1
		if i < len(x) {
			left, _ = strconv.Atoi(x[i])
		}
		if i < len(y) {
			right, _ = strconv.Atoi(y[i])
		}
		if left != right {
			return left > right
		}
	}
	return false
}

// InstallVersion installs a Go version the way golang.org/dl documents: `go install golang.org/dl/goX@latest`, then
// `goX download`, which unpacks it into ~/sdk/goX. It downloads from the internet, so a caller runs it only after the user agreed.
func InstallVersion(ctx context.Context, finder Finder, home, version string) error {
	if !ValidVersion(version) {
		return fmt.Errorf("%q is not a Go version number", version)
	}
	goPath, err := finder.Find("go")
	if err != nil {
		return fmt.Errorf("go is needed to install Go %s, and it was not found. %s", version, Hint("go"))
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	environment := append(os.Environ(), "HOME="+home, "GOTOOLCHAIN=local")
	if gobin := finder.Env["GOBIN"]; gobin != "" {
		environment = append(environment, "GOBIN="+gobin)
	}
	name := "go" + version
	install := exec.CommandContext(ctx, goPath, "install", "golang.org/dl/"+name+"@latest")
	install.Env = environment
	if out, err := install.CombinedOutput(); err != nil {
		return fmt.Errorf("go install golang.org/dl/%s failed: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	downloader, err := finder.Find(name)
	if err != nil {
		return fmt.Errorf("%s was installed but is not on the search path: %w", name, err)
	}
	download := exec.CommandContext(ctx, downloader, "download")
	download.Env = environment
	if out, err := download.CombinedOutput(); err != nil {
		return fmt.Errorf("%s download failed: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	if _, err := os.Stat(filepath.Join(home, "sdk", name, "bin", "go")); err != nil {
		return fmt.Errorf("%s did not appear under ~/sdk", name)
	}
	return nil
}
