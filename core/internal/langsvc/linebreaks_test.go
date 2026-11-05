package langsvc

import "testing"

func TestPositionsFollowAllThreeLineBreaks(t *testing.T) {
	index := newLineIndex("a\rbc\r\nd\ne")
	tests := []struct {
		offset int
		want   position
	}{
		{0, position{0, 0}},
		{2, position{1, 0}}, // after the lone CR
		{4, position{1, 2}}, // end of "bc"
		{5, position{1, 2}}, // between CR and LF of the CRLF: still the end of the line
		{6, position{2, 0}}, // after the CRLF
		{8, position{3, 0}}, // after the LF
		{9, position{3, 1}},
	}
	for _, test := range tests {
		if got := index.positionAt(test.offset); got != test.want {
			t.Errorf("positionAt(%d) = %+v, want %+v", test.offset, got, test.want)
		}
	}
	if got := index.lineEnd(1); got != 4 {
		t.Errorf("lineEnd(1) = %d, want 4 (before the CRLF)", got)
	}
	if got := index.lineCount(); got != 4 {
		t.Errorf("lineCount() = %d, want 4", got)
	}
}

func TestMarkdownHeadingsOnLoneCarriageReturnLines(t *testing.T) {
	headings := headings("# A\r## B\r\n### C\rtext")
	want := []heading{{1, "A", 0}, {2, "B", 1}, {3, "C", 2}}
	if len(headings) != len(want) {
		t.Fatalf("got %+v, want %+v", headings, want)
	}
	for index := range want {
		if headings[index] != want[index] {
			t.Fatalf("got %+v, want %+v", headings, want)
		}
	}
}
