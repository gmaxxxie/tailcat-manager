package tailcat

import (
	"strings"
	"testing"
)

func TestRedact(t *testing.T) {
	tok := "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	s := "connected to " + tok + " and " + tok[:12]
	got := Redact(s)
	if strings.Contains(got, tok) {
		t.Fatalf("full token leaked: %q", got)
	}
	if !strings.Contains(got, "tc…"+tok[len(tok)-4:]) {
		t.Fatalf("expected redacted suffix form, got %q", got)
	}
	// short non-token text unchanged
	if Redact("hello world") != "hello world" {
		t.Errorf("non-token text should be unchanged")
	}
}

func TestVersionOK(t *testing.T) {
	cases := []struct {
		v    string
		want bool
	}{
		{"v0.1.0", true},
		{"v0.1.0-pre", true},
		{"v0.2.0", true},
		{"v1.0.0", true},
		{"v0.0.0-20260831042229-4d50a34f315d", true}, // pseudo-version (git build)
		{"(devel)", true},
		{"unknown", true},
		{"", true},
		{"v0.0.9", false},
		{"garbage", false},
	}
	for _, c := range cases {
		if got := versionOK(c.v); got != c.want {
			t.Errorf("versionOK(%q) = %v, want %v", c.v, got, c.want)
		}
	}
}
