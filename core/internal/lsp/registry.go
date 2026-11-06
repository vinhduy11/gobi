package lsp

import (
	"sync"

	"gobi/core/internal/rpc"
)

// Workspace identifies one language server: a root folder, a language service and a trust level.
// Trust levels never share a server because an untrusted workspace runs with a restricted environment.
type Workspace struct {
	Root     string
	Language string
	Trusted  bool
	// GoRoot is the Go installation the server runs with; a different one is a different server.
	GoRoot string
	// Tool replaces the language server program (an absolute path); a different one is a different server.
	Tool string
}

type registryEntry struct {
	broker  *Broker
	clients int
}

// Registry hands out one Broker per Workspace, created for the first client and closed when the last leaves.
type Registry struct {
	newBroker func(Workspace) *Broker

	lock    sync.Mutex
	entries map[Workspace]*registryEntry
}

func NewRegistry(newBroker func(Workspace) *Broker) *Registry {
	return &Registry{newBroker: newBroker, entries: map[Workspace]*registryEntry{}}
}

// Serve attaches one client to the workspace's broker and returns when the client disconnects.
func (r *Registry) Serve(workspace Workspace, reader *rpc.Reader, writer *rpc.Writer) error {
	broker := r.acquire(workspace)
	defer r.release(workspace)
	return broker.Attach(reader, writer)
}

func (r *Registry) acquire(workspace Workspace) *Broker {
	r.lock.Lock()
	defer r.lock.Unlock()
	entry := r.entries[workspace]
	if entry == nil {
		entry = &registryEntry{broker: r.newBroker(workspace)}
		r.entries[workspace] = entry
	}
	entry.clients++
	return entry.broker
}

func (r *Registry) release(workspace Workspace) {
	r.lock.Lock()
	entry := r.entries[workspace]
	entry.clients--
	last := entry.clients == 0
	if last {
		delete(r.entries, workspace)
	}
	r.lock.Unlock()
	if last {
		entry.broker.Close()
	}
}

// Close stops every broker.
func (r *Registry) Close() {
	r.lock.Lock()
	brokers := make([]*Broker, 0, len(r.entries))
	for _, entry := range r.entries {
		brokers = append(brokers, entry.broker)
	}
	r.lock.Unlock()
	for _, broker := range brokers {
		broker.Close()
	}
}

func (r *Registry) size() int {
	r.lock.Lock()
	defer r.lock.Unlock()
	return len(r.entries)
}
