//go:build unix

package daemon

import (
	"context"
	"log/slog"

	"gobi/core/internal/ipc"
	"gobi/core/internal/runner"
	"gobi/core/internal/wire"
)

// Field numbers of the run channel messages (protobuf wire format, see package wire). Never reuse a number.
//
//	client to server: 1 kind (1 start, 2 stop)
//	  start adds:     2 command ("run", "test", "vet", "build"), 3 package (repeated), 4 test filter, 5 argument (repeated; run only, and -a for build),
//	                  6 environment file inside the project (empty: .env when present; "-": none),
//	                  7 Go folder to use (absolute, holds bin/go; empty: the go on PATH),
//	                  8 environment entry KEY=VALUE from the active profile (repeated)
//	server to client: 1 kind (1 output, 2 test, 3 exit)
//	  output adds:    2 data, 6 stream (1 stdout, 2 stderr)
//	  test adds:      7 action, 8 package, 9 test name, 10 elapsed milliseconds, 11 output text
//	  exit adds:      12 exit code, 13 message (why a request was refused; exit code 125)
//
// workspace_root in the handshake is the folder the commands run in. One run at a time per connection.
const (
	runKind     = 1
	runCommand  = 2
	runPackage  = 3
	runFilter   = 4
	runArg      = 5
	runEnvFile  = 6
	runGoRoot   = 7
	runEnvEntry = 8
	runStream   = 6
	runAction   = 7
	runPkgName  = 8
	runTest     = 9
	runElapsed  = 10
	runOutput   = 11
	runExitCode = 12
	runMessage  = 13
	runData     = 2

	runStart = 1
	runStop  = 2

	runOutputKind = 1
	runTestKind   = 2
	runExitKind   = 3

	runRefused = 125
)

// runAdmit refuses the run channel for a workspace the user has not trusted: running a project runs its code.
func runAdmit(hello ipc.Hello) string {
	if hello.Channel == "run" && !hello.Trusted {
		return "running code is off in Restricted Mode; trust the project first"
	}
	return ""
}

func serveRun(session *ipc.Session, logger *slog.Logger) {
	var current *runner.Run
	var done chan struct{}
	stopCurrent := func() {
		if current != nil {
			current.Stop()
			<-done
			current, done = nil, nil
		}
	}
	defer stopCurrent()

	for {
		payload, err := session.Reader.Read()
		if err != nil {
			return
		}
		fields, err := wire.Parse(payload)
		if err != nil {
			return
		}
		var kind uint64
		request := runner.Request{Dir: session.Hello.WorkspaceRoot}
		for _, field := range fields {
			switch field.Number {
			case runKind:
				kind = field.Uint
			case runCommand:
				request.Kind = string(field.Bytes)
			case runPackage:
				request.Packages = append(request.Packages, string(field.Bytes))
			case runFilter:
				request.Filter = string(field.Bytes)
			case runArg:
				request.Args = append(request.Args, string(field.Bytes))
			case runEnvFile:
				request.EnvFile = string(field.Bytes)
			case runGoRoot:
				request.GoRoot = string(field.Bytes)
			case runEnvEntry:
				request.Env = append(request.Env, string(field.Bytes))
			}
		}
		switch kind {
		case runStop:
			if current != nil {
				current.Stop()
			}
		case runStart:
			if current != nil {
				select {
				case <-done: // the previous run has finished
					current, done = nil, nil
				default:
					refuse(session, "a run is already in progress")
					continue
				}
			}
			run, err := runner.Start(context.Background(), request)
			if err != nil {
				logger.Info("run refused", "kind", request.Kind, "error", err)
				refuse(session, err.Error())
				continue
			}
			logger.Info("run started", "kind", request.Kind, "root", request.Dir)
			current, done = run, make(chan struct{})
			go func(run *runner.Run, done chan struct{}) {
				defer close(done)
				for event := range run.Events() {
					if session.Writer.Write(encodeRunEvent(event)) != nil {
						run.Stop()
					}
				}
			}(run, done)
		}
	}
}

func refuse(session *ipc.Session, reason string) {
	var message wire.Writer
	message.Uint(runKind, runExitKind)
	message.Uint(runExitCode, runRefused)
	message.String(runMessage, reason)
	session.Writer.Write(message.Bytes())
}

func encodeRunEvent(event runner.Event) []byte {
	var message wire.Writer
	switch event.Kind {
	case runner.EventOutput:
		message.Uint(runKind, runOutputKind)
		message.Raw(runData, event.Data)
		message.Uint(runStream, uint64(event.Stream))
	case runner.EventTest:
		message.Uint(runKind, runTestKind)
		message.String(runAction, event.Action)
		message.String(runPkgName, event.Package)
		message.String(runTest, event.Test)
		message.Uint(runElapsed, event.ElapsedMillis)
		message.String(runOutput, event.Output)
	default:
		message.Uint(runKind, runExitKind)
		message.Uint(runExitCode, uint64(event.ExitCode))
		message.String(runMessage, event.Message)
	}
	return message.Bytes()
}
