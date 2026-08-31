package tailcat

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"omarchy-tailcat/validate"
)

func newListenerBackend(t *testing.T) *CLIBackend {
	t.Helper()
	t.Setenv("OMARCHY_TAILCAT_CONFIG_DIR", t.TempDir())
	t.Setenv("FAKE_KEYS_DIR", t.TempDir())
	return &CLIBackend{Bin: fakeTailcatPath(t)}
}

func TestListenerStartStatusStop(t *testing.T) {
	b := newListenerBackend(t)
	ctx := context.Background()

	st, err := b.StartListener(ctx, ListenerSpec{})
	if err != nil {
		t.Fatalf("StartListener: %v", err)
	}
	if !st.Running || st.Addr == "" || st.KeyInUse != "ephemeral" {
		t.Fatalf("status: %+v", st)
	}
	if st.Region != "San Francisco" || st.RegionID != 302 {
		t.Fatalf("region: %+v", st)
	}
	if !st.Broad {
		t.Fatalf("empty spec should be broad: %+v", st)
	}
	if !validate.TokenShapeOK(st.Addr) {
		t.Fatalf("addr not a token shape: %q", st.Addr)
	}

	// Starting again while running must fail.
	if _, err := b.StartListener(ctx, ListenerSpec{}); err == nil {
		t.Fatalf("second StartListener should fail")
	} else {
		var te *Error
		if !errors.As(err, &te) || te.Kind != ErrListenerRunning {
			t.Fatalf("second start kind: %v", err)
		}
	}

	// State file persisted.
	if _, err := os.Stat(b.statePath()); err != nil {
		t.Fatalf("state file missing: %v", err)
	}

	st = b.StopListenerAndCheck(t, ctx)
	if st.Running {
		t.Fatalf("after stop should not be running")
	}
	if _, err := os.Stat(b.statePath()); !os.IsNotExist(err) {
		t.Fatalf("state file should be removed")
	}

	// Status now returns not-running.
	cur, _ := b.ListenerStatus(ctx)
	if cur.Running {
		t.Fatalf("status after stop: %+v", cur)
	}
}

// StopListenerAndCheck stops and asserts the process is gone.
func (b *CLIBackend) StopListenerAndCheck(t *testing.T, ctx context.Context) ListenerStatus {
	t.Helper()
	st, err := b.StopListener(ctx)
	if err != nil {
		t.Fatalf("StopListener: %v", err)
	}
	return st
}

func TestListenerFreshBackendSeesRunning(t *testing.T) {
	b := newListenerBackend(t)
	ctx := context.Background()

	st, err := b.StartListener(ctx, ListenerSpec{})
	if err != nil {
		t.Fatal(err)
	}
	oldPID := st.PID

	// A brand-new backend (no in-process child) must still see it via state.
	b2 := &CLIBackend{Bin: b.Bin}
	got, err := b2.ListenerStatus(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Running || got.PID != oldPID || got.Addr == "" {
		t.Fatalf("fresh backend status: %+v", got)
	}

	// Stop from the fresh backend.
	st2, err := b2.StopListener(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st2.Running {
		t.Fatalf("fresh stop should stop it")
	}
	// Original backend now sees it stopped too.
	if cur, _ := b.ListenerStatus(ctx); cur.Running {
		t.Fatalf("original backend still running after fresh stop")
	}
}

func TestListenerRestart(t *testing.T) {
	b := newListenerBackend(t)
	ctx := context.Background()

	st, err := b.StartListener(ctx, ListenerSpec{})
	if err != nil {
		t.Fatal(err)
	}
	p1 := st.PID

	time.Sleep(200 * time.Millisecond)
	st2, err := b.RestartListener(ctx, ListenerSpec{
		Services: []Service{{Name: "Web", Kind: ServicePortForward, Port: 8080, Enabled: true}},
	})
	if err != nil {
		t.Fatalf("restart: %v", err)
	}
	if !st2.Running || st2.Broad {
		t.Fatalf("restarted status: %+v", st2)
	}
	if st2.PID == p1 {
		t.Fatalf("restart should use a new pid")
	}
	if len(st2.Services) != 1 || st2.Services[0].Port != 8080 {
		t.Fatalf("restart services: %+v", st2.Services)
	}
	b.StopListenerAndCheck(t, ctx)
}

func TestListenerSpecErrors(t *testing.T) {
	b := newListenerBackend(t)
	ctx := context.Background()

	// Port 0.
	if _, err := b.StartListener(ctx, ListenerSpec{Services: []Service{{Kind: ServicePortForward, Port: 0, Enabled: true}}}); err == nil {
		t.Fatalf("port 0 should fail")
	}
	// All disabled.
	if _, err := b.StartListener(ctx, ListenerSpec{Services: []Service{{Kind: ServicePortForward, Port: 80, Enabled: false}}}); err == nil {
		t.Fatalf("all-disabled should fail")
	}
	// Files without a dir.
	if _, err := b.StartListener(ctx, ListenerSpec{Services: []Service{{Kind: ServiceFiles, Enabled: true}}}); err == nil {
		t.Fatalf("files without dir should fail")
	}
	// Bad files mode.
	if _, err := b.StartListener(ctx, ListenerSpec{Services: []Service{{Kind: ServiceFiles, Enabled: true}}, FilesDir: "/tmp", FilesMode: "zz"}); err == nil {
		t.Fatalf("bad files mode should fail")
	}
}

func TestListenerInvalidBin(t *testing.T) {
	b := &CLIBackend{Bin: filepath.Join(t.TempDir(), "missing")}
	_, err := b.StartListener(context.Background(), ListenerSpec{})
	if err == nil {
		t.Fatalf("start with missing bin should fail")
	}
}
