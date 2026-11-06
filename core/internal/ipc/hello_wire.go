//go:build unix

package ipc

import (
	"gobi/core/internal/wire"
)

// Field numbers of the handshake messages. Never reuse a number; add new ones at the end.
const (
	helloProtocol      = 1
	helloClientVersion = 2
	helloChannel       = 3
	helloWorkspaceRoot = 4
	helloTrusted       = 5
	helloLanguage      = 6
	helloGoRoot        = 7
	helloShell         = 8
	helloTool          = 9

	replyOK       = 1
	replyProtocol = 2
	replyError    = 3
)

// EncodeHello returns the binary form of a Hello.
func EncodeHello(hello Hello) []byte {
	var w wire.Writer
	w.Uint(helloProtocol, uint64(hello.Protocol))
	w.String(helloClientVersion, hello.ClientVersion)
	w.String(helloChannel, hello.Channel)
	w.String(helloWorkspaceRoot, hello.WorkspaceRoot)
	w.Bool(helloTrusted, hello.Trusted)
	w.String(helloLanguage, hello.Language)
	w.String(helloGoRoot, hello.GoRoot)
	w.String(helloShell, hello.Shell)
	w.String(helloTool, hello.Tool)
	return w.Bytes()
}

// DecodeHello reads a Hello; fields it does not know are ignored.
func DecodeHello(data []byte) (Hello, error) {
	fields, err := wire.Parse(data)
	if err != nil {
		return Hello{}, err
	}
	var hello Hello
	for _, field := range fields {
		switch field.Number {
		case helloProtocol:
			hello.Protocol = int(field.Uint)
		case helloClientVersion:
			hello.ClientVersion = string(field.Bytes)
		case helloChannel:
			hello.Channel = string(field.Bytes)
		case helloWorkspaceRoot:
			hello.WorkspaceRoot = string(field.Bytes)
		case helloTrusted:
			hello.Trusted = field.Uint != 0
		case helloLanguage:
			hello.Language = string(field.Bytes)
		case helloGoRoot:
			hello.GoRoot = string(field.Bytes)
		case helloShell:
			hello.Shell = string(field.Bytes)
		case helloTool:
			hello.Tool = string(field.Bytes)
		}
	}
	return hello, nil
}

// EncodeReply returns the binary form of a Reply.
func EncodeReply(reply Reply) []byte {
	var w wire.Writer
	w.Bool(replyOK, reply.OK)
	w.Uint(replyProtocol, uint64(reply.Protocol))
	w.String(replyError, reply.Error)
	return w.Bytes()
}

// DecodeReply reads a Reply.
func DecodeReply(data []byte) (Reply, error) {
	fields, err := wire.Parse(data)
	if err != nil {
		return Reply{}, err
	}
	var reply Reply
	for _, field := range fields {
		switch field.Number {
		case replyOK:
			reply.OK = field.Uint != 0
		case replyProtocol:
			reply.Protocol = int(field.Uint)
		case replyError:
			reply.Error = string(field.Bytes)
		}
	}
	return reply, nil
}
