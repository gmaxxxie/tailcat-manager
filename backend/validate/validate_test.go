package validate

import "testing"

func TestTokenShape(t *testing.T) {
	long := "tc" + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	cases := []struct {
		in   string
		want bool
	}{
		{long, true},
		{"tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", true},
		{"tc-short", false},
		{"tcABC123", false}, // too short after prefix
		{"t", false},
		{"tcABC.DEF", false}, // dots = DNS
		{"tcABC DEF", false},
		{"abcABCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", false}, // no tc prefix
		{"tcABC+", false}, // + not in base64url alphabet
	}
	for _, c := range cases {
		if got := TokenShapeOK(c.in); got != c.want {
			t.Errorf("TokenShapeOK(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestDNSName(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"example.com", true},
		{"my-server.example.com", true},
		{"tc302a.ipn.dev", true},
		{"foo", false}, // no dot
		{"-foo.example.com", false},
		{"foo..bar", false},
		{"https://example.com", false},
		{"../etc/passwd", false},
		{"foo bar.com", false},
	}
	for _, c := range cases {
		if got := DNSNameOK(c.in); got != c.want {
			t.Errorf("DNSNameOK(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestIsValidTarget(t *testing.T) {
	if k, ok := IsValidTarget("tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"); !ok || k != "token" {
		t.Errorf("expected token kind, got %q %v", k, ok)
	}
	if k, ok := IsValidTarget("example.com"); !ok || k != "dns" {
		t.Errorf("expected dns kind, got %q %v", k, ok)
	}
	if _, ok := IsValidTarget("rm -rf /"); ok {
		t.Errorf("shell-like input must be rejected")
	}
	if _, ok := IsValidTarget("  tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  "); ok {
		t.Errorf("whitespace not trimmed here (caller trims); shape check should reject")
	}
	if _, ok := IsValidTarget(""); ok {
		t.Errorf("empty must be rejected")
	}
}
