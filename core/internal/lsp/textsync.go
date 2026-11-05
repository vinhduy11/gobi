// Package lsp brokers one gopls process per workspace for any number of UI clients.
package lsp

import (
	"sort"
	"strings"
	"unicode/utf8"
)

type position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type lspRange struct {
	Start position `json:"start"`
	End   position `json:"end"`
}

// contentChange is one textDocument/didChange entry; a nil Range replaces the whole document.
type contentChange struct {
	Range *lspRange `json:"range,omitempty"`
	Text  string    `json:"text"`
}

// applyChange applies one change to text. Positions count UTF-16 code units, as the LSP specifies;
// out-of-range positions clamp to the end of the line or document.
func applyChange(text string, edit contentChange) string {
	if edit.Range == nil {
		return edit.Text
	}
	from := offsetOf(text, edit.Range.Start)
	to := offsetOf(text, edit.Range.End)
	if to < from {
		from, to = to, from
	}
	return text[:from] + edit.Text + text[to:]
}

func offsetOf(text string, at position) int {
	lineStart := 0
	for skipped := 0; skipped < at.Line; skipped++ {
		newline := strings.IndexByte(text[lineStart:], '\n')
		if newline < 0 {
			return len(text)
		}
		lineStart += newline + 1
	}

	lineEnd := len(text)
	if newline := strings.IndexByte(text[lineStart:], '\n'); newline >= 0 {
		lineEnd = lineStart + newline
		if lineEnd > lineStart && text[lineEnd-1] == '\r' {
			lineEnd--
		}
	}

	offset, units := lineStart, 0
	for offset < lineEnd && units < at.Character {
		r, size := utf8.DecodeRuneInString(text[offset:lineEnd])
		if r >= 0x10000 {
			units += 2
		} else {
			units++
		}
		offset += size
	}
	return offset
}

// document is the latest known state of a document open in gopls.
type document struct {
	URI        string
	LanguageID string
	Version    int
	Text       string
	owners     map[int]bool
}

// docStore tracks open documents so they can be replayed to a restarted gopls.
// It is not safe for concurrent use; the broker serialises access.
type docStore struct {
	docs map[string]*document
}

func newDocStore() *docStore { return &docStore{docs: map[string]*document{}} }

// open registers owner as holding uri open and reports whether it was the first owner.
func (s *docStore) open(uri, languageID string, version int, text string, owner int) bool {
	if existing, ok := s.docs[uri]; ok {
		existing.owners[owner] = true
		return false
	}
	s.docs[uri] = &document{URI: uri, LanguageID: languageID, Version: version, Text: text, owners: map[int]bool{owner: true}}
	return true
}

// change applies edits in order and reports whether uri was open.
func (s *docStore) change(uri string, version int, edits []contentChange) bool {
	doc, ok := s.docs[uri]
	if !ok {
		return false
	}
	for _, edit := range edits {
		doc.Text = applyChange(doc.Text, edit)
	}
	doc.Version = version
	return true
}

// close removes owner and reports whether that was the last owner.
func (s *docStore) close(uri string, owner int) bool {
	doc, ok := s.docs[uri]
	if !ok || !doc.owners[owner] {
		return false
	}
	delete(doc.owners, owner)
	if len(doc.owners) > 0 {
		return false
	}
	delete(s.docs, uri)
	return true
}

// dropOwner removes owner everywhere and returns the URIs that no longer have any owner.
func (s *docStore) dropOwner(owner int) []string {
	var closed []string
	for uri := range s.docs {
		if s.close(uri, owner) {
			closed = append(closed, uri)
		}
	}
	sort.Strings(closed)
	return closed
}

// snapshot returns copies of all open documents ordered by URI.
func (s *docStore) snapshot() []document {
	copies := make([]document, 0, len(s.docs))
	for _, doc := range s.docs {
		copies = append(copies, document{URI: doc.URI, LanguageID: doc.LanguageID, Version: doc.Version, Text: doc.Text})
	}
	sort.Slice(copies, func(i, j int) bool { return copies[i].URI < copies[j].URI })
	return copies
}
