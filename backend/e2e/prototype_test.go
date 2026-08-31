// Package e2e contains hermetic end-to-end tests that exercise the backend
// against a REAL tailcat binary with a localhost DERP server
// (TS_DEBUG_TAILCAT_LOCAL_DERP=1), so no internet is required. The tailcat
// binary must be available (TAILCAT_BIN env var or on PATH); otherwise these
// tests skip.
package e2e

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"omarchy-tailcat/tailcat"
	"omarchy-tailcat/validate"
)

// findTailcat returns the real tailcat binary path, or "" to skip.
func findTailcat(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("TAILCAT_BIN"); p != "" {
		return p
	}
	if p, err := exec.LookPath("tailcat"); err == nil {
		return p
	}
	t.Skip("tailcat binary not available (set TAILCAT_BIN or add to PATH); skipping hermetic e2e")
	return ""
}

// newHermeticBackend returns a CLI backend pointed at the real binary,
// configured for a fully-offline localhost DERP run, with config isolated in a
// temp dir.
func newHermeticBackend(t *testing.T) *tailcat.CLIBackend {
	t.Helper()
	dir := t.TempDir()
	// Isolate the manager config AND tailcat's own config/cache/keys/ssh
	// (os.UserConfigDir/os.UserCacheDir) so tests never touch the real
	// ~/.config/tailcat or ~/.cache/tailcat.
	t.Setenv("OMARCHY_TAILCAT_CONFIG_DIR", filepath.Join(dir, "manager"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "config"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(dir, "cache"))
	t.Setenv("HOME", filepath.Join(dir, "home"))
	return &tailcat.CLIBackend{
		Bin:        findTailcat(t),
		DerpMapURL: "none",
		ExtraEnv:   []string{"TS_DEBUG_TAILCAT_LOCAL_DERP=1"},
	}
}

// startEcho starts a TCP echo server on localhost, returning its port.
func startEcho(t *testing.T) uint16 {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return uint16(ln.Addr().(*net.TCPAddr).Port)
}

func TestHermeticStartPingRoundTrip(t *testing.T) {
	b := newHermeticBackend(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start a listener forwarding the echo port through the tunnel.
	echoPort := startEcho(t)
	st, err := b.StartListener(ctx, tailcat.ListenerSpec{
		Services: []tailcat.Service{{Name: "Echo", Kind: tailcat.ServicePortForward, Port: echoPort, Enabled: true}},
	})
	if err != nil {
		t.Fatalf("StartListener: %v", err)
	}
	defer b.StopListener(ctx)

	if !st.Running || st.Addr == "" {
		t.Fatalf("listener status: %+v", st)
	}
	t.Logf("listener addr: %s (key=%s, region=%s)", redactAddr(st.Addr), st.KeyInUse, st.Region)

	// The token validates locally.
	ti, err := b.ValidateToken(ctx, st.Addr)
	if err != nil {
		t.Fatalf("ValidateToken: %v", err)
	}
	if !ti.Valid {
		t.Fatalf("token not valid: %+v", ti)
	}

	// Ping reaches the server.
	pr, err := b.Ping(ctx, st.Addr, false, 15*time.Second)
	if err != nil {
		t.Fatalf("Ping: %v", err)
	}
	if !pr.Ok || pr.Latency <= 0 {
		t.Fatalf("ping result: %+v", pr)
	}
	t.Logf("ping: direct=%v endpoint=%q region=%s latency=%s", pr.Direct, pr.Endpoint, pr.RegionCode, pr.Latency)

	// --until-direct should find the localhost direct path.
	prd, err := b.Ping(ctx, st.Addr, true, 20*time.Second)
	if err != nil {
		t.Fatalf("Ping until-direct: %v", err)
	}
	if !prd.Direct {
		t.Fatalf("expected a direct path on localhost, got %+v", prd)
	}

	// Real data round trip through the tunnel: the client CLI sends a payload
	// to the served port and must get the echo back. The blob embeds the
	// localhost DERP, so the client needs no map fetch.
	payload := "hermetic echo payload"
	cmd := exec.Command(b.Bin, "--key=new", "--derpmap-url=none", st.Addr, fmt.Sprint(echoPort))
	cmd.Stdin = strings.NewReader(payload)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		t.Fatalf("client round-trip failed: %v\n%s", err, redactAddr(out.String()))
	}
	if strings.TrimSpace(out.String()) != payload {
		t.Fatalf("echo mismatch: got %q want %q", out.String(), payload)
	}

	// Fresh backend (no in-process child) still sees the listener.
	b2 := &tailcat.CLIBackend{Bin: b.Bin}
	st2, err := b2.ListenerStatus(ctx)
	if err != nil || !st2.Running {
		t.Fatalf("fresh backend status: %+v err=%v", st2, err)
	}

	// Stop from the fresh backend.
	st3, err := b2.StopListener(ctx)
	if err != nil {
		t.Fatalf("stop from fresh backend: %v", err)
	}
	if st3.Running {
		t.Fatalf("expected stopped")
	}
}

func TestHermeticIdentitiesAndServices(t *testing.T) {
	b := newHermeticBackend(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	name := "hermetic-" + fmt.Sprint(time.Now().UnixNano()%100000)
	id, err := b.CreateIdentity(ctx, name, tailcat.IdentityServer, "")
	if err != nil {
		t.Fatalf("CreateIdentity: %v", err)
	}
	t.Cleanup(func() { _ = b.DeleteIdentity(ctx, name) })
	if !id.Persistent || id.IsDefault {
		t.Fatalf("identity: %+v", id)
	}

	ids, err := b.ListIdentities(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, i := range ids {
		if i.Name == name {
			found = true
		}
	}
	if !found {
		t.Fatalf("created identity not listed: %+v", ids)
	}

	// Start a listener with the saved key: the address must be stable and the
	// key name reported.
	st, err := b.StartListener(ctx, tailcat.ListenerSpec{Key: name})
	if err != nil {
		t.Fatalf("StartListener with saved key: %v", err)
	}
	defer b.StopListener(ctx)
	if st.KeyInUse != name {
		t.Fatalf("key in use: %q want %q", st.KeyInUse, name)
	}
	if !validate.TokenShapeOK(st.Addr) {
		t.Fatalf("addr not token: %q", st.Addr)
	}

	// Client identity public key is obtainable (for --allow lists).
	pub, err := b.CurrentClientPublicKey(ctx)
	if err != nil {
		t.Fatalf("printpub: %v", err)
	}
	if !strings.HasPrefix(pub, "nodekey:") {
		t.Fatalf("public key: %q", pub)
	}

	// Diagnostics report works and is redacted.
	rep, err := b.Diagnostics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !rep.Listener.Running {
		t.Fatalf("diag listener not running")
	}
	for _, l := range rep.LogTail {
		if strings.Contains(l, strings.TrimPrefix(st.Addr, "tc")[:8]) {
			t.Fatalf("diagnostic log leaked a token fragment: %q", l)
		}
	}
}

func redactAddr(s string) string {
	if len(s) > 12 && strings.HasPrefix(s, "tc") {
		return "tc…" + s[len(s)-4:]
	}
	return s
}
