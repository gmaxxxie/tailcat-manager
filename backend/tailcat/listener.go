package tailcat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"omarchy-tailcat/atomicfile"
	"omarchy-tailcat/config"
	"omarchy-tailcat/process"
)

// listenerState is persisted to the config dir so the listener (a detached
// `tailcat serve` process) survives the manager backend process exiting and
// can be stopped/queried from any later invocation.
type listenerState struct {
	PID       int          `json:"pid"`
	Addr      string       `json:"addr"`
	AddrFile  string       `json:"addrFile"`
	KeyInUse  string       `json:"keyInUse"`
	Region    string       `json:"region"`
	RegionID  int          `json:"regionID"`
	Services  []Service    `json:"services"`
	Broad     bool         `json:"broad"`
	StartedAt time.Time    `json:"startedAt"`
	Spec      ListenerSpec `json:"spec"`
}

// Listener manages one detached `tailcat serve` process.
type Listener struct {
	b     *CLIBackend
	mu    sync.Mutex
	child *process.Child // in-process handle; nil after backend process restarts
	state listenerState
}

// startWait is how long to wait for the server to publish its address.
const startWait = 30 * time.Second

// Startup-line regexes (parsed from the redacted stderr ring; they never touch
// the token itself, which the ring redacts).
var (
	regionLineRX   = regexp.MustCompile(`Selected bootstrap relay region (\d+), (.+)`)
	keyNewLineRX   = regexp.MustCompile(`Server listening with new address`)
	keySavedLineRX = regexp.MustCompile(`Server listening with saved key "([^"]+)"`)
)

// statePath is where the listener state lives.
func (b *CLIBackend) statePath() string { return filepath.Join(config.Dir(), "listener.json") }

// addrPath is where tailcat writes the current address blob.
func (b *CLIBackend) addrPath() string { return filepath.Join(config.Dir(), "addr") }

// newListener validates the spec, starts the detached server, waits for its
// address, and persists state. The returned Listener tracks the running child.
func newListener(b *CLIBackend, spec ListenerSpec) (*Listener, error) {
	argv, broad, err := b.serveArgv(spec)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(config.Dir(), 0700); err != nil {
		return nil, &Error{Kind: ErrListenerFailed, Message: "could not create config directory", Detail: err.Error()}
	}
	addrFile := b.addrPath()
	_ = atomicfile.Remove(addrFile) // fresh start

	env := append([]string{}, os.Environ()...)
	env = append(env, b.ExtraEnv...)
	env = append(env, "TAILCAT_ADDR_FILE="+addrFile)

	ctx, cancel := context.WithTimeout(context.Background(), startWait)
	defer cancel()
	child, err := process.Start(ctx, argv, env, Redact)
	if err != nil {
		return nil, &Error{Kind: ErrListenerFailed, Message: "could not start the tailcat server", Detail: Redact(err.Error())}
	}

	ln := &Listener{b: b, child: child}
	ln.state.Spec = spec
	ln.state.Services = enabledServices(spec.Services)
	ln.state.Broad = broad
	ln.state.AddrFile = addrFile
	ln.state.PID = child.Cmd.Process.Pid
	ln.state.StartedAt = time.Now().UTC()

	addr, err := ln.waitForAddr(addrFile, child)
	if err != nil {
		child.Stop(3 * time.Second)
		return nil, err
	}
	ln.state.Addr = addr
	ln.state.KeyInUse, ln.state.Region, ln.state.RegionID = ln.parseStartup(child)

	if err := ln.saveState(); err != nil {
		child.Stop(3 * time.Second)
		return nil, &Error{Kind: ErrListenerFailed, Message: "could not persist listener state", Detail: err.Error()}
	}
	return ln, nil
}

// serveArgv builds the structured argv for the server (never a shell).
// The second return value reports whether the listener is "broad" (serving all
// localhost ports, because no explicit services were configured).
func (b *CLIBackend) serveArgv(spec ListenerSpec) ([]string, bool, error) {
	bin, err := b.resolveBin()
	if err != nil {
		return nil, false, err
	}
	args := []string{bin}
	if b.DerpMapURL != "" {
		args = append(args, "--derpmap-url="+b.DerpMapURL)
	}
	switch spec.Key {
	case "":
		// auto: use saved "default" if present, else ephemeral
	case "new":
		args = append(args, "--key=new")
	default:
		args = append(args, "--key="+spec.Key)
	}
	args = append(args, "--json", "serve")
	if spec.FullAddr {
		args = append(args, "--full-address")
	}
	if spec.AllowNone {
		args = append(args, "--allow=none")
	} else if len(spec.Allow) > 0 {
		args = append(args, "--allow="+strings.Join(spec.Allow, ","))
	}
	for _, s := range spec.Services {
		if s.Kind == ServiceFiles {
			if spec.FilesDir == "" {
				return nil, false, &Error{Kind: ErrInvalidInput, Message: "the file share service requires a directory"}
			}
			arg := spec.FilesDir
			if spec.FilesMode != "" {
				switch spec.FilesMode {
				case "ro", "rw", "wo":
					arg += ":" + spec.FilesMode
				default:
					return nil, false, &Error{Kind: ErrInvalidInput, Message: "file share mode must be ro, rw, or wo"}
				}
			}
			args = append(args, "--files="+arg)
			break
		}
	}
	svcArgs, broad, err := buildServiceArgs(spec.Services)
	if err != nil {
		return nil, false, err
	}
	args = append(args, svcArgs...)
	return args, broad, nil
}

// buildServiceArgs maps the service list to `tailcat serve` arguments. A
// listener with no services configured at all becomes "serve all" (broad).
// Services configured but all disabled is an error (safer than broad).
func buildServiceArgs(services []Service) ([]string, bool, error) {
	if len(services) == 0 {
		return []string{"all"}, true, nil
	}
	var out []string
	seen := map[uint16]bool{}
	for _, s := range services {
		if !s.Enabled {
			continue
		}
		switch s.Kind {
		case ServicePortForward:
			if s.Port == 0 {
				return nil, false, &Error{Kind: ErrInvalidInput, Message: "a port-forward service needs a port"}
			}
			if seen[s.Port] {
				return nil, false, &Error{Kind: ErrInvalidInput, Message: fmt.Sprintf("port %d is listed more than once", s.Port)}
			}
			seen[s.Port] = true
			out = append(out, strconv.Itoa(int(s.Port)))
		case ServiceNoAuthSSH:
			out = append(out, "no-auth-ssh")
		case ServiceFiles:
			out = append(out, "files")
		case ServiceExitNode:
			out = append(out, "exit-node")
		default:
			return nil, false, &Error{Kind: ErrInvalidInput, Message: "unknown service kind"}
		}
	}
	if len(out) == 0 {
		return nil, false, &Error{Kind: ErrInvalidInput, Message: "at least one service must be enabled"}
	}
	return out, false, nil
}

func enabledServices(services []Service) []Service {
	var out []Service
	for _, s := range services {
		if s.Enabled {
			out = append(out, s)
		}
	}
	return out
}

// waitForAddr polls addrFile until the server writes its blob, or the child
// exits, or startWait elapses.
func (ln *Listener) waitForAddr(addrFile string, child *process.Child) (string, error) {
	deadline := time.Now().Add(startWait)
	for {
		if b, err := os.ReadFile(addrFile); err == nil && len(b) > 0 {
			return strings.TrimSpace(string(b)), nil
		}
		select {
		case <-child.Done():
			return "", &Error{Kind: ErrListenerFailed, Message: "the tailcat server exited before publishing its address", Detail: child.JoinLines()}
		default:
		}
		if time.Now().After(deadline) {
			child.Stop(3 * time.Second)
			return "", &Error{Kind: ErrListenerFailed, Message: "timed out waiting for the tailcat server to start", Detail: child.JoinLines()}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// parseStartup extracts the key-in-use and bootstrap region from the startup
// log lines (which are already token-redacted; we only read non-token fields).
func (ln *Listener) parseStartup(child *process.Child) (keyInUse, region string, regionID int) {
	keyInUse = "ephemeral"
	deadline := time.Now().Add(2 * time.Second)
	foundKey, foundRegion := false, false
	for time.Now().Before(deadline) {
		for _, line := range child.OutputLines() {
			if !foundKey {
				if m := keySavedLineRX.FindStringSubmatch(line); m != nil {
					keyInUse = m[1]
					foundKey = true
				} else if keyNewLineRX.MatchString(line) {
					foundKey = true
				}
			}
			if !foundRegion {
				if m := regionLineRX.FindStringSubmatch(line); m != nil {
					if id, err := strconv.Atoi(m[1]); err == nil {
						regionID = id
					}
					region = m[2]
					foundRegion = true
				}
			}
			if foundKey && foundRegion {
				return keyInUse, region, regionID
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return keyInUse, region, regionID
}

// saveState persists the listener state atomically (0600).
func (ln *Listener) saveState() error {
	data, err := json.MarshalIndent(&ln.state, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(ln.b.statePath(), data, 0600)
}

// Status returns a snapshot of the listener.
func (ln *Listener) Status() ListenerStatus {
	ln.mu.Lock()
	defer ln.mu.Unlock()
	return ln.StatusLocked()
}

// StatusLocked must be called with ln.mu held.
func (ln *Listener) StatusLocked() ListenerStatus {
	st := ln.state
	return ListenerStatus{
		Running:   ln.aliveLocked(),
		Addr:      st.Addr,
		KeyInUse:  st.KeyInUse,
		Region:    st.Region,
		RegionID:  st.RegionID,
		Services:  append([]Service(nil), st.Services...),
		StartedAt: st.StartedAt,
		PID:       st.PID,
		Broad:     st.Broad,
	}
}

func (ln *Listener) aliveLocked() bool {
	if ln.child != nil {
		return ln.child.Running()
	}
	if ln.state.PID == 0 {
		return false
	}
	return pidAlive(ln.state.PID)
}

// Stop terminates the listener and clears state.
func (ln *Listener) Stop() ListenerStatus {
	ln.mu.Lock()
	defer ln.mu.Unlock()
	st := ln.StatusLocked()
	if ln.child != nil {
		ln.child.Stop(5 * time.Second)
		ln.child = nil
	} else if ln.state.PID != 0 {
		stopPID(ln.state.PID, 5*time.Second)
	}
	_ = atomicfile.Remove(ln.state.AddrFile)
	_ = atomicfile.Remove(ln.b.statePath())
	ln.state = listenerState{}
	st.Running = false
	return st
}

// logTail returns the current redacted server log lines (empty if the child
// was started by a different process).
func (ln *Listener) logTail() []string {
	ln.mu.Lock()
	defer ln.mu.Unlock()
	if ln.child == nil {
		return nil
	}
	return ln.child.OutputLines()
}

// pidAlive reports whether pid exists (signal 0 probe).
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// stopPID sends SIGTERM to the process group (-pid), waits up to timeout, then
// SIGKILLs. The group id equals the pid because we start children with
// Setpgid.
func stopPID(pid int, timeout time.Duration) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !pidAlive(pid) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	// Give it a moment to die.
	for i := 0; i < 40 && pidAlive(pid); i++ {
		time.Sleep(50 * time.Millisecond)
	}
}

// loadListenerState reads persisted state (nil if none).
func (b *CLIBackend) loadListenerState() (*listenerState, error) {
	data, err := atomicfile.Read(b.statePath())
	if err != nil {
		if errors.Is(err, atomicfile.ErrNotFound) {
			return nil, nil
		}
		return nil, err
	}
	var st listenerState
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, &Error{Kind: ErrListenerFailed, Message: "listener state is corrupt", Detail: err.Error()}
	}
	return &st, nil
}

// listenerFromState reconstructs a Listener view from persisted state so
// status/stop work from a fresh backend invocation.
func (b *CLIBackend) listenerFromState(st *listenerState) *Listener {
	return &Listener{b: b, state: *st}
}
