package gitsvc

import "regexp"

var urlPassword = regexp.MustCompile(`(\b[A-Za-z][A-Za-z0-9+.-]*://[^\s/@:]+):[^\s/@]*@`)

// RedactURL drops the password from every scheme://user:password@host address in text (a URL or git's message), so a token
// typed into a remote never reaches the UI or a log. user@host and scp-style git@host:path are left as they are.
func RedactURL(text string) string { return urlPassword.ReplaceAllString(text, "$1@") }
