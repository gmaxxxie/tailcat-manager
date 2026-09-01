package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeTailcatEnv returns an env slice whose PATH points at a temp dir
// containing a `tailcat` that is the fake script (testdata/fake-tailcat.sh).
func fakeTailcatEnv(t *testing.T) []string {
	t.Helper()
	dir := t.TempDir()
	abs, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fake-tailcat.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(abs, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(abs, filepath.Join(dir, "tailcat")); err != nil {
		t.Fatal(err)
	}
	// Later entries win for duplicate keys, so this overrides the inherited PATH.
	return append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func decodeJSON(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, out)
	}
	return m
}

func TestSocksStartStopStatus(t *testing.T) {
	env := append(fakeTailcatEnv(t), "OMARCHY_TAILCAT_CONFIG_DIR="+t.TempDir())

	out, err := runBackend(t, env, "socks", "start", "--port=0")
	if err != nil {
		t.Fatalf("start: %v\n%s", err, out)
	}
	st := decodeJSON(t, out)
	if st["running"] != true {
		t.Fatalf("start running: %s", out)
	}
	addr, _ := st["addr"].(string)
	if !strings.HasPrefix(addr, "socks5h://127.0.0.1:") {
		t.Fatalf("addr: %s", out)
	}

	out, err = runBackend(t, env, "socks", "status")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	st = decodeJSON(t, out)
	if st["running"] != true || st["addr"] == nil || st["addr"] == "" {
		t.Fatalf("status should report running + addr: %s", out)
	}

	// Starting again while running must fail.
	out, err = runBackend(t, env, "socks", "start")
	if err == nil {
		t.Fatalf("second start should fail, got %s", out)
	}

	out, err = runBackend(t, env, "socks", "stop")
	if err != nil {
		t.Fatalf("stop: %v\n%s", err, out)
	}
	out, err = runBackend(t, env, "socks", "status")
	if err != nil {
		t.Fatalf("status after stop: %v\n%s", err, out)
	}
	st = decodeJSON(t, out)
	addr, _ = st["addr"].(string)
	if st["running"] != false || addr != "" {
		t.Fatalf("status after stop should be stopped: %s", out)
	}
}

func TestSSHOpenLaunchesTerminal(t *testing.T) {
	env := append(fakeTailcatEnv(t), "OMARCHY_TAILCAT_CONFIG_DIR="+t.TempDir())

	termDir := t.TempDir()
	log := filepath.Join(termDir, "term.log")
	term := filepath.Join(termDir, "fake-term")
	script := "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > '" + log + "'\nexit 0\n"
	if err := os.WriteFile(term, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	env = append(env, "OMARCHY_TAILCAT_TERMINAL="+term)

	tok := "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	out, err := runBackend(t, env, "ssh", "open", tok, "--port=2222", "--user=root", "--cmd=uptime -p")
	if err != nil {
		t.Fatalf("open: %v\n%s", err, out)
	}
	res := decodeJSON(t, out)
	if res["ok"] != true {
		t.Fatalf("open not ok: %s", out)
	}

	// The fake terminal records its argv; poll briefly (the launch is detached).
	var got string
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		b, rerr := os.ReadFile(log)
		if rerr == nil && len(b) > 0 {
			got = string(b)
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	want := []string{"ssh", "-p", "2222", "root@" + tok, "uptime", "-p"}
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Fatalf("terminal argv %q missing %q", got, w)
		}
	}
}

func TestSSHOpenRejectsBadTarget(t *testing.T) {
	env := append(fakeTailcatEnv(t), "OMARCHY_TAILCAT_CONFIG_DIR="+t.TempDir())
	out, err := runBackend(t, env, "ssh", "open", "not a target")
	if err == nil {
		t.Fatalf("bad target should fail: %s", out)
	}
	var e map[string]any
	if err := json.Unmarshal([]byte(out), &e); err != nil || e["error"] == nil {
		t.Fatalf("expected error object: %s", out)
	}
}

func TestSSHStatusReportsTerminal(t *testing.T) {
	env := append(fakeTailcatEnv(t), "OMARCHY_TAILCAT_CONFIG_DIR="+t.TempDir())
	env = append(env, "OMARCHY_TAILCAT_TERMINAL=/nonexistent/fake-term")
	out, err := runBackend(t, env, "ssh", "status")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	st := decodeJSON(t, out)
	if st["tailcatOK"] != true {
		t.Fatalf("tailcatOK should be true with fake on PATH: %s", out)
	}
	if st["terminalOK"] != false {
		t.Fatalf("terminalOK should be false for bogus terminal: %s", out)
	}
}
