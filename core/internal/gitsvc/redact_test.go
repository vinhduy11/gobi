package gitsvc

import (
	"strings"
	"testing"
)

func TestRedactURL(t *testing.T) {
	cases := map[string]string{
		"https://user:token@example.test/team/repo.git":                          "https://user@example.test/team/repo.git",
		"https://user@example.test/team/repo.git":                                "https://user@example.test/team/repo.git",
		"https://example.test/team/repo.git":                                     "https://example.test/team/repo.git",
		"ssh://deploy:pw@example.test:22/repo.git":                               "ssh://deploy@example.test:22/repo.git",
		"git@example.test:team/repo.git":                                         "git@example.test:team/repo.git",
		"/srv/repos/a:b@c":                                                       "/srv/repos/a:b@c",
		"fatal: unable to access 'https://u:secret@example.test/r.git/': denied": "fatal: unable to access 'https://u@example.test/r.git/': denied",
	}
	for in, want := range cases {
		if got := RedactURL(in); got != want {
			t.Errorf("RedactURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRemotesAndErrorsHideCredentials(t *testing.T) {
	dir := repo(t)
	if err := testGit.AddRemote(dir, "origin", "https://user:token@example.test/team/repo.git"); err != nil {
		t.Fatal(err)
	}
	remotes, err := testGit.Remotes(dir)
	if err != nil || len(remotes) != 1 || strings.Contains(remotes[0].URL, "token") {
		t.Fatalf("remotes = %+v, %v", remotes, err)
	}
	// a failing fetch names the remote URL in git's message
	_, err = testGit.run(dir, nil, "fetch", "https://user:token@127.0.0.1:1/none.git")
	if err == nil || strings.Contains(err.Error(), "token") {
		t.Errorf("error must not carry the password: %v", err)
	}
}
