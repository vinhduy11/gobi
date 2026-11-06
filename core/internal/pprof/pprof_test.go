package pprof

import (
	"bytes"
	"compress/gzip"
	"runtime"
	rpprof "runtime/pprof"
	"testing"

	"gobi/core/internal/wire"
)

// build makes a small CPU profile: main -> (work -> hash 30, work 10), main -> idle 5. Values are nanoseconds.
func build(t *testing.T, compress bool) []byte {
	t.Helper()
	strs := []string{"", "cpu", "nanoseconds", "main.main", "main.work", "main.hash", "main.idle", "main.go"}
	var p wire.Writer
	p.Message(1, func(m *wire.Writer) { m.Uint(1, 1); m.Uint(2, 2) }) // sample type cpu/nanoseconds
	sample := func(value uint64, locs ...uint64) {
		p.Message(2, func(m *wire.Writer) { m.Raw(1, varints(locs...)); m.Raw(2, varints(value)) })
	}
	sample(30, 3, 2, 1) // hash <- work <- main
	sample(10, 2, 1)    // work <- main
	sample(5, 4, 1)     // idle <- main
	loc := func(id, fn uint64, line uint64) {
		p.Message(4, func(m *wire.Writer) {
			m.Uint(1, id)
			m.Message(4, func(l *wire.Writer) { l.Uint(1, fn); l.Uint(2, line) })
		})
	}
	loc(1, 1, 10)
	loc(2, 2, 20)
	loc(3, 3, 30)
	loc(4, 4, 40)
	fn := func(id, name uint64) {
		p.Message(5, func(m *wire.Writer) { m.Uint(1, id); m.Uint(2, name); m.Uint(4, 7); m.Uint(5, id*10-2) })
	}
	fn(1, 3)
	fn(2, 4)
	fn(3, 5)
	fn(4, 6)
	for _, s := range strs {
		p.Raw(6, []byte(s))
	}
	p.Uint(10, 1_000_000_000)
	if !compress {
		return p.Bytes()
	}
	var buffer bytes.Buffer
	zip := gzip.NewWriter(&buffer)
	zip.Write(p.Bytes())
	zip.Close()
	return buffer.Bytes()
}

func varints(values ...uint64) []byte {
	var out []byte
	for _, v := range values {
		for v >= 0x80 {
			out = append(out, byte(v)|0x80)
			v >>= 7
		}
		out = append(out, byte(v))
	}
	return out
}

func TestTreeAndTotals(t *testing.T) {
	for _, compress := range []bool{true, false} {
		profile, err := Parse(build(t, compress))
		if err != nil {
			t.Fatal(err)
		}
		if len(profile.SampleTypes) != 1 || profile.SampleTypes[0] != (SampleType{"cpu", "nanoseconds"}) {
			t.Fatalf("sample types = %+v", profile.SampleTypes)
		}
		root := profile.Tree(0)
		if root.Name != "all" || root.Cum != 45 {
			t.Fatalf("root = %s %d", root.Name, root.Cum)
		}
		main := root.Children[0]
		if main.Name != "main.main" || main.Cum != 45 || main.Flat != 0 {
			t.Fatalf("main = %+v", main)
		}
		if len(main.Children) != 2 || main.Children[0].Name != "main.work" || main.Children[0].Cum != 40 || main.Children[0].Flat != 10 || main.Children[1].Name != "main.idle" {
			t.Fatalf("children of main = %+v", main.Children)
		}
		hash := main.Children[0].Children[0]
		if hash.Name != "main.hash" || hash.Flat != 30 || hash.Line != 30 || hash.File != "main.go" {
			t.Fatalf("hash = %+v", hash)
		}
	}
}

func TestTopAggregatesByFunction(t *testing.T) {
	profile, _ := Parse(build(t, true))
	top := profile.Top(0, 10)
	want := []TopRow{{"main.hash", 30, 30}, {"main.work", 10, 40}, {"main.idle", 5, 5}, {"main.main", 0, 45}}
	if len(top) != len(want) {
		t.Fatalf("top = %+v", top)
	}
	for i := range want {
		if top[i] != want[i] {
			t.Errorf("row %d = %+v, want %+v", i, top[i], want[i])
		}
	}
	if got := profile.Top(0, 2); len(got) != 2 {
		t.Errorf("limit not applied: %+v", got)
	}
}

func TestRecursionCountsCumulativeOnce(t *testing.T) {
	profile, _ := Parse(build(t, true))
	// a sample whose stack holds main.work twice must still count once toward its cumulative time
	profile.samples = append(profile.samples, sample{locations: []uint64{2, 2, 1}, values: []int64{7}})
	for _, row := range profile.Top(0, 10) {
		if row.Name == "main.work" && row.Cum != 47 {
			t.Errorf("work cum = %d, want 47", row.Cum)
		}
	}
}

func TestRealGoProfileParses(t *testing.T) {
	var buffer bytes.Buffer
	runtime.GC()
	if err := rpprof.Lookup("heap").WriteTo(&buffer, 0); err != nil {
		t.Fatal(err)
	}
	profile, err := Parse(buffer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.SampleTypes) == 0 {
		t.Fatal("no sample types")
	}
	if profile.DefaultSampleIndex() < 0 || profile.DefaultSampleIndex() >= len(profile.SampleTypes) {
		t.Errorf("default index %d out of range", profile.DefaultSampleIndex())
	}
	profile.Tree(profile.DefaultSampleIndex())
}

func TestGarbageIsRefused(t *testing.T) {
	if _, err := Parse([]byte("not a profile at all")); err == nil {
		t.Error("expected an error")
	}
	if _, err := Parse(nil); err == nil {
		t.Error("expected an error for empty input")
	}
}
