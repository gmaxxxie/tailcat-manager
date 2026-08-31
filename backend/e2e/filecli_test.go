// CLI-level tests for the V0.2 `omarchy-tailcat file` subcommands, run
// against a hermetic localhost DERP map (no internet).
package e2e

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func buildManagerBin(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "omarchy-tailcat")
	out, err := exec.Command("go", "build", "-o", bin, "omarchy-tailcat/cmd/omarchy-tailcat").CombinedOutput()
	if err != nil {
		t.Fatalf("build omarchy-tailcat: %v\n%s", err, out)
	}
	return bin
}

func runBin(t *testing.T, env []string, bin string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), env...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return stdout.String(), err
	}
	return stdout.String(), nil
}

func managerEnv(t *testing.T) (string, []string) {
	dir := t.TempDir()
	return dir, []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + dir}
}

func TestFileCLIEndToEnd(t *testing.T) {
	bin := buildManagerBin(t)
	mapURL := startLocalDERPMap(t)
	_, env := managerEnv(t)
	dir := t.TempDir()

	// Start the receiver daemon.
	out, err := runBin(t, env, bin, "file", "recv-start", "--dir="+dir, "--derpmap-url="+mapURL)
	if err != nil {
		t.Fatalf("recv-start: %v\n%s", err, out)
	}
	var start struct{ Addr string }
	if err := json.Unmarshal([]byte(out), &start); err != nil || start.Addr == "" {
		t.Fatalf("recv-start output: %q", out)
	}
	t.Cleanup(func() { runBin(t, env, bin, "file", "recv-stop") })

	// Build a source file.
	src := filepath.Join(t.TempDir(), "cli.pdf")
	payload := []byte("cli native transfer " + strings.Repeat("z", 150000))
	if err := os.WriteFile(src, payload, 0600); err != nil {
		t.Fatal(err)
	}

	// Send in the background; it will wait for the accept decision.
	sendDone := make(chan struct {
		out string
		err error
	}, 1)
	go func() {
		out, err := runBin(t, env, bin, "file", "send", start.Addr, src, "--name=cli.pdf", "--derpmap-url="+mapURL)
		sendDone <- struct {
			out string
			err error
		}{out, err}
	}()

	// Wait for the offer to appear, then accept.
	acceptDest := filepath.Join(dir, "accepted.pdf")
	waitForPending(t, env, bin)
	if out, err := runBin(t, env, bin, "file", "recv-respond", pendingID(t, env, bin), "accept", acceptDest); err != nil {
		t.Fatalf("recv-respond accept: %v\n%s", err, out)
	}

	select {
	case res := <-sendDone:
		if res.err != nil {
			t.Fatalf("send: %v\n%s", res.err, res.out)
		}
		if !strings.Contains(res.out, `"type":"done"`) || !strings.Contains(res.out, `"ok":true`) {
			t.Fatalf("send output: %q", res.out)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("send did not finish")
	}

	got, err := os.ReadFile(acceptDest)
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("accepted file mismatch: %v", err)
	}

	// Status should report the done entry.
	statusOut, _ := runBin(t, env, bin, "file", "recv-status")
	if !strings.Contains(statusOut, "accepted.pdf") {
		t.Fatalf("recv-status missing done entry: %s", statusOut)
	}
}

func TestFileCLIReject(t *testing.T) {
	bin := buildManagerBin(t)
	mapURL := startLocalDERPMap(t)
	_, env := managerEnv(t)
	dir := t.TempDir()

	out, err := runBin(t, env, bin, "file", "recv-start", "--dir="+dir, "--derpmap-url="+mapURL)
	if err != nil {
		t.Fatalf("recv-start: %v\n%s", err, out)
	}
	t.Cleanup(func() { runBin(t, env, bin, "file", "recv-stop") })
	var start struct{ Addr string }
	_ = json.Unmarshal([]byte(out), &start)

	src := filepath.Join(t.TempDir(), "r.pdf")
	_ = os.WriteFile(src, []byte("reject me"), 0600)

	sendDone := make(chan struct {
		out string
		err error
	}, 1)
	go func() {
		out, err := runBin(t, env, bin, "file", "send", start.Addr, src, "--derpmap-url="+mapURL)
		sendDone <- struct {
			out string
			err error
		}{out, err}
	}()

	waitForPending(t, env, bin)
	if out, err := runBin(t, env, bin, "file", "recv-respond", pendingID(t, env, bin), "reject"); err != nil {
		t.Fatalf("recv-respond reject: %v\n%s", err, out)
	}
	select {
	case res := <-sendDone:
		if res.err == nil || !strings.Contains(res.out, "rejected") {
			t.Fatalf("expected rejection in send output: %v\n%s", res.err, res.out)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("send did not finish after reject")
	}
	if _, err := os.Stat(filepath.Join(dir, "r.pdf")); !os.IsNotExist(err) {
		t.Fatalf("rejected file was written")
	}
}

// waitForPending polls recv-status until a pending offer appears.
func waitForPending(t *testing.T, env []string, bin string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		out, err := runBin(t, env, bin, "file", "recv-status")
		if err == nil {
			var st struct {
				Pending []struct {
					ID string `json:"id"`
				} `json:"pending"`
			}
			if json.Unmarshal([]byte(out), &st) == nil && len(st.Pending) > 0 {
				return
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("no pending offer appeared")
}

func pendingID(t *testing.T, env []string, bin string) string {
	t.Helper()
	out, err := runBin(t, env, bin, "file", "recv-status")
	if err != nil {
		t.Fatalf("recv-status: %v", err)
	}
	var st struct {
		Pending []struct {
			ID string `json:"id"`
		} `json:"pending"`
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil || len(st.Pending) == 0 {
		t.Fatalf("no pending in status: %s", out)
	}
	return st.Pending[0].ID
}
