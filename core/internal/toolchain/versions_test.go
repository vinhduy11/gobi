package toolchain

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const releasesJSON = `[
 {"version":"go1.26.6","stable":true},
 {"version":"go1.26.5","stable":true},
 {"version":"go1.27rc1","stable":false},
 {"version":"go1.25.10","stable":true},
 {"version":"go1.25.9","stable":true},
 {"version":"go1.24.12","stable":true},
 {"version":"go1.23.12","stable":true},
 {"version":"go1.22.12","stable":true}
]`

func TestAvailableListsTheNewestPatchOfEachRecentMinor(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("mode") != "json" {
			t.Errorf("query = %q", r.URL.RawQuery)
		}
		w.Write([]byte(releasesJSON))
	}))
	defer server.Close()
	got, err := Available(context.Background(), server.URL, 4)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"1.26.6", "1.25.10", "1.24.12", "1.23.12"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestAvailableReportsABadReply(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no", 500) }))
	defer server.Close()
	if _, err := Available(context.Background(), server.URL, 4); err == nil {
		t.Error("expected an error for a 500")
	}
}

func TestValidVersion(t *testing.T) {
	for _, ok := range []string{"1.25.10", "1.26", "1.9.2"} {
		if !ValidVersion(ok) {
			t.Errorf("%q should be valid", ok)
		}
	}
	for _, bad := range []string{"", "go1.25", "1.25.10; rm -rf /", "../1.2", "1.2.3.4", "latest", "1.25rc1"} {
		if ValidVersion(bad) {
			t.Errorf("%q should be refused", bad)
		}
	}
}

func TestInstallVersionRunsGoInstallThenDownload(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "gobin")
	pathDir := t.TempDir()
	log := filepath.Join(home, "log.txt")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	// A fake `go`: "install golang.org/dl/go1.9.9@latest" creates a fake go1.9.9 in $GOBIN, which on "download" makes ~/sdk/go1.9.9/bin/go.
	fakeGo := "#!/bin/sh\necho \"go $@\" >> " + log + "\ncat > \"$GOBIN/go1.9.9\" <<'EOS'\n#!/bin/sh\necho \"go1.9.9 $@\" >> " + log + "\nmkdir -p \"$HOME/sdk/go1.9.9/bin\"\nprintf '#!/bin/sh\\n' > \"$HOME/sdk/go1.9.9/bin/go\"\nchmod +x \"$HOME/sdk/go1.9.9/bin/go\"\nEOS\nchmod +x \"$GOBIN/go1.9.9\"\n"
	if err := os.WriteFile(filepath.Join(pathDir, "go"), []byte(fakeGo), 0o755); err != nil {
		t.Fatal(err)
	}
	finder := Finder{Env: map[string]string{"PATH": pathDir, "GOBIN": bin}}
	if err := InstallVersion(context.Background(), finder, home, "1.9.9"); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(log)
	if !strings.Contains(string(got), "go install golang.org/dl/go1.9.9@latest") || !strings.Contains(string(got), "go1.9.9 download") {
		t.Errorf("log:\n%s", got)
	}
	if _, err := os.Stat(filepath.Join(home, "sdk", "go1.9.9", "bin", "go")); err != nil {
		t.Error("the version was not installed under ~/sdk")
	}
}

func TestInstallVersionRefusesABadVersionAndMissingGo(t *testing.T) {
	if err := InstallVersion(context.Background(), Finder{Env: map[string]string{"PATH": t.TempDir()}}, t.TempDir(), "1.2; x"); err == nil {
		t.Error("a bad version must be refused")
	}
	if err := InstallVersion(context.Background(), Finder{Env: map[string]string{"PATH": t.TempDir()}}, t.TempDir(), "1.9.9"); err == nil {
		t.Error("without go the install must fail")
	}
}
