package main

import "fmt"

// Greet returns a greeting for name.
func Greet(name string) string { return fmt.Sprintf("hello, %s", name) }

func main() { fmt.Println(Greet("gobi")) }
