package main

import "testing"

func TestVersionLine(t *testing.T) {
	oldVersion, oldCommit := version, commit
	defer func() { version, commit = oldVersion, oldCommit }()

	version, commit = "dev", ""
	if got := versionLine(); got != "gobid dev" {
		t.Errorf("without flags: %q", got)
	}
	version, commit = "0.1.0-alpha.1", "abc1234"
	if got := versionLine(); got != "gobid 0.1.0-alpha.1 (abc1234)" {
		t.Errorf("with flags: %q", got)
	}
}
