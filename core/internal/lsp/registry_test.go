package lsp

import (
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

func newTestRegistry() *Registry {
	return NewRegistry(func(workspace Workspace) *Broker {
		config := Config{
			Root:         workspace.Root,
			Command:      []string{fakeBinary},
			Logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
			RestartDelay: 10 * time.Millisecond,
		}
		if !workspace.Trusted {
			config.Env = append(os.Environ(), "GOTOOLCHAIN=local")
		}
		return NewBroker(config)
	})
}

func serveVia(registry *Registry, root string, trusted bool) func(*rpc.Reader, *rpc.Writer) error {
	return serveLanguageVia(registry, root, "go", trusted)
}

func serveLanguageVia(registry *Registry, root, language string, trusted bool) func(*rpc.Reader, *rpc.Writer) error {
	return func(reader *rpc.Reader, writer *rpc.Writer) error {
		return registry.Serve(Workspace{Root: root, Language: language, Trusted: trusted}, reader, writer)
	}
}

func TestRegistryKeepsLanguagesOfOneWorkspaceApart(t *testing.T) {
	registry := newTestRegistry()
	t.Cleanup(registry.Close)

	goClient := newTestClientVia(t, serveLanguageVia(registry, "/work/a", "go", false))
	jsonClient := newTestClientVia(t, serveLanguageVia(registry, "/work/a", "json", false))
	goClient.initialize()
	jsonClient.initialize()

	if decodeResult[pidResult](t, goClient.call("fake/pid", nil)).PID == decodeResult[pidResult](t, jsonClient.call("fake/pid", nil)).PID {
		t.Fatal("each language needs its own server process")
	}
}

func TestRegistrySharesOneServerPerWorkspace(t *testing.T) {
	registry := newTestRegistry()
	t.Cleanup(registry.Close)

	first := newTestClientVia(t, serveVia(registry, "/work/a", false))
	sameWorkspace := newTestClientVia(t, serveVia(registry, "/work/a", false))
	otherWorkspace := newTestClientVia(t, serveVia(registry, "/work/b", false))
	for _, client := range []*testClient{first, sameWorkspace, otherWorkspace} {
		client.initialize()
	}

	pidFirst := decodeResult[pidResult](t, first.call("fake/pid", nil)).PID
	pidSame := decodeResult[pidResult](t, sameWorkspace.call("fake/pid", nil)).PID
	pidOther := decodeResult[pidResult](t, otherWorkspace.call("fake/pid", nil)).PID
	if pidFirst != pidSame {
		t.Fatalf("same workspace must share a server: %d vs %d", pidFirst, pidSame)
	}
	if pidFirst == pidOther {
		t.Fatal("different workspaces must not share a server")
	}
}

func TestRegistryStopsTheServerWhenTheLastClientLeaves(t *testing.T) {
	registry := newTestRegistry()
	t.Cleanup(registry.Close)

	leaving := newTestClientVia(t, serveVia(registry, "/work/a", false))
	leaving.initialize()
	before := decodeResult[pidResult](t, leaving.call("fake/pid", nil)).PID
	leaving.pipe.Close()
	waitFor(t, "the workspace to be released", func() bool { return registry.size() == 0 })

	returning := newTestClientVia(t, serveVia(registry, "/work/a", false))
	returning.initialize()
	if after := decodeResult[pidResult](t, returning.call("fake/pid", nil)).PID; after == before {
		t.Fatal("a fresh server must start after the old one was released")
	}
}

func TestUntrustedWorkspaceRunsTheServerWithLocalToolchain(t *testing.T) {
	registry := newTestRegistry()
	t.Cleanup(registry.Close)

	untrusted := newTestClientVia(t, serveVia(registry, "/work/a", false))
	trusted := newTestClientVia(t, serveVia(registry, "/work/a", true))
	untrusted.initialize()
	trusted.initialize()

	type envResult struct {
		GOTOOLCHAIN string `json:"gotoolchain"`
	}
	if got := decodeResult[envResult](t, untrusted.call("fake/env", nil)); got.GOTOOLCHAIN != "local" {
		t.Fatalf("untrusted workspace must pin GOTOOLCHAIN=local, got %q", got.GOTOOLCHAIN)
	}
	if got := decodeResult[envResult](t, trusted.call("fake/env", nil)); got.GOTOOLCHAIN == "local" {
		t.Fatal("a trusted workspace keeps the user's toolchain setting")
	}
	pidUntrusted := decodeResult[pidResult](t, untrusted.call("fake/pid", nil)).PID
	pidTrusted := decodeResult[pidResult](t, trusted.call("fake/pid", nil)).PID
	if pidUntrusted == pidTrusted {
		t.Fatal("trust levels must not share a server process")
	}
}
