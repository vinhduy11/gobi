package pprof

import "testing"

func TestLinesGivePerLineCost(t *testing.T) {
	p, err := Parse(build(t, true))
	if err != nil {
		t.Fatal(err)
	}
	file, start, rows := p.Lines(0, "main.work")
	if start != 18 {
		t.Fatalf("start line = %d", start)
	}
	if file != "main.go" || len(rows) != 1 || rows[0] != (LineRow{Line: 20, Flat: 10, Cum: 40}) {
		t.Fatalf("work: %q %+v", file, rows)
	}
	_, _, rows = p.Lines(0, "main.main")
	if len(rows) != 1 || rows[0] != (LineRow{Line: 10, Flat: 0, Cum: 45}) {
		t.Fatalf("main: %+v", rows)
	}
	if _, _, rows = p.Lines(0, "nope"); len(rows) != 0 {
		t.Fatalf("unknown function: %+v", rows)
	}
}

func TestDiffSortsByAbsoluteDelta(t *testing.T) {
	a, _ := Parse(build(t, true))
	b, _ := Parse(build(t, true))
	b.samples = []sample{{locations: []uint64{3, 2, 1}, values: []int64{5}}, {locations: []uint64{4, 1}, values: []int64{25}}} // hash 30->5, idle 5->25
	if b.SampleIndex("cpu") != 0 || b.SampleIndex("nope") != -1 {
		t.Fatal("SampleIndex")
	}
	rows := Diff(a, b, 0, 0, 0)
	if len(rows) < 2 || rows[0].Name != "main.hash" || rows[0].BaseFlat != 30 || rows[0].NewFlat != 5 {
		t.Fatalf("rows: %+v", rows)
	}
	if rows[1].Name != "main.idle" || rows[1].NewFlat-rows[1].BaseFlat != 20 {
		t.Fatalf("second: %+v", rows[1])
	}
	if limited := Diff(a, b, 0, 0, 1); len(limited) != 1 {
		t.Fatalf("limit: %d", len(limited))
	}
}
