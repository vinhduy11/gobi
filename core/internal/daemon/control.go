//go:build unix

package daemon

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/pprof"
	"gobi/core/internal/project"
	"gobi/core/internal/search"
	"gobi/core/internal/toolchain"
	"gobi/core/internal/wire"
)

// Field numbers of the control messages (protobuf wire format, see package wire). Never reuse a number.
//
//	request: 1 id (uint), 2 method (string), 3 params (message, layout depends on the method)
//	reply:   1 id (uint), 2 failure message (string, present only on failure), 3 result (message)
//	project/new    params: 1 template, 2 name, 3 location, 4 module path, 5 go version, 6 git init (bool),
//	               7 sample test (bool), 8 scaffold README/.gitignore/.env.example (bool), 9 work dir (add to this go.work)
//	project/preview params: as project/new; result: 1 root, 2 kind, 3 module path, 4 file (repeated), relative to the root
//	project/templates params: none; result: 1 template (repeated message, in dialog order: 1 id, 2 order (1-based), 3 group,
//	               4 title, 5 summary, 6 available (bool)). Read-only.
//	project/clone  params: 1 url, 2 location, 3 folder name
//	project/open   params: 1 path
//	project/import params: 1 path, 2 module path
//	result (all four): 1 root, 2 kind, 3 module path
//	tools/check    params: none; result: 1 tool (repeated message: 1 name, 2 required, 3 found, 4 version, 5 path, 6 problem,
//	               7 installable by Gobi (bool), 8 hint for getting it)
//	toolchain/available  params: none; result: 1 version (repeated, newest first), the newest patch of the last few Go minors
//	toolchain/install    params: 1 version ("1.25.10"); result: empty. Downloads Go into ~/sdk; the client asks the user first.
//	profile/load   params: 1 absolute path of a .pprof file, 2 sample index as text (empty: the profile's default)
//	               result: 1 sample type (repeated message: 1 type, 2 unit), 2 chosen index, 3 total, 4 duration ns,
//	               5 node (repeated: 1 id, 2 parent id (0 for the root), 3 name, 4 flat, 5 cum, 6 file, 7 line; parents come first),
//	               6 top row (repeated: 1 name, 2 flat, 3 cum)
//	profile/lines  params: 1 absolute path, 2 sample index as text (empty: default), 3 function name
//	               result: 1 source file, 2 line row (repeated: 1 line, 2 flat, 3 cum), ordered by line
//	profile/diff   params: 1 base path, 2 other path (both absolute), 3 sample type name (empty: the base profile's default)
//	               result: 1 type name, 2 unit, 3 base total, 4 other total, 5 row (repeated, largest flat change first, at most
//	               200: 1 name, 2 base flat, 3 other flat, 4 base cum, 5 other cum)
//	profile/capture params: 1 address (loopback host:port), 2 kind (cpu, heap, allocs, goroutine, mutex, block), 3 seconds as text,
//	               4 absolute output path ending in .pprof; result: empty
//	terminal/shells  params: none; result: 1 shell (repeated), the absolute paths listed in /etc/shells, 2 login shell ($SHELL)
//	daemon/status  params: none; result: 1 pid, 2 runtime version, 3 log level (debug, info, warn, error), 4 start time (unix seconds)
//	daemon/loglevel params: 1 level; result: empty
//	daemon/stop    params: none; result: empty, then gobid shuts down (the app starts a new one on its next connection)
//	search/files   params: 1 query, 2 regex, 3 case sensitive, 4 whole word, 5 replacement, 6 has replacement (bool), 7 include glob
//	               (repeated), 8 most results (0: 2000), 9 absolute project folder
//	               result: 1 match (repeated: 1 path, 2 line (0-based), 3 start, 4 end (UTF-16 columns), 5 text, 6 column where the text
//	               starts, 7 replacement), 2 files with matches, 3 files skipped, 4 truncated (bool)
//	tools/install  params: 1 tool name; result: empty. Runs `go install`; the client asks the user first.
const (
	controlID      = 1
	controlMethod  = 2
	controlFailure = 2
	controlBody    = 3

	projectRoot   = 1
	projectKind   = 2
	projectModule = 3
	projectFile   = 4

	toolEntry     = 1
	templateEntry = 1
)

// serveControl answers project requests on the control channel, one at a time per connection.
// ponytail: requests run in order, so a long clone holds up later requests on the same connection; a client that
// needs both opens a second control connection.
func serveControl(session *ipc.Session, logger *slog.Logger, hooks controlHooks) {
	for {
		payload, err := session.Reader.Read()
		if err != nil {
			return
		}
		var reply wire.Writer
		id, method, params, err := decodeRequest(payload)
		reply.Uint(controlID, id)
		if err == nil {
			var result []byte
			if result, err = handleControl(method, params, hooks); err == nil {
				reply.Raw(controlBody, result)
			}
		}
		if err != nil {
			logger.Info("control request failed", "method", method, "error", err)
			reply.String(controlFailure, err.Error())
		}
		if err := session.Writer.Write(reply.Bytes()); err != nil {
			return
		}
	}
}

func decodeRequest(payload []byte) (id uint64, method string, params []byte, err error) {
	fields, err := wire.Parse(payload)
	if err != nil {
		return 0, "", nil, errors.New("malformed request: control requests are binary (protobuf wire format), not JSON")
	}
	for _, field := range fields {
		switch field.Number {
		case controlID:
			id = field.Uint
		case controlMethod:
			method = string(field.Bytes)
		case controlBody:
			params = field.Bytes
		}
	}
	return id, method, params, nil
}

// controlHooks lets the control channel reach the daemon's own settings.
type controlHooks struct {
	level   *slog.LevelVar // nil: the log level cannot be changed
	stop    func()         // asks the daemon to shut down
	started time.Time
}

func handleControl(method string, params []byte, hooks controlHooks) ([]byte, error) {
	fields, err := wire.Parse(params)
	if err != nil {
		return nil, err
	}
	text := func(number int) string {
		for _, field := range fields {
			if field.Number == number {
				return string(field.Bytes)
			}
		}
		return ""
	}
	flag := func(number int) bool {
		for _, field := range fields {
			if field.Number == number {
				return field.Uint != 0
			}
		}
		return false
	}

	newRequest := project.NewRequest{
		Template: text(1), Name: text(2), Location: text(3), ModulePath: text(4), GoVersion: text(5), GitInit: flag(6),
		SampleTest: flag(7), Scaffold: flag(8), WorkDir: text(9),
	}
	var info project.Info
	switch method {
	case "tools/check":
		return toolsReport(toolchain.Check(toolchain.FromOS(), toolchain.DefaultTools)), nil
	case "toolchain/available":
		versions, err := toolchain.Available(context.Background(), toolchain.ReleasesURL, 5)
		if err != nil {
			return nil, err
		}
		var result wire.Writer
		for _, version := range versions {
			result.String(1, version)
		}
		return result.Bytes(), nil
	case "toolchain/install":
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		return nil, toolchain.InstallVersion(context.Background(), toolchain.FromOS(), home, text(1))
	case "profile/load":
		return loadProfile(text(1), text(2))
	case "profile/lines":
		return profileLines(text(1), text(2), text(3))
	case "profile/diff":
		return profileDiff(text(1), text(2), text(3))
	case "profile/capture":
		seconds, _ := strconv.Atoi(text(3))
		return nil, pprof.Capture(context.Background(), text(1), text(2), seconds, text(4))
	case "terminal/shells":
		var result wire.Writer
		for _, shell := range listedShells(shellsFile) {
			result.String(1, shell)
		}
		result.String(2, os.Getenv("SHELL"))
		return result.Bytes(), nil
	case "daemon/status":
		var result wire.Writer
		result.Uint(1, uint64(os.Getpid()))
		result.String(2, runtime.Version())
		level := "info"
		if hooks.level != nil {
			level = strings.ToLower(hooks.level.Level().String())
		}
		result.String(3, level)
		result.Uint(4, uint64(hooks.started.Unix()))
		return result.Bytes(), nil
	case "daemon/loglevel":
		if hooks.level == nil {
			return nil, errors.New("the log level cannot be changed in this daemon")
		}
		var level slog.Level
		if err := level.UnmarshalText([]byte(text(1))); err != nil || text(1) == "" {
			return nil, errors.New("the log level must be debug, info, warn or error")
		}
		hooks.level.Set(level)
		return nil, nil
	case "daemon/stop":
		if hooks.stop == nil {
			return nil, errors.New("this daemon cannot be stopped from here")
		}
		go func() { time.Sleep(150 * time.Millisecond); hooks.stop() }()
		return nil, nil
	case "search/files":
		return searchFiles(fields)
	case "tools/install":
		return nil, toolchain.Install(context.Background(), toolchain.FromOS(), text(1))
	case "project/templates":
		var result wire.Writer
		for index, entry := range project.Catalogue() {
			result.Raw(templateEntry, templateEntryBytes(index+1, entry))
		}
		return result.Bytes(), nil
	case "project/preview":
		files, err := project.Preview(newRequest)
		if err != nil {
			return nil, err
		}
		var result wire.Writer
		result.String(projectRoot, filepath.Join(newRequest.Location, newRequest.Name))
		for _, file := range files {
			result.Raw(projectFile, []byte(file))
		}
		return result.Bytes(), nil
	case "project/new":
		info, err = project.Create(newRequest)
	case "project/clone":
		info, err = project.Clone(context.Background(), project.CloneRequest{URL: text(1), Location: text(2), Name: text(3)})
	case "project/open":
		var path string
		if path, err = existingFolder(text(1)); err == nil {
			info = project.Inspect(path)
		}
	case "project/import":
		var path string
		if path, err = existingFolder(text(1)); err == nil {
			info, err = project.Import(path, text(2))
		}
	default:
		err = errors.New("unknown method " + method)
	}
	if err != nil {
		return nil, err
	}
	var result wire.Writer
	result.String(projectRoot, info.Root)
	result.String(projectKind, info.Kind)
	result.String(projectModule, info.ModulePath)
	return result.Bytes(), nil
}

// templateEntryBytes encodes one catalogue entry; order is its 1-based position.
func templateEntryBytes(order int, entry project.CatalogueEntry) []byte {
	var out wire.Writer
	out.String(1, entry.ID)
	out.Uint(2, uint64(order))
	out.String(3, entry.Group)
	out.String(4, entry.Title)
	out.String(5, entry.Summary)
	out.Bool(6, entry.Available)
	return out.Bytes()
}

func existingFolder(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("path must be absolute")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New(path + " is not a folder")
	}
	return path, nil
}

func toolsReport(reports []toolchain.Report) []byte {
	var result wire.Writer
	for _, report := range reports {
		_, installable := toolchain.InstallArgs(report.Name)
		result.Message(toolEntry, func(entry *wire.Writer) {
			entry.String(1, report.Name)
			entry.Bool(2, report.Required)
			entry.Bool(3, report.Found)
			entry.String(4, report.Version)
			entry.String(5, report.Path)
			entry.String(6, report.Problem)
			entry.Bool(7, installable)
			entry.String(8, toolchain.Hint(report.Name))
		})
	}
	return result.Bytes()
}

const maxProfileNodes = 4000

// loadProfile reads a profile file and answers with its sample types, call tree (without the cheapest branches) and top table.
func loadProfile(path, indexText string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("the profile path must be absolute")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	profile, err := pprof.Parse(data)
	if err != nil {
		return nil, err
	}
	index := profile.DefaultSampleIndex()
	if indexText != "" {
		if chosen, err := strconv.Atoi(indexText); err == nil && chosen >= 0 && chosen < len(profile.SampleTypes) {
			index = chosen
		}
	}
	root := profile.Tree(index)
	var result wire.Writer
	for _, sampleType := range profile.SampleTypes {
		result.Message(1, func(m *wire.Writer) { m.String(1, sampleType.Type); m.String(2, sampleType.Unit) })
	}
	result.Uint(2, uint64(index))
	result.Uint(3, uint64(root.Cum))
	result.Uint(4, uint64(profile.DurationNanos))
	next, written := uint64(1), 0
	var walk func(node *pprof.Node, parent uint64, depth int)
	walk = func(node *pprof.Node, parent uint64, depth int) {
		if written >= maxProfileNodes || depth > 120 {
			return
		}
		id := next
		next++
		written++
		result.Message(5, func(m *wire.Writer) {
			m.Uint(1, id)
			m.Uint(2, parent)
			m.String(3, node.Name)
			m.Uint(4, uint64(node.Flat))
			m.Uint(5, uint64(node.Cum))
			m.String(6, node.File)
			m.Uint(7, uint64(node.Line))
		})
		for _, child := range node.Children {
			if child.Cum*1000 < root.Cum { // children are sorted, so the rest are cheaper still
				break
			}
			walk(child, id, depth+1)
		}
	}
	walk(root, 0, 0)
	for _, row := range profile.Top(index, 200) {
		result.Message(6, func(m *wire.Writer) { m.String(1, row.Name); m.Uint(2, uint64(row.Flat)); m.Uint(3, uint64(row.Cum)) })
	}
	return result.Bytes(), nil
}

func searchFiles(fields []wire.Field) ([]byte, error) {
	var options search.Options
	var root string
	for _, field := range fields {
		switch field.Number {
		case 1:
			options.Query = string(field.Bytes)
		case 2:
			options.Regex = field.Uint != 0
		case 3:
			options.CaseSensitive = field.Uint != 0
		case 4:
			options.WholeWord = field.Uint != 0
		case 5:
			options.Replacement = string(field.Bytes)
		case 6:
			options.HasReplace = field.Uint != 0
		case 7:
			options.Include = append(options.Include, string(field.Bytes))
		case 8:
			options.MaxResults = int(field.Uint)
		case 9:
			root = string(field.Bytes)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	found, err := search.Search(ctx, root, options)
	if err != nil {
		return nil, err
	}
	var result wire.Writer
	for _, m := range found.Matches {
		result.Message(1, func(w *wire.Writer) {
			w.String(1, m.Path)
			w.Uint(2, uint64(m.Line))
			w.Uint(3, uint64(m.Start))
			w.Uint(4, uint64(m.End))
			w.String(5, m.Text)
			w.Uint(6, uint64(m.TextStart))
			w.String(7, m.Replacement)
		})
	}
	result.Uint(2, uint64(found.Files))
	result.Uint(3, uint64(found.Skipped))
	result.Bool(4, found.Truncated)
	return result.Bytes(), nil
}
