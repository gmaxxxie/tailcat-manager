package process

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestStartScanAndStop(t *testing.T) {
	// A process that writes lines and stays alive until signalled.
	script := `#!/usr/bin/env bash
echo "line one"
echo "line two" >&2
while true; do sleep 5; done
`
	dir := t.TempDir()
	p := dir + "/loop.sh"
	if err := writeExec(p, script); err != nil {
		t.Fatal(err)
	}
	c, err := Start(context.Background(), []string{p}, nil, func(s string) string { return s })
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if c.Running() {
			c.Stop(3 * time.Second)
		}
	}()

	// Wait for the scan goroutines to pick up the lines.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(c.OutputLines()) >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	joined := c.JoinLines()
	if !strings.Contains(joined, "line one") || !strings.Contains(joined, "line two") {
		t.Fatalf("log lines: %q", joined)
	}
	if !c.Running() {
		t.Fatalf("expected running")
	}
	if err := c.Stop(3 * time.Second); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if c.Running() {
		t.Fatalf("expected stopped")
	}
}

func TestStartMissingBin(t *testing.T) {
	if _, err := Start(context.Background(), []string{"/nonexistent/xyz"}, nil, nil); err == nil {
		t.Fatalf("missing bin should fail")
	}
}

func TestRing(t *testing.T) {
	r := NewRing(3)
	for i := 0; i < 5; i++ {
		r.Add(string(rune('a' + i)))
	}
	lines := r.Lines()
	if len(lines) != 3 || lines[0] != "c" || lines[2] != "e" {
		t.Fatalf("ring: %v", lines)
	}
}

func writeExec(path, script string) error {
	return os.WriteFile(path, []byte(script), 0o755)
}
