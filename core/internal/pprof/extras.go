package pprof

import "sort"

// LineRow is the cost attributed to one source line of a function: Flat is what the line itself cost, Cum what it and its callees cost.
type LineRow struct {
	Line      int
	Flat, Cum int64
}

// Lines returns the source file and declaration line (0: unknown) of a function and its per-line cost for one sample type, ordered by line.
func (p *Profile) Lines(index int, name string) (string, int, []LineRow) {
	rows := map[int]*LineRow{}
	file, start := "", 0
	row := func(line int) *LineRow {
		if rows[line] == nil {
			rows[line] = &LineRow{Line: line}
		}
		return rows[line]
	}
	for _, s := range p.samples {
		cost := value(s, index)
		if cost == 0 {
			continue
		}
		stack := p.stack(s)
		seen := map[int]bool{}
		for i, fr := range stack {
			if fr.name != name {
				continue
			}
			if file == "" {
				file, start = fr.file, fr.start
			}
			if i == len(stack)-1 {
				row(fr.line).Flat += cost
			}
			if !seen[fr.line] {
				seen[fr.line] = true
				row(fr.line).Cum += cost
			}
		}
	}
	out := make([]LineRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Line < out[j].Line })
	return file, start, out
}

// SampleIndex is the index of the sample type with this name, or -1.
func (p *Profile) SampleIndex(typeName string) int {
	for i, t := range p.SampleTypes {
		if t.Type == typeName {
			return i
		}
	}
	return -1
}

// DiffRow compares one function in two profiles.
type DiffRow struct {
	Name              string
	BaseFlat, NewFlat int64
	BaseCum, NewCum   int64
}

func abs(number int64) int64 {
	if number < 0 {
		return -number
	}
	return number
}

// Diff compares two profiles (sample index a of base, b of next) per function, largest absolute flat change first.
func Diff(base, next *Profile, a, b, limit int) []DiffRow {
	rows := map[string]*DiffRow{}
	row := func(name string) *DiffRow {
		if rows[name] == nil {
			rows[name] = &DiffRow{Name: name}
		}
		return rows[name]
	}
	for _, top := range base.Top(a, 0) {
		entry := row(top.Name)
		entry.BaseFlat, entry.BaseCum = top.Flat, top.Cum
	}
	for _, top := range next.Top(b, 0) {
		entry := row(top.Name)
		entry.NewFlat, entry.NewCum = top.Flat, top.Cum
	}
	out := make([]DiffRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool {
		flatI, flatJ := abs(out[i].NewFlat-out[i].BaseFlat), abs(out[j].NewFlat-out[j].BaseFlat)
		if flatI != flatJ {
			return flatI > flatJ
		}
		cumI, cumJ := abs(out[i].NewCum-out[i].BaseCum), abs(out[j].NewCum-out[j].BaseCum)
		if cumI != cumJ {
			return cumI > cumJ
		}
		return out[i].Name < out[j].Name
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}
