// Package process provides a small supervised-child helper: start a command
// with a bounded, redacted log ring and clean stop (SIGTERM then SIGKILL).
// Used by the CLI backend to manage the long-running `tailcat serve` process.
package process

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Ring is a small bounded ring buffer of log lines.
type Ring struct {
	mu    sync.Mutex
	lines []string
	max   int
}

// NewRing returns a ring holding at most max lines.
func NewRing(max int) *Ring {
	if max <= 0 {
		max = 200
	}
	return &Ring{max: max}
}

// Add appends a line, evicting the oldest when full.
func (r *Ring) Add(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, line)
	if len(r.lines) > r.max {
		r.lines = r.lines[len(r.lines)-r.max:]
	}
}

// Lines returns a copy of the current lines.
func (r *Ring) Lines() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.lines))
	copy(out, r.lines)
	return out
}

// Child is a running supervised command.
type Child struct {
	Cmd    *exec.Cmd
	Log    *Ring
	redact func(string) string

	done    chan struct{} // closed when the process exits
	err     error         // wait error
	errOnce sync.Once

	stopMu sync.Mutex
}

// ErrUnexpectedExit is returned by Wait when the process exited on its own
// (not via Stop).
var ErrUnexpectedExit = errors.New("process exited unexpectedly")

// Start launches argv with env. Each stdout/stderr line is passed to line
// (after redact) and stored in the ring. It returns once the process is
// running. It does not wait for the child to produce output.
//
// The child is NOT bound to ctx (a long-running server must not be killed by
// a caller's context); termination is managed via Stop.
func Start(_ context.Context, argv []string, env []string, redact func(string) string) (*Child, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdin = nil // servers don't need stdin
	// Own process group so Stop can signal the whole group (children too)
	// and so the child is detached from our lifetime (it survives if the
	// manager backend process exits).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c := &Child{
		Cmd:    cmd,
		Log:    NewRing(200),
		redact: redact,
		done:   make(chan struct{}),
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %v: %w", argv[0], err)
	}
	go c.scan(stdout)
	go c.scan(stderr)
	go func() {
		c.errOnce.Do(func() {
			c.err = cmd.Wait()
			close(c.done)
		})
	}()
	return c, nil
}

func (c *Child) scan(r interface{ Read([]byte) (int, error) }) {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 0, 64*1024), 512*1024)
	for s.Scan() {
		line := s.Text()
		if c.redact != nil {
			line = c.redact(line)
		}
		c.Log.Add(line)
	}
}

// Done is closed when the process exits.
func (c *Child) Done() <-chan struct{} { return c.done }

// Running reports whether the process is still alive.
func (c *Child) Running() bool {
	select {
	case <-c.done:
		return false
	default:
		return c.ProcessAlive()
	}
}

// ProcessAlive checks liveness without blocking.
func (c *Child) ProcessAlive() bool {
	return c.Cmd.ProcessState == nil || !c.Cmd.ProcessState.Exited()
}

// Wait returns the process exit error, or nil if it exited 0. If the process
// is still running it blocks until exit.
func (c *Child) Wait() error {
	<-c.done
	return c.err
}

// Stop terminates the process: SIGTERM, then SIGKILL after timeout. It waits
// for the process to exit. A nil error means the process is gone.
func (c *Child) Stop(timeout time.Duration) error {
	c.stopMu.Lock()
	defer c.stopMu.Unlock()
	select {
	case <-c.done:
		return nil // already exited
	default:
	}
	if c.Cmd.Process != nil {
		// Signal the process group so any tailcat-spawned children die too.
		sigErr := syscall.Kill(-c.Cmd.Process.Pid, syscall.SIGTERM)
		if sigErr != nil {
			_ = c.Cmd.Process.Signal(syscall.SIGTERM)
		}
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-c.done:
		return nil
	case <-timer.C:
		if c.Cmd.Process != nil {
			_ = syscall.Kill(-c.Cmd.Process.Pid, syscall.SIGKILL)
			_ = c.Cmd.Process.Kill()
		}
		select {
		case <-c.done:
			return nil
		case <-time.After(2 * time.Second):
			return errors.New("process did not exit after SIGKILL")
		}
	}
}

// OutputLines returns the current (redacted) log lines.
func (c *Child) OutputLines() []string { return c.Log.Lines() }

// JoinLines joins the log lines into one string (redacted already).
func (c *Child) JoinLines() string {
	var b bytes.Buffer
	for _, l := range c.Log.Lines() {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return b.String()
}
