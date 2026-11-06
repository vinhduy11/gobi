package toolchain

import (
	"path/filepath"
	"strings"
	"testing"
)

func existsIn(dirs ...string) func(string) bool {
	set := map[string]bool{}
	for _, d := range dirs {
		set[d] = true
	}
	return func(p string) bool { return set[p] }
}

func TestExtendPathAddsTheUsualGoPlacesThatExist(t *testing.T) {
	home := "/Users/x"
	exists := existsIn("/usr/local/go/bin", "/opt/homebrew/bin", filepath.Join(home, "go", "bin"))
	got := ExtendPath("/usr/bin:/bin", home, []string{"/usr/local/go/bin"}, exists)
	want := "/usr/bin:/bin:/usr/local/go/bin:/opt/homebrew/bin:" + filepath.Join(home, "go", "bin")
	if got != want {
		t.Fatalf("ExtendPath = %q, want %q", got, want)
	}
}

func TestExtendPathKeepsTheOrderAndNeverRepeatsOrAddsMissingDirs(t *testing.T) {
	home := "/Users/x"
	exists := existsIn("/opt/homebrew/bin", "/usr/local/go/bin")
	got := ExtendPath("/opt/homebrew/bin:/usr/bin", home, []string{"/usr/local/go/bin", "/nowhere"}, exists)
	if got != "/opt/homebrew/bin:/usr/bin:/usr/local/go/bin" {
		t.Fatalf("got %q", got)
	}
	if strings.Contains(got, "/nowhere") {
		t.Fatal("a directory that does not exist must not be added")
	}
}

func TestExtendPathOfAnEmptyPathIsJustTheKnownDirs(t *testing.T) {
	got := ExtendPath("", "/Users/x", nil, existsIn("/usr/local/bin"))
	if got != "/usr/local/bin" {
		t.Fatalf("got %q", got)
	}
}

func TestKnownToolDirsIncludesHomebrewTheGoInstallerAndTheGoBinFolder(t *testing.T) {
	dirs := KnownToolDirs("/Users/x")
	for _, want := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "/Users/x/go/bin"} {
		found := false
		for _, d := range dirs {
			if d == want {
				found = true
			}
		}
		if !found {
			t.Errorf("KnownToolDirs is missing %s: %v", want, dirs)
		}
	}
}
