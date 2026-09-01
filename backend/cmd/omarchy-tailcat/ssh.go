package main

import (
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"

	"omarchy-tailcat/tailcat"
	"omarchy-tailcat/validate"
)

// sshCmd dispatches the SSH subcommands.
//
//	ssh open <target> [--port=N] [--user=U] [--cmd=...]
//	    build `tailcat ssh …` and launch it in a terminal (detached)
//	ssh status
//	    detected terminal + tailcat availability (for UI guidance)
func sshCmd(ctx context.Context, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: ssh open|status"))
	}
	switch args[0] {
	case "open":
		return sshOpen(ctx, args[1:])
	case "status":
		return sshStatus(ctx)
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown ssh subcommand %q", args[0]))
	}
}

// knownTerminals maps a terminal binary to the flag that runs a command.
// tailcat ssh is interactive (it execs system ssh), so it must live in a
// real terminal window, not the background.
var knownTerminals = []struct {
	name string
	flag string
}{
	{"ghostty", "-e"},
	{"alacritty", "-e"},
	{"kitty", "-e"},
	{"foot", "-e"},
	{"x-terminal-emulator", "-e"},
	{"kgx", "--"},
	{"gnome-terminal", "--"},
}

// detectTerminal returns the terminal binary (resolved to a path) and the
// flag used to run a command in it. Override with OMARCHY_TAILCAT_TERMINAL.
func detectTerminal() (string, string, error) {
	if t := strings.TrimSpace(os.Getenv("OMARCHY_TAILCAT_TERMINAL")); t != "" {
		p, err := exec.LookPath(t)
		if err != nil {
			return "", "", tailcat.Errf(tailcat.ErrCommandFailed, "terminal %q not found (set OMARCHY_TAILCAT_TERMINAL)", t)
		}
		return p, "-e", nil
	}
	for _, t := range knownTerminals {
		if p, err := exec.LookPath(t.name); err == nil {
			return p, t.flag, nil
		}
	}
	return "", "", tailcat.Errf(tailcat.ErrCommandFailed, "no terminal found (install one of ghostty/alacritty/kitty/foot, or set OMARCHY_TAILCAT_TERMINAL)")
}

func sshStatus(ctx context.Context) int {
	term, _, terr := detectTerminal()
	st := map[string]any{
		"terminal":   term,
		"terminalOK": terr == nil,
		"terminalError": func() string {
			if terr != nil {
				return terr.Error()
			}
			return ""
		}(),
	}
	b := newBackendFromStore(socksStore())
	if bin, err := b.BinPath(); err == nil {
		st["tailcatPath"] = bin
		st["tailcatOK"] = true
	} else {
		st["tailcatOK"] = false
	}
	emitLine(st)
	return 0
}

func sshOpen(ctx context.Context, args []string) int {
	var target, user, cmd string
	port := "22"
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--port="):
			v := strings.TrimPrefix(a, "--port=")
			if v == "" {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "--port requires a value"))
			}
			if _, err := strconv.Atoi(v); err != nil {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "--port must be a number"))
			}
			port = v
		case strings.HasPrefix(a, "--user="):
			user = strings.TrimPrefix(a, "--user=")
		case strings.HasPrefix(a, "--cmd="):
			cmd = strings.TrimPrefix(a, "--cmd=")
		case strings.HasPrefix(a, "--"):
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown ssh flag %q", a))
		default:
			if target == "" {
				target = a
			} else {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unexpected argument %q (one target only)", a))
			}
		}
	}
	target = strings.TrimSpace(target)
	if target == "" {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "a target is required (tc… token or DNS name)"))
	}
	if !validate.TokenShapeOK(target) && !validate.DNSNameOK(target) {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "%q is not a valid tailcat token or DNS name", target))
	}

	b := newBackendFromStore(socksStore())
	bin, err := b.BinPath()
	if err != nil {
		return errOut(err)
	}

	// Build `tailcat ssh [-p P] [user@]target [cmd...]`.
	argv := []string{bin, "ssh"}
	if port != "22" {
		argv = append(argv, "-p", port)
	}
	dest := target
	if user != "" {
		dest = user + "@" + target
	}
	argv = append(argv, dest)
	if cmd != "" {
		argv = append(argv, strings.Fields(cmd)...)
	}

	term, termFlag, err := detectTerminal()
	if err != nil {
		return errOut(err)
	}
	// The tailcat binary (not a name on PATH) must be what the ssh ProxyCommand
	// uses; `tailcat ssh` derives it from its own executable, so passing the
	// absolute binary is correct and robust.
	termArgv := append([]string{term, termFlag}, argv...)
	cmdObj := exec.Command(termArgv[0], termArgv[1:]...)
	cmdObj.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmdObj.Start(); err != nil {
		return errOut(tailcat.Errf(tailcat.ErrCommandFailed, "could not launch %s: %s", term, err.Error()))
	}
	// Detach: don't wait; the terminal owns the ssh session.

	emitLine(map[string]any{
		"ok":       true,
		"terminal": term,
		"command":  strings.Join(argv, " "),
		"argv":     argv,
	})
	return 0
}
