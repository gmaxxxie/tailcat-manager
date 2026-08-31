// Package validate holds input-shape checks shared across the manager. It has
// no Tailcat dependency; full token validation happens in the tailcat backend.
package validate

import "regexp"

// tokenRX matches the shape of a valid tailcat token: "tc" + base64url
// (alphabet [A-Za-z0-9_-], no padding, no dots). Tokens are case-sensitive and
// never contain dots (a dot means DNS name in tailcat's own heuristic).
var tokenRX = regexp.MustCompile(`^tc[A-Za-z0-9_-]{20,}$`)

// dnsRX is a permissive-but-safe DNS name check; it requires at least one dot
// (a bare label like "localhost" is not a valid tailcat target).
var dnsRX = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))+$`)

// TokenShapeOK reports whether s has the shape of a tailcat token.
func TokenShapeOK(s string) bool { return tokenRX.MatchString(s) }

// DNSNameOK reports whether s looks like a DNS name.
func DNSNameOK(s string) bool { return dnsRX.MatchString(s) }

// IsValidTarget classifies a connection target. It returns "token", "dns", or
// "" (invalid). It only checks shape; token semantics need the backend.
func IsValidTarget(s string) (string, bool) {
	if s == "" {
		return "", false
	}
	if TokenShapeOK(s) {
		return "token", true
	}
	if DNSNameOK(s) {
		return "dns", true
	}
	return "", false
}
