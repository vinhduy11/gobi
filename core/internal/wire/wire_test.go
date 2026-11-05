package wire

import (
	"bytes"
	"testing"
)

// The vectors come from the protobuf encoding guide, so the format stays compatible with generated protobuf code.
func TestEncodingMatchesProtobufGoldenVectors(t *testing.T) {
	var w Writer
	w.Uint(1, 150)
	if want := []byte{0x08, 0x96, 0x01}; !bytes.Equal(w.Bytes(), want) {
		t.Fatalf("uint 150 as field 1 = % x, want % x", w.Bytes(), want)
	}
	w = Writer{}
	w.String(2, "testing")
	if want := []byte{0x12, 0x07, 't', 'e', 's', 't', 'i', 'n', 'g'}; !bytes.Equal(w.Bytes(), want) {
		t.Fatalf("string = % x, want % x", w.Bytes(), want)
	}
	w = Writer{}
	w.Message(3, func(inner *Writer) { inner.Uint(1, 150) })
	if want := []byte{0x1a, 0x03, 0x08, 0x96, 0x01}; !bytes.Equal(w.Bytes(), want) {
		t.Fatalf("nested = % x, want % x", w.Bytes(), want)
	}
}

func TestReadBackWhatWasWritten(t *testing.T) {
	var w Writer
	w.Uint(1, 7)
	w.String(2, "héllo")
	w.Bool(3, true)
	w.Bool(4, false)
	w.Message(5, func(inner *Writer) { inner.String(1, "inner") })

	fields, err := Parse(w.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if len(fields) != 5 {
		t.Fatalf("got %d fields, want 5", len(fields))
	}
	if fields[0].Number != 1 || fields[0].Uint != 7 {
		t.Errorf("field 1 = %+v", fields[0])
	}
	if string(fields[1].Bytes) != "héllo" {
		t.Errorf("field 2 = %q", fields[1].Bytes)
	}
	if fields[2].Uint != 1 || fields[3].Uint != 0 {
		t.Errorf("bools = %d, %d", fields[2].Uint, fields[3].Uint)
	}
	inner, err := Parse(fields[4].Bytes)
	if err != nil || len(inner) != 1 || string(inner[0].Bytes) != "inner" {
		t.Errorf("nested = %+v (%v)", inner, err)
	}
}

func TestParseRejectsDamagedInput(t *testing.T) {
	tests := map[string][]byte{
		"cut varint":          {0x08, 0x96},
		"length past the end": {0x12, 0x09, 'a'},
		"fixed32 not used":    {0x0d, 1, 2, 3, 4},
		"field number zero":   {0x00, 0x01},
		"varint too long":     {0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01},
	}
	for name, input := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse(input); err == nil {
				t.Fatalf("Parse(% x) accepted damaged input", input)
			}
		})
	}
}

func TestUnknownFieldsAreKept(t *testing.T) {
	var w Writer
	w.Uint(1, 1)
	w.String(99, "from a newer client")
	fields, err := Parse(w.Bytes())
	if err != nil || len(fields) != 2 || fields[1].Number != 99 {
		t.Fatalf("unknown field handling: %+v (%v)", fields, err)
	}
}

func FuzzParse(f *testing.F) {
	f.Add([]byte{0x08, 0x96, 0x01})
	f.Add([]byte{0x12, 0x03, 'a', 'b', 'c'})
	f.Fuzz(func(t *testing.T, data []byte) {
		fields, err := Parse(data)
		if err != nil {
			return
		}
		var w Writer
		for _, field := range fields {
			if field.IsBytes {
				w.Raw(field.Number, field.Bytes)
			} else {
				w.Uint(field.Number, field.Uint)
			}
		}
		again, err := Parse(w.Bytes())
		if err != nil || len(again) != len(fields) {
			t.Fatalf("re-encoding changed the fields: %v", err)
		}
	})
}
