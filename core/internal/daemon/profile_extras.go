package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"gobi/core/internal/pprof"
	"gobi/core/internal/wire"
)

func readProfile(path string) (*pprof.Profile, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("the profile path must be absolute")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return pprof.Parse(data)
}

// profileLines answers with the per-line cost of one function (profile/lines).
func profileLines(path, indexText, function string) ([]byte, error) {
	profile, err := readProfile(path)
	if err != nil {
		return nil, err
	}
	index := profile.DefaultSampleIndex()
	if chosen, err := strconv.Atoi(indexText); err == nil && chosen >= 0 && chosen < len(profile.SampleTypes) {
		index = chosen
	}
	file, start, rows := profile.Lines(index, function)
	var result wire.Writer
	result.String(1, file)
	result.Uint(3, uint64(start))
	for _, row := range rows {
		result.Message(2, func(m *wire.Writer) {
			m.Uint(1, uint64(row.Line))
			m.Uint(2, uint64(row.Flat))
			m.Uint(3, uint64(row.Cum))
		})
	}
	return result.Bytes(), nil
}

// profileDiff compares two profiles of the same sample type (profile/diff).
func profileDiff(basePath, otherPath, typeName string) ([]byte, error) {
	base, err := readProfile(basePath)
	if err != nil {
		return nil, err
	}
	other, err := readProfile(otherPath)
	if err != nil {
		return nil, err
	}
	baseIndex := base.DefaultSampleIndex()
	if typeName != "" {
		baseIndex = base.SampleIndex(typeName)
	}
	if baseIndex < 0 {
		return nil, fmt.Errorf("the base profile has no %q values", typeName)
	}
	typeName = base.SampleTypes[baseIndex].Type
	otherIndex := other.SampleIndex(typeName)
	if otherIndex < 0 {
		return nil, fmt.Errorf("the other profile has no %q values", typeName)
	}
	var result wire.Writer
	result.String(1, typeName)
	result.String(2, base.SampleTypes[baseIndex].Unit)
	result.Uint(3, uint64(base.Tree(baseIndex).Cum))
	result.Uint(4, uint64(other.Tree(otherIndex).Cum))
	for _, row := range pprof.Diff(base, other, baseIndex, otherIndex, 200) {
		result.Message(5, func(m *wire.Writer) {
			m.String(1, row.Name)
			m.Uint(2, uint64(row.BaseFlat))
			m.Uint(3, uint64(row.NewFlat))
			m.Uint(4, uint64(row.BaseCum))
			m.Uint(5, uint64(row.NewCum))
		})
	}
	return result.Bytes(), nil
}
