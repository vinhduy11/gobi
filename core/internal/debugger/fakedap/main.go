// Command fakedap stands in for `dlv dap` in tests: it announces a TCP address the way dlv does and echoes every byte back.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "silent" {
		select {} // never announces an address
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		os.Exit(1)
	}
	fmt.Printf("DAP server listening at: %s\n", listener.Addr())
	fmt.Println("program says hi")
	fmt.Fprint(os.Stderr, "err line")
	conn, err := listener.Accept()
	if err != nil {
		os.Exit(1)
	}
	io.Copy(conn, conn)
}
