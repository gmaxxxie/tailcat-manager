package tailcat

import (
	"strconv"
	"strings"
)

// Known-good CLI version pin. Tailcat has no stability promises, so the CLI
// adapter should be considered pinned to a minimum release. Values are
// advisory: the manager warns when the installed version is older than
// MinVersion or is an unknown/dev build, rather than refusing to run.
//
// The current upstream release line is v0.1.0 (see upstream README /
// container tags).
var (
	// MinVersion is the oldest CLI version we expect to understand.
	MinVersion = [3]int{0, 1, 0}

	// MinVersionStr is MinVersion in "vX.Y.Z" form, for display.
	MinVersionStr = "v0.1.0"
)

// versionOK reports whether a `tailcat version` output is acceptable. It
// accepts a real semver >= MinVersion, pseudo-versions (v0.0.0-20260831...-hash,
// the module version of a git commit, meaning "current"), and
// "(devel)"/empty/unknown (source builds) which we can't reject without
// information.
func versionOK(v string) bool {
	v = strings.TrimSpace(v)
	if v == "" || v == "unknown" || v == "(devel)" {
		return true // source/dev build; assume current
	}
	// Pseudo-version: v<X>.<Y>.<Z>-20<YY><MM><DD>...-<hash> => built from a
	// git commit; treat as current.
	if i := strings.IndexByte(v, '-'); i >= 0 {
		pre := v[i+1:]
		if len(pre) >= 8 && pre[:4] >= "2000" && pre[:4] <= "2099" {
			return true
		}
	}
	t := parseSemver(v)
	if t == nil {
		return false // unparsable version; flag it
	}
	for i := 0; i < 3; i++ {
		if t[i] > MinVersion[i] {
			return true
		}
		if t[i] < MinVersion[i] {
			return false
		}
	}
	return true
}

// parseSemver extracts the major.minor.patch from a "v1.2.3" or "1.2.3" string
// (ignoring any -pre suffix). Returns nil if not parseable.
func parseSemver(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	pre := strings.IndexAny(v, "-+")
	if pre >= 0 {
		v = v[:pre]
	}
	parts := strings.Split(v, ".")
	if len(parts) < 3 {
		return nil
	}
	out := make([]int, 3)
	for i, p := range parts[:3] {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nil
		}
		out[i] = n
	}
	return out
}
