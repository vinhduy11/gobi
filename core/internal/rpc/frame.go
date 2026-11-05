// Package rpc implements the LSP base protocol framing (Content-Length headers)
// used on every Gobi connection: UI to core and core to gopls.
package rpc

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
)

var (
	ErrMalformedHeader = errors.New("rpc: malformed header")
	ErrTooLarge        = errors.New("rpc: message exceeds size limit")
)

const maxHeaderLine = 4096

// Reader reads framed messages. It is not safe for concurrent use.
type Reader struct {
	source     *bufio.Reader
	maxPayload int
}

// NewReader returns a Reader that rejects payloads larger than maxPayload bytes.
func NewReader(source io.Reader, maxPayload int) *Reader {
	return &Reader{source: bufio.NewReaderSize(source, maxHeaderLine), maxPayload: maxPayload}
}

// Read returns the next payload. It returns io.EOF only on a clean end between
// messages and io.ErrUnexpectedEOF when the stream ends inside one.
func (r *Reader) Read() ([]byte, error) {
	length, err := r.readHeaders()
	if err != nil {
		return nil, err
	}
	if length > r.maxPayload {
		return nil, fmt.Errorf("%w: %d > %d", ErrTooLarge, length, r.maxPayload)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r.source, payload); err != nil {
		return nil, io.ErrUnexpectedEOF
	}
	return payload, nil
}

func (r *Reader) readHeaders() (int, error) {
	length := -1
	seenType := false
	for first := true; ; first = false {
		line, err := r.readLine(first)
		if err != nil {
			return 0, err
		}
		if line == "" {
			break
		}
		name, headerValue, ok := strings.Cut(line, ":")
		if !ok {
			return 0, fmt.Errorf("%w: no colon in %q", ErrMalformedHeader, line)
		}
		headerValue = strings.TrimSpace(headerValue)
		switch strings.ToLower(name) {
		case "content-length":
			if length >= 0 {
				return 0, fmt.Errorf("%w: duplicate Content-Length", ErrMalformedHeader)
			}
			if length, err = parseLength(headerValue); err != nil {
				return 0, err
			}
		case "content-type":
			if seenType {
				return 0, fmt.Errorf("%w: duplicate Content-Type", ErrMalformedHeader)
			}
			seenType = true
		default:
			return 0, fmt.Errorf("%w: unknown header %q", ErrMalformedHeader, name)
		}
	}
	if length < 0 {
		return 0, fmt.Errorf("%w: missing Content-Length", ErrMalformedHeader)
	}
	return length, nil
}

// readLine returns one CRLF-terminated line without the terminator.
func (r *Reader) readLine(first bool) (string, error) {
	lineBytes, err := r.source.ReadSlice('\n')
	switch {
	case errors.Is(err, bufio.ErrBufferFull):
		return "", fmt.Errorf("%w: header line too long", ErrMalformedHeader)
	case err == io.EOF && len(lineBytes) == 0 && first:
		return "", io.EOF
	case err != nil:
		return "", io.ErrUnexpectedEOF
	}
	if len(lineBytes) < 2 || lineBytes[len(lineBytes)-2] != '\r' {
		return "", fmt.Errorf("%w: line not terminated by CRLF", ErrMalformedHeader)
	}
	return string(lineBytes[:len(lineBytes)-2]), nil
}

func parseLength(lengthText string) (int, error) {
	if lengthText == "" || strings.Trim(lengthText, "0123456789") != "" {
		return 0, fmt.Errorf("%w: bad Content-Length %q", ErrMalformedHeader, lengthText)
	}
	length, err := strconv.Atoi(lengthText)
	if err != nil {
		return 0, fmt.Errorf("%w: bad Content-Length %q", ErrMalformedHeader, lengthText)
	}
	return length, nil
}

// Writer writes framed messages. It is safe for concurrent use.
type Writer struct {
	lock   sync.Mutex
	target io.Writer
}

func NewWriter(target io.Writer) *Writer { return &Writer{target: target} }

// Write sends payload as one frame; frames from concurrent callers never interleave.
func (w *Writer) Write(payload []byte) error {
	header := strconv.AppendInt([]byte("Content-Length: "), int64(len(payload)), 10)
	header = append(header, "\r\n\r\n"...)

	w.lock.Lock()
	defer w.lock.Unlock()
	if _, err := w.target.Write(header); err != nil {
		return err
	}
	_, err := w.target.Write(payload)
	return err
}
