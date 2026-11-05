package lsp

import (
	"sync"

	"gobi/core/internal/rpc"
)

type workspaceKey struct {
	root    string
	trusted bool
}

type registryEntry struct {
	broker  *Broker
	clients int
}

// Registry hands out one Broker per workspace root and trust level. A broker is created for the
// first client and closed when the last one leaves. Trust levels never share a server because an
// untrusted workspace runs gopls with a restricted environment.
type Registry struct {
	newBroker func(root string, trusted bool) *Broker

	lock    sync.Mutex
	entries map[workspaceKey]*registryEntry
}

func NewRegistry(newBroker func(root string, trusted bool) *Broker) *Registry {
	return &Registry{newBroker: newBroker, entries: map[workspaceKey]*registryEntry{}}
}

// Serve attaches one client to the workspace's broker and returns when the client disconnects.
func (r *Registry) Serve(root string, trusted bool, reader *rpc.Reader, writer *rpc.Writer) error {
	key := workspaceKey{root, trusted}
	broker := r.acquire(key)
	defer r.release(key)
	return broker.Attach(reader, writer)
}

func (r *Registry) acquire(key workspaceKey) *Broker {
	r.lock.Lock()
	defer r.lock.Unlock()
	entry := r.entries[key]
	if entry == nil {
		entry = &registryEntry{broker: r.newBroker(key.root, key.trusted)}
		r.entries[key] = entry
	}
	entry.clients++
	return entry.broker
}

func (r *Registry) release(key workspaceKey) {
	r.lock.Lock()
	entry := r.entries[key]
	entry.clients--
	last := entry.clients == 0
	if last {
		delete(r.entries, key)
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
