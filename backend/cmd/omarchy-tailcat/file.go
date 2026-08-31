package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/types/key"

	"omarchy-tailcat/atomicfile"
	"omarchy-tailcat/config"
	"omarchy-tailcat/process"
	"omarchy-tailcat/tailcat"
)

// fileCmd dispatches the V0.2 native file-transfer subcommands.
//
//	file send <blob> <path> [--name=] [--derpmap-url=]
//	    one-shot sender; emits JSON-lines (progress + final result)
//	file recv [--dir=] [--key=] [--derpmap-url=]     (daemon; spawned detached)
//	file recv-start [--dir=] [--key=] [--derpmap-url=]
//	file recv-stop
//	file recv-status
//	file recv-respond <id> accept [dest] | reject
func fileCmd(ctx context.Context, store *config.Store, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: file send|recv-start|recv-stop|recv-status|recv-respond"))
	}
	switch args[0] {
	case "send":
		return fileSend(ctx, args[1:])
	case "recv":
		return fileRecv(ctx, args[1:])
	case "recv-start":
		return fileRecvStart(ctx, args[1:])
	case "recv-stop":
		return fileRecvStop(ctx)
	case "recv-status":
		return fileRecvStatus(ctx)
	case "recv-respond":
		return fileRecvRespond(ctx, args[1:])
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown file subcommand %q", args[0]))
	}
}

// --- sender ----------------------------------------------------------------

// emitLine writes one JSON object as a stdout line.
func emitLine(v any) {
	_ = json.NewEncoder(os.Stdout).Encode(v)
}

func fileSend(ctx context.Context, args []string) int {
	var name, derpMapURL string
	var pos []string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--name="):
			name = strings.TrimPrefix(a, "--name=")
		case strings.HasPrefix(a, "--derpmap-url="):
			derpMapURL = strings.TrimPrefix(a, "--derpmap-url=")
		case strings.HasPrefix(a, "--"):
			emitLine(map[string]any{"type": "error", "message": "unknown flag " + a})
			return 1
		default:
			pos = append(pos, a)
		}
	}
	if len(pos) < 2 {
		emitLine(map[string]any{"type": "error", "message": "usage: file send <blob> <path>"})
		return 1
	}
	blob, path := pos[0], pos[1]

	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	var mu sync.Mutex
	var lastEmit time.Time
	res, err := tailcat.SendFileToToken(ctx, blob, derpMapURL, path, name, func(sent, total int64) {
		mu.Lock()
		now := time.Now()
		if now.Sub(lastEmit) > 100*time.Millisecond {
			lastEmit = now
			mu.Unlock()
			emitLine(map[string]any{"type": "progress", "sent": sent, "total": total})
			return
		}
		mu.Unlock()
	})
	if err != nil {
		var te *tailcat.Error
		if errors.As(err, &te) {
			emitLine(map[string]any{"type": "error", "message": te.Message, "detail": te.Detail})
		} else {
			emitLine(map[string]any{"type": "error", "message": err.Error()})
		}
		return 1
	}
	emitLine(map[string]any{"type": "done", "ok": true, "bytes": res.Bytes, "sha256": res.SHA256})
	return 0
}

// --- receiver daemon state ------------------------------------------------

// recvDir is where the receiver daemon keeps its state.
func recvDir() string { return filepath.Join(config.Dir(), "filerecv") }

// recvState is the daemon's persisted status.
type recvState struct {
	Running bool          `json:"running"`
	Addr    string        `json:"addr,omitempty"`
	Dir     string        `json:"dir"`
	Key     string        `json:"key,omitempty"`
	Pending []recvPending `json:"pending"`
	Done    []recvDone    `json:"done"`
	LastErr string        `json:"lastError,omitempty"`
}

type recvPending struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	Sender string `json:"sender,omitempty"`
	SHA256 string `json:"sha256,omitempty"`
	Sent   int64  `json:"sent"`
	State  string `json:"state"` // offered | transferring | done | failed | rejected
}

type recvDone struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Dest   string `json:"dest,omitempty"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256,omitempty"`
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
	At     string `json:"at"`
}

// writeRecvState persists the daemon state (atomic, 0600).
func writeRecvState(st *recvState) {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return
	}
	_ = atomicfile.Write(filepath.Join(recvDir(), "state.json"), b, 0600)
}

// loadRecvState reads the daemon state (zero value if absent).
func loadRecvState() recvState {
	var st recvState
	b, err := atomicfile.Read(filepath.Join(recvDir(), "state.json"))
	if err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}

// readRecvPid reads the daemon pid file.
func readRecvPid() int {
	b, _ := atomicfile.Read(filepath.Join(recvDir(), "pid"))
	var pid int
	_, _ = fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &pid)
	return pid
}

// pidAliveLocal reports whether pid exists (signal 0 probe).
func pidAliveLocal(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// recvRunning reports whether the daemon pid is alive.
func recvRunning() bool { return pidAliveLocal(readRecvPid()) }

// stopPIDLocal terminates a process group (-pid): SIGTERM then SIGKILL.
func stopPIDLocal(pid int, timeout time.Duration) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !pidAliveLocal(pid) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	for i := 0; i < 40 && pidAliveLocal(pid); i++ {
		time.Sleep(50 * time.Millisecond)
	}
}

// --- receiver daemon (file recv) ------------------------------------------

func fileRecv(ctx context.Context, args []string) int {
	var dir, keyName, derpMapURL string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--dir="):
			dir = strings.TrimPrefix(a, "--dir=")
		case strings.HasPrefix(a, "--key="):
			keyName = strings.TrimPrefix(a, "--key=")
		case strings.HasPrefix(a, "--derpmap-url="):
			derpMapURL = strings.TrimPrefix(a, "--derpmap-url=")
		case strings.HasPrefix(a, "--"):
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown flag %s", a))
		}
	}
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, "Downloads")
	}
	absDir, err := filepath.Abs(dir)
	if err != nil {
		return errOut(err)
	}
	if fi, err := os.Stat(absDir); err != nil || !fi.IsDir() {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "receive directory %q is not a directory", absDir))
	}

	// V0.2 receiver identity: ephemeral only. (Saved-key receiver identities
	// are a follow-up; the address is shared fresh each session.)
	var priv key.NodePrivate
	_ = keyName

	if err := os.MkdirAll(recvDir(), 0700); err != nil {
		return errOut(err)
	}
	_ = os.MkdirAll(filepath.Join(recvDir(), "decisions"), 0700)

	st := recvState{Running: true, Dir: absDir, Key: "ephemeral"}

	var mu sync.Mutex
	// updatePending flips a pending entry's state under lock.
	markPending := func(id, state string) {
		mu.Lock()
		defer mu.Unlock()
		for i := range st.Pending {
			if st.Pending[i].ID == id {
				st.Pending[i].State = state
			}
		}
		writeRecvState(&st)
	}

	decide := func(in tailcat.IncomingFile) (string, bool) {
		mu.Lock()
		st.Pending = append(st.Pending, recvPending{ID: in.ID, Name: in.Name, Size: in.Size, Sender: in.Sender, SHA256: in.SHA256, State: "offered"})
		writeRecvState(&st)
		mu.Unlock()

		// Wait for the GUI to write a decision file.
		decisionPath := filepath.Join(recvDir(), "decisions", in.ID+".json")
		deadline := time.Now().Add(10 * time.Minute)
		for time.Now().Before(deadline) {
			b, err := atomicfile.Read(decisionPath)
			if err == nil {
				var d struct {
					Accept bool   `json:"accept"`
					Dest   string `json:"dest"`
				}
				_ = json.Unmarshal(b, &d)
				_ = atomicfile.Remove(decisionPath)
				if !d.Accept {
					markPending(in.ID, "rejected")
					return "", false
				}
				dest := d.Dest
				if dest == "" {
					dest = filepath.Join(absDir, in.Name)
				}
				markPending(in.ID, "transferring")
				return dest, true
			}
			if !recvRunning() {
				return "", false
			}
			select {
			case <-time.After(100 * time.Millisecond):
			case <-ctx.Done():
				return "", false
			}
		}
		return "", false // timed out waiting for a decision
	}

	progress := func(id string, sent, total int64) {
		mu.Lock()
		for i := range st.Pending {
			if st.Pending[i].ID == id {
				st.Pending[i].Sent = sent
			}
		}
		writeRecvState(&st)
		mu.Unlock()
	}

	onResult := func(in tailcat.IncomingFile, res tailcat.TransferResult) {
		mu.Lock()
		defer mu.Unlock()
		// Move the pending entry to done.
		for i := range st.Pending {
			if st.Pending[i].ID == in.ID {
				st.Done = append(st.Done, recvDone{
					ID: in.ID, Name: in.Name, Dest: res.File, Bytes: res.Bytes,
					SHA256: res.SHA256, OK: res.OK, Error: res.Error, At: time.Now().UTC().Format(time.RFC3339),
				})
				st.Pending = append(st.Pending[:i], st.Pending[i+1:]...)
				break
			}
		}
		writeRecvState(&st)
	}

	recv, blob, err := tailcat.StartReceiver(ctx, priv, tailcat.ReceiverOptions{DERPMapURL: derpMapURL},
		tailcat.ReceiveOptions{Decide: decide, Progress: progress, OnResult: onResult})
	if err != nil {
		return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "could not start the native receiver: %s", err.Error()))
	}
	defer recv.Close()

	st.Addr = blob
	writeRecvState(&st)
	_ = atomicfile.Write(filepath.Join(recvDir(), "addr"), []byte(blob), 0600)
	_ = atomicfile.Write(filepath.Join(recvDir(), "pid"), []byte(fmt.Sprint(os.Getpid())), 0600)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	mu.Lock()
	st.Running = false
	writeRecvState(&st)
	mu.Unlock()
	_ = atomicfile.Remove(filepath.Join(recvDir(), "pid"))
	return 0
}

// --- receiver management (start/stop/status/respond) ----------------------

func fileRecvStart(ctx context.Context, args []string) int {
	var dir, keyName, derpMapURL string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--dir="):
			dir = strings.TrimPrefix(a, "--dir=")
		case strings.HasPrefix(a, "--key="):
			keyName = strings.TrimPrefix(a, "--key=")
		case strings.HasPrefix(a, "--derpmap-url="):
			derpMapURL = strings.TrimPrefix(a, "--derpmap-url=")
		case strings.HasPrefix(a, "--"):
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown flag %s", a))
		}
	}
	if recvRunning() {
		return errOut(tailcat.Errf(tailcat.ErrListenerRunning, "the file receiver is already running"))
	}
	_ = atomicfile.Remove(filepath.Join(recvDir(), "addr"))

	exe, err := os.Executable()
	if err != nil {
		return errOut(err)
	}
	argv := []string{exe, "file", "recv"}
	if dir != "" {
		argv = append(argv, "--dir="+dir)
	}
	if keyName != "" {
		argv = append(argv, "--key="+keyName)
	}
	if derpMapURL != "" {
		argv = append(argv, "--derpmap-url="+derpMapURL)
	}
	child, err := process.Start(ctx, argv, os.Environ(), tailcat.Redact)
	if err != nil {
		return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "could not start the file receiver: %s", err.Error()))
	}
	// Wait for the addr file (the daemon writes it after StartReceiver).
	deadline := time.Now().Add(40 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(filepath.Join(recvDir(), "addr")); err == nil && len(b) > 0 {
			st := loadRecvState()
			_ = atomicfile.Write(filepath.Join(recvDir(), "pid"), []byte(fmt.Sprint(child.Cmd.Process.Pid)), 0600)
			emitLine(map[string]any{"addr": strings.TrimSpace(string(b)), "dir": st.Dir, "key": st.Key})
			return 0
		}
		select {
		case <-child.Done():
			return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "the file receiver exited early: %s", child.JoinLines()))
		default:
		}
		time.Sleep(100 * time.Millisecond)
	}
	child.Stop(3 * time.Second)
	return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "timed out waiting for the file receiver: %s", child.JoinLines()))
}

func fileRecvStop(ctx context.Context) int {
	if pid := readRecvPid(); pid > 0 {
		stopPIDLocal(pid, 5*time.Second)
	}
	_ = atomicfile.Remove(filepath.Join(recvDir(), "pid"))
	_ = atomicfile.Remove(filepath.Join(recvDir(), "addr"))
	st := loadRecvState()
	st.Running = false
	st.Pending = nil
	st.Done = nil
	writeRecvState(&st)
	emitLine(map[string]any{"stopped": true})
	return 0
}

func fileRecvStatus(ctx context.Context) int {
	st := loadRecvState()
	st.Running = recvRunning()
	if !st.Running {
		st.Pending = nil
		st.Done = nil
	}
	emitLine(st)
	return 0
}

func fileRecvRespond(ctx context.Context, args []string) int {
	if len(args) < 2 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: file recv-respond <id> accept [dest] | reject"))
	}
	id, op := args[0], args[1]
	dest := ""
	if len(args) > 2 {
		dest = args[2]
	}
	switch op {
	case "accept", "reject":
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "op must be accept or reject"))
	}
	decisionPath := filepath.Join(recvDir(), "decisions", id+".json")
	if _, err := os.Stat(decisionPath); err == nil {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "decision already given for %q", id))
	}
	d := map[string]any{"accept": op == "accept"}
	if dest != "" {
		d["dest"] = dest
	}
	b, _ := json.Marshal(d)
	if err := atomicfile.Write(decisionPath, b, 0600); err != nil {
		return errOut(err)
	}
	emitLine(map[string]any{"ok": true})
	return 0
}
