package generate

import "gobi/core/internal/wire"

// Field numbers (protobuf wire format, see package wire). Never reuse a number.
//
//	request (generate/list, generate/preview, generate/render):
//	  1 path, 2 package, 3 caret line, 4 caret column, 5 kind, 6 symbol name,
//	  7 field (repeated: 1 name, 2 type, 3 underlying type), 8 source (the live buffer), 9 version, 10 item id,
//	  11 selected field name (repeated), 12 name asked by the dialog,
//	  13 method (repeated: 1 name, 2 param (repeated, as 7), 3 result type (repeated)),
//	  14 func parameter (repeated, as 7), 15 func result type (repeated), 16 receiver type
//	list result: 1 version, 2 item (repeated: 1 id, 2 title, 3 detail, 4 needs name, 5 needs fields)
//	preview and render result: 1 version, 2 text, 3 import path (repeated),
//	  4 edit (repeated: 1 start line, 2 start char, 3 end line, 4 end char (0-based, UTF-16), 5 text),
//	  5 file (repeated: 1 path, 2 content)

func decodeField(data []byte) (Field, error) {
	parts, err := wire.Parse(data)
	if err != nil {
		return Field{}, err
	}
	var f Field
	for _, p := range parts {
		switch p.Number {
		case 1:
			f.Name = string(p.Bytes)
		case 2:
			f.Type = string(p.Bytes)
		case 3:
			f.Underlying = string(p.Bytes)
		}
	}
	return f, nil
}

func decodeMethod(data []byte) (Method, error) {
	parts, err := wire.Parse(data)
	if err != nil {
		return Method{}, err
	}
	var m Method
	for _, p := range parts {
		switch p.Number {
		case 1:
			m.Name = string(p.Bytes)
		case 2:
			f, err := decodeField(p.Bytes)
			if err != nil {
				return Method{}, err
			}
			m.Params = append(m.Params, f)
		case 3:
			m.Results = append(m.Results, string(p.Bytes))
		}
	}
	return m, nil
}

// DecodeRequest reads the params of generate/list, generate/preview and generate/render.
func DecodeRequest(fields []wire.Field) (Request, error) {
	var r Request
	for _, f := range fields {
		switch f.Number {
		case 1:
			r.Path = string(f.Bytes)
		case 2:
			r.Package = string(f.Bytes)
		case 3:
			r.Line = int(f.Uint)
		case 4:
			r.Col = int(f.Uint)
		case 5:
			r.Kind = string(f.Bytes)
		case 6:
			r.Context.Name = string(f.Bytes)
		case 7, 14:
			field, err := decodeField(f.Bytes)
			if err != nil {
				return Request{}, err
			}
			if f.Number == 7 {
				r.Fields = append(r.Fields, field)
			} else {
				r.Params = append(r.Params, field)
			}
		case 8:
			r.Source = string(f.Bytes)
		case 9:
			r.Version = f.Uint
		case 10:
			r.Item = string(f.Bytes)
		case 11:
			r.Selected = append(r.Selected, string(f.Bytes))
		case 12:
			r.AskedName = string(f.Bytes)
		case 13:
			m, err := decodeMethod(f.Bytes)
			if err != nil {
				return Request{}, err
			}
			r.Methods = append(r.Methods, m)
		case 15:
			r.Results = append(r.Results, string(f.Bytes))
		case 16:
			r.Receiver = string(f.Bytes)
		}
	}
	return r, nil
}

// EncodeList writes the result of generate/list.
func EncodeList(version uint64, items []Item) []byte {
	var w wire.Writer
	w.Uint(1, version)
	for _, item := range items {
		w.Message(2, func(m *wire.Writer) {
			m.String(1, item.ID)
			m.String(2, item.Title)
			m.String(3, item.Detail)
			if item.NeedsName {
				m.Bool(4, true)
			}
			if item.NeedsFields {
				m.Bool(5, true)
			}
		})
	}
	return w.Bytes()
}

// EncodeResult writes the result of generate/preview and generate/render.
func EncodeResult(r Result) []byte {
	var w wire.Writer
	w.Uint(1, r.Version)
	w.String(2, r.Text)
	for _, path := range r.Imports {
		w.Raw(3, []byte(path))
	}
	for _, e := range r.Edits {
		w.Message(4, func(m *wire.Writer) {
			m.Uint(1, uint64(e.StartLine))
			m.Uint(2, uint64(e.StartChar))
			m.Uint(3, uint64(e.EndLine))
			m.Uint(4, uint64(e.EndChar))
			m.String(5, e.Text)
		})
	}
	for _, f := range r.Files {
		w.Message(5, func(m *wire.Writer) { m.String(1, f.Path); m.String(2, f.Content) })
	}
	return w.Bytes()
}
