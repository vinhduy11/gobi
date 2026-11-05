//go:build unix

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"

	"gobi/core/internal/ipc"
	"gobi/core/internal/project"
)

type controlRequest struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type controlError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type controlResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *controlError   `json:"error,omitempty"`
}

// serveControl answers project requests on the control channel, one at a time per connection.
// ponytail: requests run in order, so a long clone holds up later requests on the same connection; a client that
// needs both opens a second control connection.
func serveControl(session *ipc.Session, logger *slog.Logger) {
	for {
		payload, err := session.Reader.Read()
		if err != nil {
			return
		}
		var request controlRequest
		response := controlResponse{JSONRPC: "2.0"}
		if err := json.Unmarshal(payload, &request); err != nil {
			response.Error = &controlError{Code: -32700, Message: "malformed request"}
		} else {
			response.ID = request.ID
			result, err := handleControl(request.Method, request.Params)
			if err != nil {
				logger.Info("control request failed", "method", request.Method, "error", err)
				response.Error = &controlError{Code: -32000, Message: err.Error()}
			} else {
				response.Result = result
			}
		}
		encoded, _ := json.Marshal(response)
		if err := session.Writer.Write(encoded); err != nil {
			return
		}
	}
}

func handleControl(method string, params json.RawMessage) (any, error) {
	switch method {
	case "project/new":
		var request project.NewRequest
		if err := json.Unmarshal(params, &request); err != nil {
			return nil, err
		}
		return project.Create(request)
	case "project/clone":
		var request project.CloneRequest
		if err := json.Unmarshal(params, &request); err != nil {
			return nil, err
		}
		return project.Clone(context.Background(), request)
	case "project/open":
		path, err := pathParam(params)
		if err != nil {
			return nil, err
		}
		return project.Inspect(path), nil
	case "project/import":
		var request struct {
			Path       string `json:"path"`
			ModulePath string `json:"module_path"`
		}
		if err := json.Unmarshal(params, &request); err != nil {
			return nil, err
		}
		if _, err := existingFolder(request.Path); err != nil {
			return nil, err
		}
		return project.Import(request.Path, request.ModulePath)
	}
	return nil, errors.New("unknown method " + method)
}

func pathParam(params json.RawMessage) (string, error) {
	var request struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal(params, &request); err != nil {
		return "", err
	}
	return existingFolder(request.Path)
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
