package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"omarchy-tailcat/atomicfile"
	"omarchy-tailcat/config"
	"omarchy-tailcat/process"
	"omarchy-tailcat/tailcat"
)

// socksCmd dispatches the SOCKS5-proxy subcommands.
//
//	socks start [--port=N] [--target=<blob>] [--derpmap-url=]
//	socks stop
//	socks status
//
// The proxy is a detached `tailcat socks` process (like the serve listener),
// so it survives backend invocations and can be stopped/queried later.
func socksCmd(ctx context.Context, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: socks start|stop|status"))
	}
	switch args[0] {
	case "start":
		return socksStart(ctx, args[1:])
	case "stop":
		return socksStop(ctx)
	case "status":
		return socksStatus(ctx)
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown socks subcommand %q", args[0]))
	}
}

// socksDir is where the socks daemon keeps its state.
func socksDir() string { return filepath.Join(config.Dir(), "socks") }

// socksState is the daemon's persisted status.
type socksState struct {
	Running   bool      `json:"running"`
	Addr      string    `json:"addr,omitempty"` // socks5h://127.0.0.1:port
	Port      int       `json:"port,omitempty"`
	Target    string    `json:"target,omitempty"` // fixed server blob, if any
	PID       int       `json:"pid,omitempty"`
	StartedAt time.Time `json:"startedAt,omitempty"`
}

func writeSocksState(st *socksState) {
	b, _ := json.MarshalIndent(st, "", "  ")
	_ = atomicfile.Write(filepath.Join(socksDir(), "state.json"), b, 0600)
}

func loadSocksState() socksState {
	var st socksState
	b, err := atomicfile.Read(filepath.Join(socksDir(), "state.json"))
	if err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}

func readSocksPid() int {
	b, _ := atomicfile.Read(filepath.Join(socksDir(), "pid"))
	var pid int
	_, _ = fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &pid)
	return pid
}

// socksRunning reports whether the daemon pid is alive.
func socksRunning() bool { return pidAliveLocal(readSocksPid()) }

// socksAddrRX matches the proxy's startup line on stderr:
//
//	2026/09/01 21:18:21 SOCKS running at socks5h://127.0.0.1:18080
var socksAddrRX = regexp.MustCompile(`SOCKS running at (socks5h://[0-9.]+:[0-9]+)`)

// startWaitSocks is how long to wait for the proxy to publish its address.
const startWaitSocks = 20 * time.Second

func socksStart(ctx context.Context, args []string) int {
	if socksRunning() {
		return errOut(tailcat.Errf(tailcat.ErrListenerRunning, "the SOCKS5 proxy is already running; stop it first"))
	}
	var port int
	var target, derpMapURL string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--port="):
			n, err := strconv.Atoi(strings.TrimPrefix(a, "--port="))
			if err != nil || n < 0 || n > 65535 {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "--port must be 0–65535"))
			}
			port = n
		case strings.HasPrefix(a, "--target="):
			target = strings.TrimPrefix(a, "--target=")
		case strings.HasPrefix(a, "--derpmap-url="):
			derpMapURL = strings.TrimPrefix(a, "--derpmap-url=")
		case strings.HasPrefix(a, "--"):
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown socks flag %q", a))
		default:
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unexpected argument %q", a))
		}
	}
	if target != "" && !strings.HasPrefix(target, "tc") {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "--target must be a tc… token (the SOCKS proxy dials that server)"))
	}

	b := newBackendFromStore(socksStore())
	bin, err := b.BinPath()
	if err != nil {
		return errOut(err)
	}
	argv := []string{bin}
	if derpMapURL != "" {
		argv = append(argv, "--derpmap-url="+derpMapURL)
	}
	argv = append(argv, "socks", "--listen=127.0.0.1:"+strconv.Itoa(port))
	if target != "" {
		argv = append(argv, target)
	}

	if err := os.MkdirAll(socksDir(), 0700); err != nil {
		return errOut(err)
	}

	ctx, cancel := context.WithTimeout(ctx, startWaitSocks)
	defer cancel()
	child, err := process.Start(ctx, argv, os.Environ(), tailcat.Redact)
	if err != nil {
		return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "could not start the SOCKS5 proxy: %s", err.Error()))
	}

	// Wait for the proxy to print its listening address.
	deadline := time.Now().Add(startWaitSocks)
	var addr string
	for time.Now().Before(deadline) {
		for _, line := range child.OutputLines() {
			if m := socksAddrRX.FindStringSubmatch(line); m != nil {
				addr = m[1]
				break
			}
		}
		if addr != "" {
			break
		}
		select {
		case <-child.Done():
			return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "the SOCKS5 proxy exited before listening: %s", child.JoinLines()))
		default:
		}
		time.Sleep(50 * time.Millisecond)
	}
	if addr == "" {
		child.Stop(3 * time.Second)
		return errOut(tailcat.Errf(tailcat.ErrListenerFailed, "timed out waiting for the SOCKS5 proxy to listen: %s", child.JoinLines()))
	}

	portNum := 0
	if i := strings.LastIndexByte(addr, ':'); i >= 0 {
		portNum, _ = strconv.Atoi(addr[i+1:])
	}
	st := socksState{Running: true, Addr: addr, Port: portNum, Target: target, PID: child.Cmd.Process.Pid, StartedAt: time.Now().UTC()}
	writeSocksState(&st)
	_ = atomicfile.Write(filepath.Join(socksDir(), "pid"), []byte(fmt.Sprint(child.Cmd.Process.Pid)), 0600)
	emitLine(map[string]any{"running": true, "addr": addr, "port": portNum})
	return 0
}

func socksStop(ctx context.Context) int {
	if pid := readSocksPid(); pid > 0 {
		stopPIDLocal(pid, 5*time.Second)
	}
	_ = atomicfile.Remove(filepath.Join(socksDir(), "pid"))
	_ = atomicfile.Remove(filepath.Join(socksDir(), "addr"))
	st := loadSocksState()
	st.Running = false
	st.Addr = ""
	st.Port = 0
	st.Target = ""
	st.PID = 0
	writeSocksState(&st)
	emitLine(map[string]any{"stopped": true})
	return 0
}

func socksStatus(ctx context.Context) int {
	st := loadSocksState()
	st.Running = socksRunning()
	if !st.Running {
		st.Addr = ""
		st.Port = 0
		st.PID = 0
	}
	emitLine(st)
	return 0
}

// socksStore returns the config store used to build a backend (config dir only).
func socksStore() *config.Store {
	st, _ := config.Open()
	return st
}
