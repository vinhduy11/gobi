//go:build unix

package daemon

import (
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"gobi/core/internal/debugger"
	"gobi/core/internal/ipc"
	"gobi/core/internal/rpc"
)

const debuggerReadyWait = 20 * time.Second

// debugAdmit refuses the dap channel for a workspace the user has not trusted (debugging runs the program) and when no
// debugger is configured, so the client can tell the user to install one.
func debugAdmit(hello ipc.Hello, servers map[string][]string) string {
	if hello.Channel != "dap" {
		return ""
	}
	if !hello.Trusted {
		return "debugging runs your program and is off in Restricted Mode; trust the project first"
	}
	if len(servers["dap"]) == 0 {
		return "the Delve debugger (dlv) is not installed"
	}
	return ""
}

// serveDebug starts the debug adapter for the workspace and passes DAP messages both ways until either side closes.
func serveDebug(session *ipc.Session, command []string, logger *slog.Logger) {
	adapter, err := debugger.Start(command, session.Hello.WorkspaceRoot, debuggerReadyWait)
	if err != nil {
		logger.Info("debugger did not start", "error", err)
		return
	}
	defer adapter.Close()
	logger.Info("debug session started", "root", session.Hello.WorkspaceRoot)
	done := make(chan struct{}, 2)
	var writeLock sync.Mutex // the adapter's replies and the program's output share one writer
	write := func(payload []byte) error {
		writeLock.Lock()
		defer writeLock.Unlock()
		return session.Writer.Write(payload)
	}
	go func() {
		writer := rpc.NewWriter(adapter.Conn())
		for {
			payload, err := session.Reader.Read()
			if err != nil || writer.Write(payload) != nil {
				break
			}
		}
		done <- struct{}{}
	}()
	go func() {
		reader := rpc.NewReader(adapter.Conn(), 64<<20)
		for {
			payload, err := reader.Read()
			if err != nil || write(payload) != nil {
				break
			}
		}
		done <- struct{}{}
	}()
	// Delve writes the program's stdout and stderr to its own, not to DAP events; pass them on as output events.
	go func() {
		for chunk := range adapter.Output() {
			category := "stdout"
			if chunk.Stderr {
				category = "stderr"
			}
			event, err := json.Marshal(map[string]any{"seq": 0, "type": "event", "event": "output", "body": map[string]string{"category": category, "output": string(chunk.Data)}})
			if err == nil && write(event) != nil {
				return
			}
		}
	}()
	<-done
}
