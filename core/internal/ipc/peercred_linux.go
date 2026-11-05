package ipc

import (
	"net"

	"golang.org/x/sys/unix"
)

// peerUID returns the effective UID of the process on the other end of conn.
func peerUID(conn *net.UnixConn) (uint32, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var credentials *unix.Ucred
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, sockErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return 0, err
	}
	if sockErr != nil {
		return 0, sockErr
	}
	return credentials.Uid, nil
}
