// Package pprof reads Go's profile files (the gzipped protocol buffer that `go tool pprof` and net/http/pprof use) and turns
// them into a call tree and a table of the costliest functions. It only needs the fields the Profiler shows.
package pprof

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"sort"

	"gobi/core/internal/wire"
)

const maxProfileBytes = 512 << 20

type SampleType struct{ Type, Unit string }

type sample struct {
	locations []uint64 // leaf first
	values    []int64
}

type frame struct {
	name, file string
	line       int
	start      int // line of the function declaration, 0 when the profile has none
}

// Profile is a parsed profile.
type Profile struct {
	SampleTypes   []SampleType
	DurationNanos int64
	samples       []sample
	frames        map[uint64][]frame // location id -> frames, innermost first
	defaultIndex  int
}

// Node is one function in the call tree. Flat is what the function itself cost, Cum what it and its callees cost.
type Node struct {
	Name, File string
	Line       int
	Flat, Cum  int64
	Children   []*Node
}

type TopRow struct {
	Name      string
	Flat, Cum int64
}

// Parse reads a profile, gzipped or not.
func Parse(data []byte) (*Profile, error) {
	if len(data) == 0 {
		return nil, errors.New("the profile is empty")
	}
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		reader, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("not a profile: %w", err)
		}
		unzipped, err := io.ReadAll(io.LimitReader(reader, maxProfileBytes))
		if err != nil {
			return nil, fmt.Errorf("not a profile: %w", err)
		}
		data = unzipped
	}
	fields, err := wire.Parse(data)
	if err != nil {
		return nil, fmt.Errorf("not a profile: %w", err)
	}
	var strs []string
	for _, field := range fields {
		if field.Number == 6 && field.IsBytes {
			strs = append(strs, string(field.Bytes))
		}
	}
	str := func(index uint64) string {
		if int(index) < len(strs) {
			return strs[index]
		}
		return ""
	}
	p := &Profile{frames: map[uint64][]frame{}, defaultIndex: -1}
	functions := map[uint64]frame{}
	var defaultType uint64
	for _, field := range fields {
		switch {
		case field.Number == 1 && field.IsBytes:
			inner, err := wire.Parse(field.Bytes)
			if err != nil {
				return nil, err
			}
			var t, u uint64
			for _, f := range inner {
				if f.Number == 1 {
					t = f.Uint
				} else if f.Number == 2 {
					u = f.Uint
				}
			}
			p.SampleTypes = append(p.SampleTypes, SampleType{str(t), str(u)})
		case field.Number == 2 && field.IsBytes:
			inner, err := wire.Parse(field.Bytes)
			if err != nil {
				return nil, err
			}
			var s sample
			for _, f := range inner {
				if f.Number == 1 {
					s.locations = append(s.locations, unpack(f)...)
				} else if f.Number == 2 {
					for _, v := range unpack(f) {
						s.values = append(s.values, int64(v))
					}
				}
			}
			p.samples = append(p.samples, s)
		case field.Number == 5 && field.IsBytes:
			inner, err := wire.Parse(field.Bytes)
			if err != nil {
				return nil, err
			}
			var id, name, file, start uint64
			for _, f := range inner {
				switch f.Number {
				case 1:
					id = f.Uint
				case 2:
					name = f.Uint
				case 4:
					file = f.Uint
				case 5:
					start = f.Uint
				}
			}
			functions[id] = frame{name: str(name), file: str(file), start: int(start)}
		case field.Number == 10:
			p.DurationNanos = int64(field.Uint)
		case field.Number == 14:
			defaultType = field.Uint
		}
	}
	for _, field := range fields {
		if field.Number != 4 || !field.IsBytes {
			continue
		}
		inner, err := wire.Parse(field.Bytes)
		if err != nil {
			return nil, err
		}
		var id uint64
		var frames []frame
		for _, f := range inner {
			switch {
			case f.Number == 1:
				id = f.Uint
			case f.Number == 4 && f.IsBytes:
				line, err := wire.Parse(f.Bytes)
				if err != nil {
					return nil, err
				}
				var functionID, number uint64
				for _, l := range line {
					if l.Number == 1 {
						functionID = l.Uint
					} else if l.Number == 2 {
						number = l.Uint
					}
				}
				fr := functions[functionID]
				fr.line = int(number)
				frames = append(frames, fr)
			}
		}
		if len(frames) == 0 {
			frames = []frame{{name: fmt.Sprintf("location %d", id)}}
		}
		p.frames[id] = frames
	}
	if len(p.SampleTypes) == 0 {
		return nil, errors.New("not a profile: no sample types")
	}
	p.defaultIndex = len(p.SampleTypes) - 1
	for i, t := range p.SampleTypes {
		if t.Type == "inuse_space" {
			p.defaultIndex = i
		}
	}
	if defaultType != 0 {
		for i, t := range p.SampleTypes {
			if t.Type == str(defaultType) {
				p.defaultIndex = i
			}
		}
	}
	return p, nil
}

// unpack reads a repeated integer field, packed (one length-delimited value) or not (one varint per field).
func unpack(field wire.Field) []uint64 {
	if !field.IsBytes {
		return []uint64{field.Uint}
	}
	var values []uint64
	data := field.Bytes
	for len(data) > 0 {
		var value uint64
		var shift uint
		used := 0
		for used < len(data) {
			b := data[used]
			used++
			value |= uint64(b&0x7f) << shift
			if b < 0x80 {
				break
			}
			shift += 7
		}
		values = append(values, value)
		data = data[used:]
	}
	return values
}

// DefaultSampleIndex is the value to show first: inuse_space for a heap profile, otherwise the profile's own default or its last
// value (cpu time for a CPU profile).
func (p *Profile) DefaultSampleIndex() int { return p.defaultIndex }

// stack returns the frames of a sample, outermost caller first.
func (p *Profile) stack(s sample) []frame {
	var out []frame
	for i := len(s.locations) - 1; i >= 0; i-- {
		frames := p.frames[s.locations[i]]
		for j := len(frames) - 1; j >= 0; j-- {
			out = append(out, frames[j])
		}
	}
	return out
}

func value(s sample, index int) int64 {
	if index < 0 || index >= len(s.values) {
		return 0
	}
	return s.values[index]
}

// Tree builds the call tree for one sample type. The root is "all"; children are ordered by cumulative cost.
func (p *Profile) Tree(index int) *Node {
	root := &Node{Name: "all"}
	for _, s := range p.samples {
		v := value(s, index)
		if v == 0 {
			continue
		}
		root.Cum += v
		node := root
		for _, fr := range p.stack(s) {
			var child *Node
			for _, c := range node.Children {
				if c.Name == fr.name {
					child = c
					break
				}
			}
			if child == nil {
				child = &Node{Name: fr.name, File: fr.file, Line: fr.line}
				node.Children = append(node.Children, child)
			}
			child.Cum += v
			node = child
			if fr.line != 0 && node.Line == 0 {
				node.Line, node.File = fr.line, fr.file
			}
		}
		node.Flat += v
	}
	sortTree(root)
	return root
}

func sortTree(n *Node) {
	sort.SliceStable(n.Children, func(i, j int) bool {
		if n.Children[i].Cum != n.Children[j].Cum {
			return n.Children[i].Cum > n.Children[j].Cum
		}
		return n.Children[i].Name < n.Children[j].Name
	})
	for _, c := range n.Children {
		sortTree(c)
	}
}

// Top lists the costliest functions, by flat cost then cumulative cost. A function that appears twice in one stack counts once
// toward its cumulative cost.
func (p *Profile) Top(index, limit int) []TopRow {
	rows := map[string]*TopRow{}
	row := func(name string) *TopRow {
		if rows[name] == nil {
			rows[name] = &TopRow{Name: name}
		}
		return rows[name]
	}
	for _, s := range p.samples {
		v := value(s, index)
		if v == 0 {
			continue
		}
		stack := p.stack(s)
		if len(stack) > 0 {
			row(stack[len(stack)-1].name).Flat += v
		}
		seen := map[string]bool{}
		for _, fr := range stack {
			if !seen[fr.name] {
				seen[fr.name] = true
				row(fr.name).Cum += v
			}
		}
	}
	out := make([]TopRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Flat != out[j].Flat {
			return out[i].Flat > out[j].Flat
		}
		if out[i].Cum != out[j].Cum {
			return out[i].Cum > out[j].Cum
		}
		return out[i].Name < out[j].Name
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}
