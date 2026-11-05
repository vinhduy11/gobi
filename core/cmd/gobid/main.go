// Command gobid is the Gobi core daemon.
//
//	gobid [serve] [-dir DIR]   serve the lsp channel on a private unix socket
//	gobid doctor               report go, gopls and dlv; exit 1 if a required tool is missing
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"text/tabwriter"

	"gobi/core/internal/daemon"
	"gobi/core/internal/ipc"
	"gobi/core/internal/toolchain"
)

func main() {
	command, args := "serve", os.Args[1:]
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		command, args = args[0], args[1:]
	}
	switch command {
	case "doctor":
		os.Exit(doctor())
	case "serve":
		os.Exit(serve(args))
	default:
		fmt.Fprintln(os.Stderr, "usage: gobid [serve] [-dir DIR] | gobid doctor")
		os.Exit(2)
	}
}

func serve(args []string) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	socketDir := flags.String("dir", ipc.SocketDir(os.TempDir()), "directory for the socket and lock file")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	goplsPath, err := toolchain.FromOS().Find("gopls")
	if err != nil {
		// Keep serving: clients get an "unavailable" error that says what to install.
		logger.Warn("gopls not found; language features will report unavailable", "error", err)
		goplsPath = "gopls"
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err = daemon.Run(ctx, daemon.Config{SocketDir: *socketDir, ServerCommand: []string{goplsPath}, Logger: logger})
	switch {
	case errors.Is(err, ipc.ErrAlreadyRunning):
		fmt.Fprintln(os.Stderr, "gobid: another instance is already running")
		return 1
	case err != nil:
		logger.Error("gobid stopped", "error", err)
		return 1
	}
	return 0
}

func doctor() int {
	reports := toolchain.Check(toolchain.FromOS(), toolchain.DefaultTools)
	table := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "TOOL\tSTATUS\tVERSION\tPATH")
	for _, report := range reports {
		status := "ok"
		switch {
		case !report.Found && report.Required:
			status = "MISSING"
		case !report.Found:
			status = "missing (optional)"
		case report.Problem != "":
			status = "error"
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%s\n", report.Name, status, report.Version, report.Path)
	}
	table.Flush()
	if toolchain.HasMissingRequired(reports) {
		return 1
	}
	return 0
}
