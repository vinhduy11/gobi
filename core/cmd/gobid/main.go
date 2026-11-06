// Command gobid is the Gobi core daemon.
//
//	gobid [serve] [-dir DIR] [-log FILE]   serve the lsp channel on a private unix socket; the log goes to FILE
//	                           (default ~/Library/Logs/Gobi/gobid.log on macOS, or $GOBI_LOG_DIR/gobid.log; "-" is stderr)
//	gobid version              print the version, commit, Go runtime and platform
//	gobid doctor               report go, gopls and dlv; exit 1 if a required tool is missing
//	gobid version              print the version this daemon was built as
//	gobid langserver           the built-in JSON and Markdown language service over stdio (started by gobid itself)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"syscall"
	"text/tabwriter"

	"gobi/core/internal/daemon"
	"gobi/core/internal/ipc"
	"gobi/core/internal/langsvc"
	"gobi/core/internal/logfile"
	"gobi/core/internal/toolchain"
)

// Set by the build (`go build -ldflags "-X main.version=… -X main.commit=…"`, see ui/macos/scripts/make-app.sh).
var (
	version = "dev"
	commit  = ""
)

const (
	logMaxBytes = 2 << 20
	logKeep     = 4
)

// buildCommit is the commit the binary was built from: the -ldflags value, else the VCS revision from the build info, else "unknown".
func buildCommit() string {
	if commit != "" {
		return commit
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			if setting.Key == "vcs.revision" && setting.Value != "" {
				return setting.Value[:min(12, len(setting.Value))]
			}
		}
	}
	return "unknown"
}

// defaultLogPath is the log file when -log is not given; "-" (stderr) where there is no standard log folder.
func defaultLogPath() string {
	if dir := os.Getenv("GOBI_LOG_DIR"); dir != "" {
		return filepath.Join(dir, "gobid.log")
	}
	if home, err := os.UserHomeDir(); err == nil && runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Logs", "Gobi", "gobid.log")
	}
	return "-"
}

func main() {
	// Started from Finder, the app (and so gobid) has only the system PATH; add where go, gopls and dlv usually are.
	toolchain.ExtendProcessPath()
	command, args := "serve", os.Args[1:]
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		command, args = args[0], args[1:]
	}
	switch command {
	case "version":
		fmt.Println(versionLine())
	case "doctor":
		os.Exit(doctor())
	case "serve":
		os.Exit(serve(args))
	case "langserver":
		if err := langsvc.Serve(os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "gobid langserver:", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: gobid [serve] [-dir DIR] | gobid doctor | gobid version | gobid langserver")
		os.Exit(2)
	}
}

// versionLine is `gobid 0.1.0-alpha.1 (abc1234)`, or `gobid dev` for a build without version flags.
func versionLine() string {
	if commit == "" {
		return "gobid " + version
	}
	return "gobid " + version + " (" + commit + ")"
}

func serve(args []string) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	socketDir := flags.String("dir", ipc.SocketDir(os.TempDir()), "directory for the socket and lock file")
	logPath := flags.String("log", defaultLogPath(), `log file, or "-" for stderr`)
	if err := flags.Parse(args); err != nil {
		return 2
	}

	level := new(slog.LevelVar)
	var sink io.Writer = os.Stderr
	if *logPath != "-" {
		file, err := logfile.Open(*logPath, logMaxBytes, logKeep)
		if err != nil {
			fmt.Fprintln(os.Stderr, "gobid: cannot open the log file, logging to stderr:", err)
		} else {
			defer file.Close()
			sink = file
		}
	}
	logger := slog.New(logfile.NewHandler(sink, level))
	defer func() {
		if r := recover(); r != nil {
			logger.Error("gobid panicked", "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
			os.Exit(2) // deferred Close does not run on os.Exit; the file is unbuffered, so nothing is lost
		}
	}()
	logger.Info("gobid starting", "version", version, "commit", buildCommit(), "pid", os.Getpid(), "go", runtime.Version(),
		"os", runtime.GOOS, "arch", runtime.GOARCH, "socket_dir", filepath.Base(*socketDir))
	goplsPath, err := toolchain.FromOS().Find("gopls")
	if err != nil {
		// Keep serving: clients get an "unavailable" error that says what to install.
		logger.Warn("gopls not found; language features will report unavailable", "error", err)
		goplsPath = "gopls"
	}

	servers := map[string][]string{"go": {goplsPath}}
	if dlvPath, err := toolchain.FromOS().Find("dlv"); err == nil {
		servers["dap"] = []string{dlvPath, "dap", "--listen=127.0.0.1:0"}
	}
	if self, err := os.Executable(); err == nil {
		builtIn := []string{self, "langserver"}
		servers["json"], servers["markdown"] = builtIn, builtIn
	} else {
		logger.Warn("cannot locate gobid itself; JSON and Markdown support is off", "error", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err = daemon.Run(ctx, daemon.Config{SocketDir: *socketDir, Servers: servers, Logger: logger, LogLevel: level})
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
