//go:build unix

package daemon

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"

	"gobi/core/internal/ipc"
	"gobi/core/internal/project"
	"gobi/core/internal/wire"
)

// Field numbers of the control messages (protobuf wire format, see package wire). Never reuse a number.
//
//	request: 1 id (uint), 2 method (string), 3 params (message, layout depends on the method)
//	reply:   1 id (uint), 2 failure message (string, present only on failure), 3 result (message)
//	project/new    params: 1 template, 2 name, 3 location, 4 module path, 5 go version, 6 git init (bool),
//	               7 sample test (bool), 8 scaffold README/.gitignore/.env.example (bool), 9 work dir (add to this go.work)
//	project/preview params: as project/new; result: 1 root, 2 kind, 3 module path, 4 file (repeated), relative to the root
//	project/clone  params: 1 url, 2 location, 3 folder name
//	project/open   params: 1 path
//	project/import params: 1 path, 2 module path
//	result (all four): 1 root, 2 kind, 3 module path
const (
	controlID      = 1
	controlMethod  = 2
	controlFailure = 2
	controlBody    = 3

	projectRoot   = 1
	projectKind   = 2
	projectModule = 3
	projectFile   = 4
)

// serveControl answers project requests on the control channel, one at a time per connection.
// ponytail: requests run in order, so a long clone holds up later requests on the same connection; a client that
// needs both opens a second control connection.
func serveControl(session *ipc.Session, logger *slog.Logger) {
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
			if result, err = handleControl(method, params); err == nil {
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

func handleControl(method string, params []byte) ([]byte, error) {
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
