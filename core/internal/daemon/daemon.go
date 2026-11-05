//go:build unix

// Package daemon wires the unix-socket transport to the language-server brokers.
package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"gobi/core/internal/ipc"
	"gobi/core/internal/lsp"
)

// DefaultLanguage is used when a client does not name one.
const DefaultLanguage = "go"

// Config describes one gobid instance.
type Config struct {
	SocketDir string
	// Servers maps a language name to the command of its language server over stdio.
	Servers map[string][]string
	Logger  *slog.Logger
}

// Run serves the lsp channel until ctx is cancelled, then removes the socket and stops every server.
// It returns ipc.ErrAlreadyRunning if another gobid owns SocketDir.
func Run(ctx context.Context, config Config) error {
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	server, err := ipc.Listen(config.SocketDir)
	if err != nil {
		return err
	}
	registry := lsp.NewRegistry(func(workspace lsp.Workspace) *lsp.Broker {
		brokerConfig := lsp.Config{Root: workspace.Root, Command: config.Servers[workspace.Language], Logger: config.Logger}
		if !workspace.Trusted {
			// An untrusted workspace must not make `go` download or switch toolchains.
			brokerConfig.Env = append(os.Environ(), "GOTOOLCHAIN=local")
		}
		return lsp.NewBroker(brokerConfig)
	})
	server.SetAdmit(func(hello ipc.Hello) string {
		if _, known := config.Servers[languageOf(hello)]; !known {
			return fmt.Sprintf("language %q is not supported", languageOf(hello))
		}
		return terminalAdmit(hello)
	})
	server.Handle("lsp", func(session *ipc.Session) {
		hello := session.Hello
		workspace := lsp.Workspace{Root: hello.WorkspaceRoot, Language: languageOf(hello), Trusted: hello.Trusted}
		config.Logger.Info("lsp client attached", "root", workspace.Root, "language", workspace.Language, "trusted", workspace.Trusted, "client", hello.ClientVersion)
		registry.Serve(workspace, session.Reader, session.Writer)
		config.Logger.Info("lsp client detached", "root", workspace.Root, "language", workspace.Language)
	})

	server.Handle("pty", func(session *ipc.Session) { serveTerminal(session, config.Logger) })
	server.Handle("control", func(session *ipc.Session) { serveControl(session, config.Logger) })

	served := make(chan error, 1)
	go func() { served <- server.Serve() }()
	config.Logger.Info("gobid listening", "dir", config.SocketDir)

	select {
	case <-ctx.Done():
	case err := <-served:
		registry.Close()
		return err
	}
	server.Close()
	registry.Close()
	<-served
	return nil
}

func languageOf(hello ipc.Hello) string {
	if hello.Language == "" {
		return DefaultLanguage
	}
	return hello.Language
}
