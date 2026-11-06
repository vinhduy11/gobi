//go:build unix

package runner

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseEnvFile(t *testing.T) {
	text := "# comment\n\nA=1\nexport B=two words\nC=\"quoted # not a comment\"\nD='single $x'\nE=plain # trailing\n  F = spaced  \nbad line\n=novalue\nG=a=b\n"
	got := parseEnvFile(text)
	want := []string{"A=1", "B=two words", "C=quoted # not a comment", "D=single $x", "E=plain", "F=spaced", "G=a=b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestEnvFileChoice(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("X=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "other.env"), []byte("X=2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		file string
		want []string
		err  bool
	}{
		"auto picks .env":          {"", []string{"X=1"}, false},
		"named file":               {"other.env", []string{"X=2"}, false},
		"none":                     {NoEnvFile, nil, false},
		"missing named file fails": {"nope.env", nil, true},
		"escape is refused":        {"../x.env", nil, true},
		"absolute is refused":      {"/etc/passwd", nil, true},
	}
	for name, c := range cases {
		got, err := loadEnvFile(dir, c.file)
		if (err != nil) != c.err || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q, %v", name, got, err)
		}
	}
	empty := t.TempDir()
	if got, err := loadEnvFile(empty, ""); err != nil || got != nil {
		t.Errorf("no .env present: got %q, %v", got, err)
	}
}

func TestRunSeesTheEnvFile(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"main.go": "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() { fmt.Println(\"value=\" + os.Getenv(\"GOBI_FROM_ENV_FILE\")) }\n",
		".env":    "GOBI_FROM_ENV_FILE=hello\n",
	})
	run, err := Start(context.Background(), Request{Kind: KindRun, Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	for _, event := range collect(t, run) {
		out.Write(event.Data)
	}
	if !strings.Contains(out.String(), "value=hello") {
		t.Errorf("output = %q", out.String())
	}
}

func TestRunSeesTheProfileEnvironmentAboveTheEnvFile(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"main.go": "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() { fmt.Println(\"a=\" + os.Getenv(\"GOBI_A\") + \" b=\" + os.Getenv(\"GOBI_B\")) }\n",
		".env":    "GOBI_A=file\nGOBI_B=file\n",
	})
	run, err := Start(context.Background(), Request{Kind: KindRun, Dir: dir, Env: []string{"GOBI_B=profile"}})
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	for _, event := range collect(t, run) {
		out.Write(event.Data)
	}
	if !strings.Contains(out.String(), "a=file b=profile") {
		t.Errorf("output = %q", out.String())
	}
}

func TestEnvironmentEntriesAreChecked(t *testing.T) {
	dir := writeModule(t, map[string]string{})
	bad := [][]string{{"1A=x"}, {"A B=x"}, {"NOEQUALS"}, {"=x"}, {"DYLD_INSERT_LIBRARIES=/x"}, {"LD_PRELOAD=/x"}, {"A=b\x00c"}, make([]string, 600)}
	for i, env := range bad {
		if _, err := Start(context.Background(), Request{Kind: KindVet, Dir: dir, Env: env}); err == nil {
			t.Errorf("case %d (%q) should be refused", i, env)
		}
	}
}
