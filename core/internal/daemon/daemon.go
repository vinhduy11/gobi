//go:build unix

// Package daemon wires the unix-socket transport to the language-server brokers.
package daemon

import (
	"context"
	"log/slog"
	"os"

	"gobi/core/internal/ipc"
	"gobi/core/internal/lsp"
)

// Config describes one gobid instance.
type Config struct {
	SocketDir     string
	ServerCommand []string // the language server, normally the gopls binary
	Logger        *slog.Logger
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
	registry := lsp.NewRegistry(func(root string, trusted bool) *lsp.Broker {
		brokerConfig := lsp.Config{Root: root, Command: config.ServerCommand, Logger: config.Logger}
		if !trusted {
			// An untrusted workspace must not make `go` download or switch toolchains.
			brokerConfig.Env = append(os.Environ(), "GOTOOLCHAIN=local")
		}
		return lsp.NewBroker(brokerConfig)
	})
	server.Handle("lsp", func(session *ipc.Session) {
		hello := session.Hello
		config.Logger.Info("lsp client attached", "root", hello.WorkspaceRoot, "trusted", hello.Trusted, "client", hello.ClientVersion)
		registry.Serve(hello.WorkspaceRoot, hello.Trusted, session.Reader, session.Writer)
		config.Logger.Info("lsp client detached", "root", hello.WorkspaceRoot)
	})

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
