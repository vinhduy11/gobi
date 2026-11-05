// Package sample exercises every token kind the highlighter knows.
package sample

import (
	"fmt"
	"strings"
)

/* A block comment
   that spans two lines. */

const (
	Pi       = 3.14159
	Mask     = 0xFF_FF
	Big      = 1e-9
	Greeting = "hello, \"gobi\""
	Rune     = '\n'
)

// Server holds the state of a running service.
type Server struct {
	Name  string
	Ports []int
	raw   string
}

// Describe returns a short description of s.
func (s *Server) Describe() string {
	raw := `a raw string
that spans lines`
	var parts []string
	for i, port := range s.Ports {
		if port > 1024 && s.Name != "" {
			parts = append(parts, fmt.Sprintf("%d:%d", i, port))
		}
	}
	_ = raw
	return strings.Join(parts, ", ") // trailing comment
}

func main() {
	server := &Server{Name: "gobi", Ports: []int{8080, 9090}}
	defer fmt.Println("done", nil, true)
	fmt.Println(server.Describe())
}
