//go:build unix

// Package daemon wires the unix-socket transport to the language-server brokers.
package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

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
	// LogLevel, when set, can be changed while running through the control channel.
	LogLevel *slog.LevelVar
}

// Run serves the lsp channel until ctx is cancelled, then removes the socket and stops every server.
// It returns ipc.ErrAlreadyRunning if another gobid owns SocketDir.
func Run(ctx context.Context, config Config) error {
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	started := time.Now()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	server, err := ipc.Listen(config.SocketDir)
	if err != nil {
		return err
	}
	registry := lsp.NewRegistry(func(workspace lsp.Workspace) *lsp.Broker {
		brokerConfig := lsp.Config{Root: workspace.Root, Command: config.Servers[workspace.Language], Logger: config.Logger}
		if workspace.Tool != "" && len(brokerConfig.Command) > 0 && workspace.Language == DefaultLanguage {
			brokerConfig.Command = append([]string{workspace.Tool}, brokerConfig.Command[1:]...)
		}
		if !workspace.Trusted {
			// An untrusted workspace must not make `go` download or switch toolchains.
			brokerConfig.Env = append(os.Environ(), "GOTOOLCHAIN=local")
		}
		if workspace.GoRoot != "" {
			brokerConfig.Env = goEnv(workspace.GoRoot, os.Environ())
		}
		return lsp.NewBroker(brokerConfig)
	})
	server.SetAdmit(func(hello ipc.Hello) string {
		if _, known := config.Servers[languageOf(hello)]; !known {
			return fmt.Sprintf("language %q is not supported", languageOf(hello))
		}
		if reason := goAdmit(hello); reason != "" {
			return reason
		}
		if reason := toolAdmit(hello); reason != "" {
			return reason
		}
		if reason := debugAdmit(hello, config.Servers); reason != "" {
			return reason
		}
		return gitAdmit(hello)
	})
	server.Handle("lsp", func(session *ipc.Session) {
		hello := session.Hello
		workspace := lsp.Workspace{Root: hello.WorkspaceRoot, Language: languageOf(hello), Trusted: hello.Trusted, GoRoot: hello.GoRoot, Tool: hello.Tool}
		config.Logger.Info("lsp client attached", "root", workspace.Root, "language", workspace.Language, "trusted", workspace.Trusted, "client", hello.ClientVersion)
		registry.Serve(workspace, session.Reader, session.Writer)
		config.Logger.Info("lsp client detached", "root", workspace.Root, "language", workspace.Language)
	})

	server.Handle("dap", func(session *ipc.Session) { serveDebug(session, config.Servers["dap"], config.Logger) })
	server.Handle("git", func(session *ipc.Session) { serveGit(session, config.Logger) })
	server.Handle("run", func(session *ipc.Session) { serveRun(session, config.Logger) })
	server.Handle("pty", func(session *ipc.Session) { serveTerminal(session, config.Logger) })
	server.Handle("control", func(session *ipc.Session) {
		serveControl(session, config.Logger, controlHooks{level: config.LogLevel, stop: cancel, started: started})
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

func languageOf(hello ipc.Hello) string {
	if hello.Language == "" {
		return DefaultLanguage
	}
	return hello.Language
}

// goEnv is base with the chosen Go first on PATH, GOROOT set and GOTOOLCHAIN=local, so tools started with it use exactly that Go.
func goEnv(goRoot string, base []string) []string {
	existing := ""
	for _, entry := range base {
		if value, found := strings.CutPrefix(entry, "PATH="); found {
			existing = value
		}
	}
	path := filepath.Join(goRoot, "bin") + string(os.PathListSeparator) + existing
	return append(append([]string{}, base...), "GOROOT="+goRoot, "GOTOOLCHAIN=local", "PATH="+path)
}

// goAdmit refuses a handshake that names a Go folder that is not an installation.
func goAdmit(hello ipc.Hello) string {
	if hello.GoRoot == "" || hello.Channel != "lsp" {
		return ""
	}
	if !filepath.IsAbs(hello.GoRoot) {
		return "the Go folder must be an absolute path"
	}
	if info, err := os.Stat(filepath.Join(hello.GoRoot, "bin", "go")); err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return hello.GoRoot + " is not a Go installation (no executable bin/go)"
	}
	return ""
}

// toolAdmit refuses a handshake whose program path (git on the git channel, gopls on lsp) is not an absolute path to an executable file.
func toolAdmit(hello ipc.Hello) string {
	if hello.Tool == "" || (hello.Channel != "git" && hello.Channel != "lsp") {
		return ""
	}
	if !filepath.IsAbs(hello.Tool) {
		return "the tool path must be an absolute path"
	}
	if info, err := os.Stat(hello.Tool); err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return hello.Tool + " is not an executable file"
	}
	return ""
}
