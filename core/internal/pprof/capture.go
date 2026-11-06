package pprof

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

var captureKinds = map[string]string{
	"cpu": "profile", "heap": "heap", "allocs": "allocs", "goroutine": "goroutine", "mutex": "mutex", "block": "block",
}

const maxSeconds = 120

// Capture downloads a profile from a program that serves net/http/pprof (`/debug/pprof/...`) and writes it to out. Only a
// loopback address is accepted, so the app cannot be made to reach into the network. `seconds` applies to cpu profiles.
func Capture(ctx context.Context, address, kind string, seconds int, out string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("the address must look like localhost:6060: %w", err)
	}
	if host != "localhost" && host != "127.0.0.1" && host != "::1" {
		return fmt.Errorf("only a program on this machine can be profiled, not %q", host)
	}
	if number, err := strconv.Atoi(port); err != nil || number < 1 || number > 65535 {
		return fmt.Errorf("%q is not a port", port)
	}
	endpoint, ok := captureKinds[kind]
	if !ok {
		return fmt.Errorf("unknown profile kind %q", kind)
	}
	if seconds < 0 || seconds > maxSeconds {
		return fmt.Errorf("a CPU profile can run for 1 to %d seconds", maxSeconds)
	}
	if !filepath.IsAbs(out) || filepath.Ext(out) != ".pprof" {
		return fmt.Errorf("the output must be an absolute path ending in .pprof")
	}
	if _, err := os.Lstat(out); err == nil { // fail before a 30 second CPU profile, not after
		return existsError(out, os.ErrExist)
	}
	url := "http://" + net.JoinHostPort(host, port) + "/debug/pprof/" + endpoint
	timeout := 20 * time.Second
	if kind == "cpu" {
		if seconds == 0 {
			seconds = 30
		}
		url += "?seconds=" + strconv.Itoa(seconds)
		timeout = time.Duration(seconds+20) * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return fmt.Errorf("cannot reach %s: %w", address, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %s (does the program import net/http/pprof?)", address, response.Status)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxProfileBytes))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	// O_EXCL: a capture never replaces a file that is already there.
	file, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return existsError(out, err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		os.Remove(out)
		return err
	}
	return file.Close()
}

func existsError(out string, err error) error {
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("%s already exists; choose a new file name", out)
	}
	return err
}
