package tailcat

import "regexp"

// tokenInLogRX finds full tokens in free text for redaction.
var tokenInLogRX = regexp.MustCompile(`tc[A-Za-z0-9_-]{20,}`)

// Redact replaces full tokens in s with "tc…<last4>" so logs and diagnostics
// never leak a token. Not a security boundary, just defense in depth.
func Redact(s string) string {
	return tokenInLogRX.ReplaceAllStringFunc(s, func(m string) string {
		if len(m) <= 8 {
			return "tc…"
		}
		return "tc…" + m[len(m)-4:]
	})
}
