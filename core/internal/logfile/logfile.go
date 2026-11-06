// Package logfile writes gobid's log: a size-rotated private file, a slog handler that keeps full paths out
// of it, and a panic guard for goroutines that serve a client.
package logfile

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
)

// Writer appends to a file and rotates it (path -> path.1 -> ... -> path.N) before it would pass max bytes.
type Writer struct {
	mu   sync.Mutex
	path string
	max  int64
	keep int
	file *os.File
	size int64
}

// Open creates the folder (0700) and the file (0600) if needed and appends to the file.
func Open(path string, max int64, keep int) (*Writer, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	w := &Writer{path: path, max: max, keep: keep}
	return w, w.open()
}

func (w *Writer) open() error {
	file, err := os.OpenFile(w.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return err
	}
	w.file, w.size = file, info.Size()
	return nil
}

func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	if w.size > 0 && w.size+int64(len(p)) > w.max {
		w.rotate()
		if w.file == nil {
			return 0, os.ErrClosed
		}
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return n, err
}

// rotate is best effort: a failed rename must not stop logging.
func (w *Writer) rotate() {
	w.file.Close()
	w.file = nil
	os.Remove(fmt.Sprintf("%s.%d", w.path, w.keep))
	for i := w.keep - 1; i >= 1; i-- {
		os.Rename(fmt.Sprintf("%s.%d", w.path, i), fmt.Sprintf("%s.%d", w.path, i+1))
	}
	os.Rename(w.path, w.path+".1")
	w.open()
}

func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

// Redact replaces every absolute path in text by its last element, so a log line names a folder or file but not where it is.
func Redact(text string) string {
	if !strings.Contains(text, "/") {
		return text
	}
	var out strings.Builder
	for i := 0; i < len(text); {
		startsPath := text[i] == '/' && (i == 0 || strings.ContainsRune(" \t\"'=(:[", rune(text[i-1])))
		if !startsPath {
			out.WriteByte(text[i])
			i++
			continue
		}
		end := i
		for end < len(text) && !strings.ContainsRune(" \t\n\"'),;", rune(text[end])) {
			end++
		}
		path := strings.TrimRight(text[i:end], ":")
		end = i + len(path)
		if base := filepath.Base(path); base != "/" && base != "." {
			out.WriteString(base)
		} else {
			out.WriteString(path)
		}
		i = end
	}
	return out.String()
}

// NewHandler is a JSON slog handler that redacts paths in string and error values. The "stack" attribute is left alone.
func NewHandler(w io.Writer, level slog.Leveler) slog.Handler {
	return slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level, ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
		if len(groups) > 0 || a.Key == "stack" {
			return a
		}
		switch a.Value.Kind() {
		case slog.KindString:
			a.Value = slog.StringValue(Redact(a.Value.String()))
		case slog.KindAny:
			if err, ok := a.Value.Any().(error); ok {
				a.Value = slog.StringValue(Redact(err.Error()))
			}
		}
		return a
	}})
}

// Recover is deferred at the top of a goroutine: it logs a panic with its stack and swallows it.
func Recover(logger *slog.Logger, what string) {
	if r := recover(); r != nil {
		logger.Error("panic recovered", "where", what, "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
	}
}

// Guard wraps a handler so a panic in it is logged and does not end the process.
func Guard[T any](logger *slog.Logger, what string, handler func(T)) func(T) {
	return func(arg T) {
		defer Recover(logger, what)
		handler(arg)
	}
}
