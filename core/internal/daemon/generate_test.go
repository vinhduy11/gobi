//go:build unix

package daemon

import (
	"strings"
	"testing"

	"gobi/core/internal/wire"
)

func generateParams(item string, version uint64) func(*wire.Writer) {
	return func(w *wire.Writer) {
		w.String(1, "/p/s.go")
		w.String(2, "demo")
		w.String(5, "struct")
		w.String(6, "T")
		w.Message(7, func(f *wire.Writer) { f.String(1, "a"); f.String(2, "string") })
		w.String(8, "package demo\n\ntype T struct{ a string }\n")
		w.Uint(9, version)
		w.String(10, item)
	}
}

func TestGenerateListEchoesTheVersionAndOffersStructItems(t *testing.T) {
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "generate/list", generateParams("", 41))
	if failure != "" {
		t.Fatal(failure)
	}
	if result[1].Uint != 41 {
		t.Errorf("version = %d, want 41", result[1].Uint)
	}
	last, _ := wire.Parse(result[2].Bytes) // the last item: error-type
	if len(last) == 0 || string(last[0].Bytes) != "error-type" {
		t.Errorf("last item = %+v", last)
	}
}

func TestGenerateRenderReturnsEditsAndEchoesTheVersion(t *testing.T) {
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "generate/render", generateParams("string", 42))
	if failure != "" {
		t.Fatal(failure)
	}
	if result[1].Uint != 42 {
		t.Errorf("version = %d, want 42", result[1].Uint)
	}
	if !strings.Contains(string(result[2].Bytes), "func (t *T) String() string") {
		t.Errorf("text = %q", result[2].Bytes)
	}
	if string(result[3].Bytes) != "fmt" {
		t.Errorf("import = %q", result[3].Bytes)
	}
	if len(result[4].Bytes) == 0 {
		t.Error("render must return edits")
	}
}

func TestGeneratePreviewHasNoEdits(t *testing.T) {
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "generate/preview", generateParams("constructor", 5))
	if failure != "" {
		t.Fatal(failure)
	}
	if !strings.Contains(string(result[2].Bytes), "func NewT(a string) *T") {
		t.Errorf("text = %q", result[2].Bytes)
	}
	if _, ok := result[4]; ok {
		t.Error("preview must not carry edits")
	}
}

func TestGenerateRefusesAnItemThatDoesNotApply(t *testing.T) {
	session := controlSession(t)
	_, failure := controlCall(t, session, 1, "generate/render", generateParams("mock", 1))
	if !strings.Contains(failure, "does not apply") {
		t.Errorf("failure = %q", failure)
	}
}
