package tailcat

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"omarchy-tailcat/validate"
)

// CLIBackend implements Backend by wrapping the `tailcat` CLI binary.
// It always builds structured argument arrays (never a shell), validates all
// user input before use, and treats every CLI output as data (defensive
// parsing). See docs/security.md.
type CLIBackend struct {
	// Bin is the tailcat binary path. Empty means look up on PATH.
	Bin string
	// DerpMapURL overrides the default DERP map URL when non-empty.
	DerpMapURL string
	// ExtraEnv is appended to the child environment (used by tests to set
	// TS_DEBUG_TAILCAT_LOCAL_DERP etc.).
	ExtraEnv []string

	mu       sync.Mutex
	ln       *Listener
	lastSpec ListenerSpec
	hasSpec  bool
}

var _ Backend = (*CLIBackend)(nil)

// NewCLIBackend returns a CLI backend with defaults.
func NewCLIBackend() *CLIBackend { return &CLIBackend{} }

// Name implements Backend.
func (b *CLIBackend) Name() string { return "cli" }

func (b *CLIBackend) resolveBin() (string, error) {
	if b.Bin != "" {
		if fi, err := os.Stat(b.Bin); err == nil && !fi.IsDir() {
			return b.Bin, nil
		}
		return "", &Error{Kind: ErrNotInstalled, Message: "tailcat binary not found"}
	}
	p, err := exec.LookPath("tailcat")
	if err != nil {
		return "", &Error{
			Kind:    ErrNotInstalled,
			Message: "tailcat is not installed. Install it with `paru -S tailcat` (or `tailcat-bin`), then restart the manager.",
			Detail:  err.Error(),
		}
	}
	return p, nil
}

// run runs the tailcat binary with args (structured argv) and returns combined
// stdout+stderr. A non-zero exit becomes a *Error.
func (b *CLIBackend) run(ctx context.Context, args ...string) (string, error) {
	bin, err := b.resolveBin()
	if err != nil {
		return "", err
	}
	argv := append([]string{bin}, args...)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(out.String())
		if msg == "" {
			msg = err.Error()
		}
		return out.String(), &Error{
			Kind:    ErrCommandFailed,
			Message: fmt.Sprintf("tailcat %v failed", strings.Join(args, " ")),
			Detail:  Redact(msg),
		}
	}
	return out.String(), nil
}

// Available implements Backend.
func (b *CLIBackend) Available(ctx context.Context) (VersionInfo, error) {
	bin, err := b.resolveBin()
	if err != nil {
		return VersionInfo{Available: false, Err: err.Error()}, nil
	}
	cmd := exec.CommandContext(ctx, bin, "version")
	out, err := cmd.Output()
	if err != nil {
		return VersionInfo{Available: false, Path: bin, Err: "could not run `tailcat version`"}, nil
	}
	v := strings.TrimSpace(string(out))
	return VersionInfo{Available: true, Version: v, MinOK: versionOK(v), Path: bin}, nil
}

// ValidateToken implements Backend. It decodes tokens locally via
// `tailcat parse` (no network); DNS names are shape-checked only (resolution
// happens on explicit user action elsewhere).
func (b *CLIBackend) ValidateToken(ctx context.Context, input string) (TokenInfo, error) {
	s := strings.TrimSpace(input)
	if s == "" {
		return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: "empty input"}
	}
	if strings.Contains(s, ".") {
		if !validate.DNSNameOK(s) {
			return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: fmt.Sprintf("%q is not a valid DNS name", s)}
		}
		return TokenInfo{Valid: true, IsDNSName: true}, nil
	}
	if !strings.HasPrefix(s, "tc") {
		return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: "a connection target must be a tc... token or a DNS name"}
	}
	if !validate.TokenShapeOK(s) {
		return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: "token has an invalid character or is too short"}
	}
	// Confirm by decoding locally (no network).
	out, err := b.run(ctx, "parse", s)
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			e.Kind = ErrInvalidToken
			e.Message = "tailcat rejected this token as malformed"
			return TokenInfo{}, e
		}
		return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: "could not validate token", Detail: err.Error()}
	}
	ti, err := parseTokenJSON(out)
	if err != nil {
		return TokenInfo{}, &Error{Kind: ErrInvalidToken, Message: "tailcat parse produced unexpected output", Detail: Redact(err.Error())}
	}
	ti.Valid = true
	return ti, nil
}

// parseTokenJSON parses `tailcat parse` output (the raw wire form JSON).
func parseTokenJSON(out string) (TokenInfo, error) {
	var raw struct {
		ServerPublic string `json:"ServerPublic"`
		RegionID     int    `json:"RegionID"`
		Region       []struct {
			RegionID   int    `json:"RegionID"`
			RegionCode string `json:"RegionCode"`
			RegionName string `json:"RegionName"`
		} `json:"Region"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return TokenInfo{}, err
	}
	ti := TokenInfo{ServerPub: raw.ServerPublic, Embedded: len(raw.Region) > 0}
	if len(raw.Region) > 0 {
		ti.RegionID = raw.Region[0].RegionID
		ti.RegionCode = raw.Region[0].RegionCode
		ti.RegionName = raw.Region[0].RegionName
	} else {
		ti.RegionID = raw.RegionID
	}
	return ti, nil
}

// ListIdentities implements Backend. It lists saved keys via `tailcat
// genkey --list`. Kind is best-effort "server"; the app layer may overlay
// manager-known client identity hints. The virtual ephemeral identity is
// always included.
func (b *CLIBackend) ListIdentities(ctx context.Context) ([]Identity, error) {
	out, err := b.run(ctx, "genkey", "--list")
	if err != nil {
		return nil, err
	}
	ids := []Identity{{Name: "new", Kind: IdentityServer, Persistent: false, IsDefault: false}}
	for _, name := range strings.Fields(out) {
		ids = append(ids, Identity{Name: name, Kind: IdentityServer, Persistent: true, IsDefault: name == "default"})
	}
	return ids, nil
}

// identityNameRX restricts key names to safe characters; paths are rejected.
var identityNameRX = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// validateIdentityName rejects path injection and reserved names.
func validateIdentityName(name string) error {
	if name == "" {
		return &Error{Kind: ErrInvalidInput, Message: "identity name is required"}
	}
	if name == "new" {
		return &Error{Kind: ErrInvalidInput, Message: `"new" is reserved for ephemeral identities`}
	}
	if !identityNameRX.MatchString(name) {
		return &Error{Kind: ErrInvalidInput, Message: "identity name may only contain letters, digits, '.', '_', '-' (no paths)"}
	}
	return nil
}

// CreateIdentity implements Backend.
func (b *CLIBackend) CreateIdentity(ctx context.Context, name string, kind IdentityKind, region string) (Identity, error) {
	if err := validateIdentityName(name); err != nil {
		return Identity{}, err
	}
	args := []string{"genkey", "--key=" + name}
	if kind == IdentityClient {
		args = append(args, "--client")
	}
	if kind != IdentityClient && region != "" && region != "auto" {
		if region == "list" {
			return Identity{}, &Error{Kind: ErrInvalidInput, Message: "--region=list lists regions and does not create a key"}
		}
		args = append(args, "--region="+region)
	}
	out, err := b.run(ctx, args...)
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			if strings.Contains(e.Detail, "already exists") {
				return Identity{}, &Error{Kind: ErrKeyExists, Message: fmt.Sprintf("identity %q already exists", name)}
			}
		}
		return Identity{}, err
	}
	id := Identity{Name: name, Kind: kind, Persistent: true, IsDefault: name == "default"}
	if kind == IdentityClient {
		id.PublicKey = extractNodeKey(out)
	}
	return id, nil
}

// extractNodeKey finds the nodekey:... public key anywhere in combined
// stdout+stderr (stderr may carry a "# wrote file ..." note first).
func extractNodeKey(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "nodekey:") {
			return line
		}
	}
	return ""
}

// DeleteIdentity implements Backend.
func (b *CLIBackend) DeleteIdentity(ctx context.Context, name string) error {
	if err := validateIdentityName(name); err != nil {
		return err
	}
	_, err := b.run(ctx, "genkey", "--delete", "--key="+name)
	if err != nil {
		var e *Error
		if errors.As(err, &e) && strings.Contains(e.Detail, "no such file") {
			return &Error{Kind: ErrKeyNotFound, Message: fmt.Sprintf("identity %q does not exist", name)}
		}
		return err
	}
	return nil
}

// CurrentClientPublicKey implements Backend.
func (b *CLIBackend) CurrentClientPublicKey(ctx context.Context) (string, error) {
	out, err := b.run(ctx, "printpub")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(firstLine(out)), nil
}

// StartListener implements Backend.
func (b *CLIBackend) StartListener(ctx context.Context, spec ListenerSpec) (ListenerStatus, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln != nil && b.ln.aliveLocked() {
		return b.ln.StatusLocked(), &Error{Kind: ErrListenerRunning, Message: "listener is already running; stop it first"}
	}
	if st, err := b.loadListenerState(); err == nil && st != nil && pidAlive(st.PID) {
		return b.listenerFromState(st).StatusLocked(), &Error{Kind: ErrListenerRunning, Message: "listener is already running; stop it first"}
	}
	ln, err := newListener(b, spec)
	if err != nil {
		return ListenerStatus{}, err
	}
	b.ln = ln
	b.lastSpec = spec
	b.hasSpec = true
	return ln.Status(), nil
}

// StopListener implements Backend.
func (b *CLIBackend) StopListener(ctx context.Context) (ListenerStatus, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln != nil {
		st := b.ln.Stop()
		b.ln = nil
		return st, nil
	}
	st, err := b.loadListenerState()
	if err != nil || st == nil {
		return ListenerStatus{}, nil
	}
	ln := b.listenerFromState(st)
	return ln.Stop(), nil
}

// RestartListener implements Backend.
func (b *CLIBackend) RestartListener(ctx context.Context, spec ListenerSpec) (ListenerStatus, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln != nil {
		b.ln.Stop()
		b.ln = nil
	}
	ln, err := newListener(b, spec)
	if err != nil {
		return ListenerStatus{}, err
	}
	b.ln = ln
	b.lastSpec = spec
	b.hasSpec = true
	return ln.Status(), nil
}

// ListenerStatus implements Backend.
func (b *CLIBackend) ListenerStatus(ctx context.Context) (ListenerStatus, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln != nil {
		return b.ln.StatusLocked(), nil
	}
	st, err := b.loadListenerState()
	if err != nil || st == nil {
		return ListenerStatus{}, nil
	}
	ln := b.listenerFromState(st)
	return ln.StatusLocked(), nil
}

// CurrentListener implements CurrentListenerProvider.
func (b *CLIBackend) CurrentListener() (ListenerStatus, ListenerSpec, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln != nil {
		return b.ln.StatusLocked(), b.lastSpec, b.hasSpec
	}
	st, err := b.loadListenerState()
	if err != nil || st == nil {
		return ListenerStatus{}, ListenerSpec{}, false
	}
	return b.listenerFromState(st).StatusLocked(), st.Spec, true
}

// pongRX matches `pong in <dur> via <path>` lines.
var pongRX = regexp.MustCompile(`^pong in (\S+) via (.+)$`)

// Ping implements Backend.
func (b *CLIBackend) Ping(ctx context.Context, target string, untilDirect bool, timeout time.Duration) (PingResult, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return PingResult{}, &Error{Kind: ErrInvalidInput, Message: "a connection target is required"}
	}
	args := []string{"ping"}
	if untilDirect {
		args = append(args, "--until-direct")
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	args = append(args, "--timeout="+timeout.String(), target)

	out, err := b.run(ctx, args...)
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var last string
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "pong in ") {
			last = strings.TrimSpace(lines[i])
			break
		}
	}
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			if untilDirect && strings.Contains(e.Detail, "no direct path") {
				return PingResult{Ok: false}, &Error{Kind: ErrNoDirectPath, Message: fmt.Sprintf("no direct path to %s within %s", Redact(target), timeout)}
			}
			if strings.Contains(e.Detail, "context deadline exceeded") || strings.Contains(e.Detail, "timed out") {
				return PingResult{Ok: false}, &Error{Kind: ErrConnectTimeout, Message: fmt.Sprintf("could not reach %s before the timeout", Redact(target))}
			}
			e.Kind = ErrPingFailed
			e.Message = fmt.Sprintf("ping to %s failed", Redact(target))
			return PingResult{Ok: false}, e
		}
		return PingResult{Ok: false}, &Error{Kind: ErrPingFailed, Message: fmt.Sprintf("ping to %s failed", Redact(target)), Detail: err.Error()}
	}
	pr, perr := parsePong(last)
	if perr != nil {
		return PingResult{Ok: false}, &Error{Kind: ErrPingFailed, Message: "could not parse ping result", Detail: Redact(last)}
	}
	pr.Ok = true
	return pr, nil
}

func parsePong(line string) (PingResult, error) {
	m := pongRX.FindStringSubmatch(line)
	if m == nil {
		return PingResult{}, fmt.Errorf("unexpected ping output")
	}
	pr := PingResult{}
	if d, err := time.ParseDuration(m[1]); err == nil {
		pr.Latency = d
	}
	via := m[2]
	if strings.HasPrefix(via, "DERP(") {
		code := strings.TrimSuffix(strings.TrimPrefix(via, "DERP("), ")")
		pr.RegionCode = code
		pr.Direct = false
		if id, err := strconv.Atoi(code); err == nil {
			pr.RegionID = id
		}
	} else {
		pr.Endpoint = via
		pr.Direct = true
	}
	return pr, nil
}

// Diagnostics implements Backend.
func (b *CLIBackend) Diagnostics(ctx context.Context) (DiagReport, error) {
	rep := DiagReport{Backend: b.Name()}
	v, _ := b.Available(ctx)
	rep.Version = v
	if st, _, ok := b.CurrentListener(); ok {
		rep.Listener = st
		rep.LogTail = b.logTail()
	}
	return rep, nil
}

func (b *CLIBackend) logTail() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln == nil {
		return nil
	}
	return b.ln.logTail()
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
