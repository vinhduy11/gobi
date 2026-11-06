package generate

import (
	"bytes"
	"encoding/hex"
	"reflect"
	"testing"

	"gobi/core/internal/wire"
)

func sampleRequest() Request {
	return Request{
		Version: 3, Item: ItemString, Selected: []string{"a"}, AskedName: "x",
		GoVersion: "1.23", Target: TargetFile,
		Values: []ParamValue{{Key: "strategies", Values: []string{"Fast", "Safe"}}, {Key: "strategy", Values: []string{"Pricing"}}},
		Context: Context{
			Path: "/p/a.go", Package: "demo", Source: "package demo\n", Line: 2, Col: 5, Kind: KindStruct, Name: "T",
			Fields:  []Field{{Name: "a", Type: "string", Underlying: "string"}},
			Methods: []Method{{Name: "M", Params: []Field{{Name: "x", Type: "int"}}, Results: []string{"error"}}},
			Params:  []Field{{Name: "p", Type: "int"}}, Results: []string{"error"}, Receiver: "R",
		},
	}
}

func encodeRequest(r Request) []byte {
	var w wire.Writer
	field := func(w *wire.Writer, number int, f Field) {
		w.Message(number, func(m *wire.Writer) { m.String(1, f.Name); m.String(2, f.Type); m.String(3, f.Underlying) })
	}
	w.String(1, r.Path)
	w.String(2, r.Package)
	w.Uint(3, uint64(r.Line))
	w.Uint(4, uint64(r.Col))
	w.String(5, r.Kind)
	w.String(6, r.Name)
	for _, f := range r.Fields {
		field(&w, 7, f)
	}
	w.String(8, r.Source)
	w.Uint(9, r.Version)
	w.String(10, r.Item)
	for _, s := range r.Selected {
		w.Raw(11, []byte(s))
	}
	w.String(12, r.AskedName)
	for _, m := range r.Methods {
		w.Message(13, func(mw *wire.Writer) {
			mw.String(1, m.Name)
			for _, p := range m.Params {
				field(mw, 2, p)
			}
			for _, res := range m.Results {
				mw.Raw(3, []byte(res))
			}
		})
	}
	for _, p := range r.Params {
		field(&w, 14, p)
	}
	for _, res := range r.Results {
		w.Raw(15, []byte(res))
	}
	w.String(16, r.Receiver)
	w.String(17, r.GoVersion)
	for _, v := range r.Values {
		w.Message(18, func(m *wire.Writer) {
			m.String(1, v.Key)
			for _, value := range v.Values {
				m.Raw(2, []byte(value))
			}
		})
	}
	w.String(19, r.Target)
	return w.Bytes()
}

func TestRequestDecodes(t *testing.T) {
	want := sampleRequest()
	fields, err := wire.Parse(encodeRequest(want))
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeRequest(fields)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got  %+v\nwant %+v", got, want)
	}
}

// Golden bytes: the Swift client asserts the same bytes.
func TestResultGoldenBytes(t *testing.T) {
	list := EncodeList(9, []Item{{ID: "string", Title: "String() method", NeedsFields: true}})
	wantList := []byte{0x08, 0x09, 0x12, 0x1b, 0x0a, 0x06, 's', 't', 'r', 'i', 'n', 'g', 0x12, 0x0f, 'S', 't', 'r', 'i', 'n', 'g', '(', ')', ' ', 'm', 'e', 't', 'h', 'o', 'd', 0x28, 0x01}
	if !bytes.Equal(list, wantList) {
		t.Errorf("list bytes = % x\nwant        % x", list, wantList)
	}
	render := EncodeResult(Result{Version: 2, Text: "x", Imports: []string{"fmt"}, Edits: []Edit{{1, 2, 3, 4, "t"}}, Files: []File{{Path: "a", Content: "b"}}})
	wantRender := []byte{
		0x08, 0x02, 0x12, 0x01, 'x', 0x1a, 0x03, 'f', 'm', 't',
		0x22, 0x0b, 0x08, 0x01, 0x10, 0x02, 0x18, 0x03, 0x20, 0x04, 0x2a, 0x01, 't',
		0x2a, 0x06, 0x0a, 0x01, 'a', 0x12, 0x01, 'b',
	}
	if !bytes.Equal(render, wantRender) {
		t.Errorf("render bytes = % x\nwant          % x", render, wantRender)
	}
}

// A pattern item adds a group (6) and its parameters (7: 1 key, 2 label, 3 default (repeated), 4 kind, 5 multi).
func TestPatternItemGoldenBytes(t *testing.T) {
	list := EncodeList(1, []Item{{ID: "strategy", Title: "Strategy", Group: "behavioral",
		Params: []ParamSpec{{Key: "k", Label: "L", Kind: "type", Default: []string{"D"}}, {Key: "m", Kind: "names", Multi: true}}}})
	want := []byte{0x08, 0x01, 0x12, 0x3f,
		0x0a, 0x08, 's', 't', 'r', 'a', 't', 'e', 'g', 'y', 0x12, 0x08, 'S', 't', 'r', 'a', 't', 'e', 'g', 'y',
		0x32, 0x0a, 'b', 'e', 'h', 'a', 'v', 'i', 'o', 'r', 'a', 'l',
		0x3a, 0x0f, 0x0a, 0x01, 'k', 0x12, 0x01, 'L', 0x1a, 0x01, 'D', 0x22, 0x04, 't', 'y', 'p', 'e',
		0x3a, 0x0c, 0x0a, 0x01, 'm', 0x22, 0x05, 'n', 'a', 'm', 'e', 's', 0x28, 0x01,
	}
	if !bytes.Equal(list, want) {
		t.Errorf("bytes = % x\nwant    % x", list, want)
	}
}

// Golden bytes of a whole request: the Swift client asserts the same bytes (GenerateWireTests).
const requestGoldenHex = "0a072f702f612e676f120464656d6f180220052a067374727563743201543a130a01611206737472696e671a06737472696e67420d7061636b6167652064656d6f0a48035206737472696e675a01616201786a140a014d12080a01781203696e741a056572726f7272080a01701203696e747a056572726f72820101528a0104312e32339201180a0a737472617465676965731204466173741204536166659201130a087374726174656779120750726963696e679a010466696c65"

func TestRequestGoldenBytes(t *testing.T) {
	got := hex.EncodeToString(encodeRequest(sampleRequest()))
	if got != requestGoldenHex {
		t.Errorf("request bytes = %s", got)
	}
}
