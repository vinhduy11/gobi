// Package wire encodes the small messages gobid and the UI exchange (handshake, project requests) in the protobuf
// wire format: numbered fields, varints and length-delimited values. It is hand-coded so there is no generated code or
// dependency, and any protobuf library can read the bytes, so a schema file can replace it later.
//
// Only wire types 0 (varint) and 2 (length-delimited) exist here; every message is small, so fixed-width fields are not
// needed. Unknown fields are kept and ignored by callers, which is how a newer peer adds fields.
package wire

import (
	"errors"
	"fmt"
)

const (
	typeVarint = 0
	typeBytes  = 2

	maxVarintBytes = 10
)

// Writer builds one message.
type Writer struct{ buf []byte }

// Bytes returns the encoded message.
func (w *Writer) Bytes() []byte { return w.buf }

func (w *Writer) varint(value uint64) {
	for value >= 0x80 {
		w.buf = append(w.buf, byte(value)|0x80)
		value >>= 7
	}
	w.buf = append(w.buf, byte(value))
}

func (w *Writer) tag(number int, wireType int) { w.varint(uint64(number)<<3 | uint64(wireType)) }

// Uint writes an unsigned integer field. Zero is written too, so a reader can tell "0" from "missing".
func (w *Writer) Uint(number int, value uint64) {
	w.tag(number, typeVarint)
	w.varint(value)
}

// Bool writes a boolean field as 0 or 1.
func (w *Writer) Bool(number int, value bool) {
	if value {
		w.Uint(number, 1)
	} else {
		w.Uint(number, 0)
	}
}

// Raw writes a length-delimited field.
func (w *Writer) Raw(number int, value []byte) {
	w.tag(number, typeBytes)
	w.varint(uint64(len(value)))
	w.buf = append(w.buf, value...)
}

// String writes a string field; an empty string is left out (the reader's default is empty).
func (w *Writer) String(number int, value string) {
	if value != "" {
		w.Raw(number, []byte(value))
	}
}

// Message writes a nested message built by build.
func (w *Writer) Message(number int, build func(*Writer)) {
	var inner Writer
	build(&inner)
	w.Raw(number, inner.buf)
}

// Field is one decoded field: a number and either an unsigned value or bytes.
type Field struct {
	Number  int
	Uint    uint64
	Bytes   []byte
	IsBytes bool
}

var errTruncated = errors.New("wire: message is cut short")

// Parse splits a message into its fields, in order. It refuses damaged input and wire types this package does not use.
func Parse(data []byte) ([]Field, error) {
	var fields []Field
	for len(data) > 0 {
		key, used, err := readVarint(data)
		if err != nil {
			return nil, err
		}
		data = data[used:]
		number := int(key >> 3)
		if number == 0 || key>>3 > 1<<28 {
			return nil, errors.New("wire: bad field number")
		}
		switch key & 7 {
		case typeVarint:
			value, used, err := readVarint(data)
			if err != nil {
				return nil, err
			}
			data = data[used:]
			fields = append(fields, Field{Number: number, Uint: value})
		case typeBytes:
			length, used, err := readVarint(data)
			if err != nil {
				return nil, err
			}
			data = data[used:]
			if length > uint64(len(data)) {
				return nil, errTruncated
			}
			fields = append(fields, Field{Number: number, Bytes: data[:length], IsBytes: true})
			data = data[length:]
		default:
			return nil, fmt.Errorf("wire: wire type %d is not supported", key&7)
		}
	}
	return fields, nil
}

func readVarint(data []byte) (value uint64, used int, err error) {
	for index := 0; index < len(data) && index < maxVarintBytes; index++ {
		value |= uint64(data[index]&0x7f) << (7 * index)
		if data[index] < 0x80 {
			return value, index + 1, nil
		}
	}
	if len(data) < maxVarintBytes {
		return 0, 0, errTruncated
	}
	return 0, 0, errors.New("wire: varint is too long")
}
