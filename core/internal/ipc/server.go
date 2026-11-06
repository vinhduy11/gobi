//go:build unix

package ipc

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"gobi/core/internal/rpc"
)

// ProtocolVersion is the only handshake version this build speaks.
const ProtocolVersion = 1

const (
	maxHandshake            = 64 << 10
	maxMessage              = 64 << 20
	defaultHandshakeTimeout = 5 * time.Second
)

// Channels are separate connections, never multiplexed on one stream.
var knownChannels = map[string]bool{"control": true, "lsp": true, "dap": true, "pty": true, "run": true, "git": true}

// Hello is the first message a client sends on a new connection.
type Hello struct {
	Protocol      int    `json:"protocol"`
	ClientVersion string `json:"client_version"`
	Channel       string `json:"channel"`
	WorkspaceRoot string `json:"workspace_root,omitempty"`
	// Trusted says the user trusted this workspace; the default (false) runs tools restricted.
	Trusted bool `json:"trusted,omitempty"`
	// Language selects the language service on the lsp channel ("go", "json", "markdown"); empty means "go".
	Language string `json:"language,omitempty"`
	// GoRoot is the Go installation the language server should use (a folder holding bin/go); empty uses the go on PATH.
	GoRoot string `json:"go_root,omitempty"`
	// Shell is the shell a terminal starts (an absolute path listed in /etc/shells); empty uses the user's login shell.
	Shell string `json:"shell,omitempty"`
	// Tool is an absolute path that replaces the program the channel runs: git on the git channel, gopls on the lsp channel (Go).
	// Empty uses the one on PATH.
	Tool string `json:"tool,omitempty"`
}

// Reply answers a Hello.
type Reply struct {
	OK       bool   `json:"ok"`
	Protocol int    `json:"protocol"`
	Error    string `json:"error,omitempty"`
}

// Session is an accepted (or dialed) connection after a successful handshake.
type Session struct {
	Hello  Hello
	Reader *rpc.Reader
	Writer *rpc.Writer
	conn   net.Conn
}

func newSession(conn net.Conn, hello Hello, reader *rpc.Reader) *Session {
	return &Session{Hello: hello, Reader: reader, Writer: rpc.NewWriter(conn), conn: conn}
}

func (s *Session) Close() error { return s.conn.Close() }

// Handler serves one session of a channel; the connection is closed when it returns.
type Handler func(*Session)

// Server accepts connections on the gobid socket.
type Server struct {
	listener         *net.UnixListener
	lockFile         *os.File
	socketPath       string
	handshakeTimeout time.Duration

	handlersLock sync.RWMutex
	handlers     map[string]Handler
	admit        func(Hello) string
	closing      closer
}

func newServer(listener *net.UnixListener, lockFile *os.File, socketPath string) *Server {
	return &Server{
		listener:         listener,
		lockFile:         lockFile,
		socketPath:       socketPath,
		handshakeTimeout: defaultHandshakeTimeout,
		handlers:         map[string]Handler{},
	}
}

// Handle registers the handler for a channel.
func (s *Server) Handle(channel string, handler Handler) {
	s.handlersLock.Lock()
	defer s.handlersLock.Unlock()
	s.handlers[channel] = handler
}

// SetAdmit installs a check run after the built-in validation; a non-empty return refuses the handshake with that reason.
func (s *Server) SetAdmit(admit func(Hello) string) {
	s.handlersLock.Lock()
	defer s.handlersLock.Unlock()
	s.admit = admit
}

// Serve accepts connections until Close is called, then returns nil.
func (s *Server) Serve() error {
	for {
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.serveConn(conn)
	}
}

// Close stops accepting, removes the socket and releases the single-instance lock.
func (s *Server) Close() error {
	return s.closing.do(func() error {
		err := s.listener.Close()
		os.Remove(s.socketPath)
		s.lockFile.Close()
		return err
	})
}

func (s *Server) serveConn(conn *net.UnixConn) {
	defer conn.Close()
	if uid, err := peerUID(conn); err != nil || int(uid) != os.Geteuid() {
		return
	}
	session, handler, err := s.handshake(conn)
	if err != nil {
		return
	}
	handler(session)
}

func (s *Server) handshake(conn net.Conn) (*Session, Handler, error) {
	conn.SetDeadline(time.Now().Add(s.handshakeTimeout))
	reader := rpc.NewReader(conn, maxHandshake)
	writer := rpc.NewWriter(conn)

	payload, err := reader.Read()
	if err != nil {
		return nil, nil, err
	}
	hello, err := DecodeHello(payload)
	if err != nil {
		return nil, nil, reject(writer, "malformed handshake: the handshake is binary (protobuf wire format), not JSON")
	}
	handler, problem := s.validate(hello)
	if problem != "" {
		return nil, nil, reject(writer, problem)
	}
	if err := writer.Write(EncodeReply(Reply{OK: true, Protocol: ProtocolVersion})); err != nil {
		return nil, nil, err
	}
	conn.SetDeadline(time.Time{})
	return newSession(conn, hello, rpc.NewReader(conn, maxMessage)), handler, nil
}

func (s *Server) validate(hello Hello) (Handler, string) {
	if hello.Protocol != ProtocolVersion {
		return nil, fmt.Sprintf("unsupported protocol version %d, server speaks %d", hello.Protocol, ProtocolVersion)
	}
	if !knownChannels[hello.Channel] {
		return nil, fmt.Sprintf("unknown channel %q", hello.Channel)
	}
	if hello.Channel == "lsp" && hello.WorkspaceRoot == "" {
		return nil, "lsp channel needs a workspace_root"
	}
	s.handlersLock.RLock()
	handler, admit := s.handlers[hello.Channel], s.admit
	s.handlersLock.RUnlock()
	if handler == nil {
		return nil, fmt.Sprintf("channel %q is not available", hello.Channel)
	}
	if admit != nil {
		if reason := admit(hello); reason != "" {
			return nil, reason
		}
	}
	return handler, ""
}

func reject(writer *rpc.Writer, problem string) error {
	writer.Write(EncodeReply(Reply{OK: false, Protocol: ProtocolVersion, Error: problem}))
	return errors.New(problem)
}

// Dial connects to a gobid socket and performs the handshake. A zero Protocol means the current one.
func Dial(socketPath string, hello Hello) (*Session, error) {
	conn, err := net.DialTimeout("unix", socketPath, defaultHandshakeTimeout)
	if err != nil {
		return nil, err
	}
	if hello.Protocol == 0 {
		hello.Protocol = ProtocolVersion
	}
	conn.SetDeadline(time.Now().Add(defaultHandshakeTimeout))
	reader := rpc.NewReader(conn, maxMessage)
	writer := rpc.NewWriter(conn)

	if err := writer.Write(EncodeHello(hello)); err != nil {
		conn.Close()
		return nil, err
	}
	answer, err := reader.Read()
	if err != nil {
		conn.Close()
		return nil, err
	}
	reply, err := DecodeReply(answer)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("ipc: bad handshake reply: %w", err)
	}
	if !reply.OK {
		conn.Close()
		return nil, fmt.Errorf("ipc: handshake rejected: %s", reply.Error)
	}
	conn.SetDeadline(time.Time{})
	return &Session{Hello: hello, Reader: reader, Writer: writer, conn: conn}, nil
}
