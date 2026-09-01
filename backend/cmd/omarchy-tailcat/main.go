// Command omarchy-tailcat is the manager's Go backend. It is a machine
// interface: every subcommand prints one JSON object on stdout (an error object
// with kind/message on failure, exit code 1) and is called with structured
// argument arrays — never a shell. The Omarchy QML bridge calls this binary.
//
// Usage: omarchy-tailcat <subcommand> [args...]
//
//	version                    availability + version JSON
//	status                     backend + listener snapshot JSON
//	validate <target>          validate a token/DNS name (no network)
//	parse <token>              alias for validate
//	identities list            saved identities (with client-kind hints)
//	identities create <name> [--client] [--region=X]
//	identities delete <name>
//	identities pub             current client public key
//	serve start <spec...> [--key=X] [--allow=a,b] [--allow-none] [--files=D[:mode]] [--full-address]
//	serve stop
//	serve restart <spec...> (same flags as start)
//	serve status
//	ping <target> [--until-direct] [--timeout=D]
//	devices list
//	devices add <name> <target>
//	devices remove <id>
//	devices rename <id> <name>
//	devices touch <id>           stamp last-connected
//	diagnostics
package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"omarchy-tailcat/config"
	"omarchy-tailcat/domain"
	"omarchy-tailcat/tailcat"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

// out writes a JSON value to stdout.
func out(v any) {
	_ = json.NewEncoder(os.Stdout).Encode(v)
}

// fail prints a JSON error to stdout and returns exit code 1.
func fail(kind, message, detail string) int {
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
		"error": map[string]string{"kind": kind, "message": message, "detail": detail},
	})
	return 1
}

func errOut(err error) int {
	var te *tailcat.Error
	if errors.As(err, &te) {
		return fail(string(te.Kind), te.Message, te.Detail)
	}
	return fail("error", err.Error(), "")
}

// newBackend builds the configured backend.
func newBackend(cfg *config.Config) *tailcat.CLIBackend {
	b := tailcat.NewCLIBackend()
	if cfg.Settings.DerpMapURL != "" {
		b.DerpMapURL = cfg.Settings.DerpMapURL
	}
	return b
}

func run(args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: omarchy-tailcat <subcommand> (version|status|validate|parse|identities|serve|ping|devices|diagnostics)"))
	}

	// Commands that need the store (devices, identity hints).
	store, err := config.Open()
	if err != nil {
		return errOut(err)
	}
	reg := domain.NewRegistry(store)

	ctx := context.Background()
	switch args[0] {
	case "version":
		b := newBackend(store.Config())
		v, _ := b.Available(ctx)
		out(v)
		return 0
	case "status":
		b := newBackend(store.Config())
		v, _ := b.Available(ctx)
		st, _ := b.ListenerStatus(ctx)
		out(map[string]any{"backend": b.Name(), "version": v, "listener": st})
		return 0
	case "validate", "parse":
		if len(args) < 2 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: %s <target>", args[0]))
		}
		b := newBackend(store.Config())
		ti, err := b.ValidateToken(ctx, args[1])
		if err != nil {
			return errOut(err)
		}
		out(ti)
		return 0
	case "identities":
		return identities(ctx, store, args[1:])
	case "serve":
		return serve(ctx, store, args[1:])
	case "ping":
		return ping(ctx, store, args[1:])
	case "devices":
		return devices(reg, args[1:])
	case "diagnostics":
		b := newBackend(store.Config())
		rep, _ := b.Diagnostics(ctx)
		out(rep)
		return 0
	case "web":
		// Long-running local web console (loopback only).
		return webCmd(args[1:])
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown subcommand %q", args[0]))
	}
}

// --- identities ---

func identities(ctx context.Context, store *config.Store, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: identities list|create|delete|pub"))
	}
	b := newBackend(store.Config())
	switch args[0] {
	case "list":
		ids, err := b.ListIdentities(ctx)
		if err != nil {
			return errOut(err)
		}
		// Overlay manager-known client-kind hints.
		for i := range ids {
			if k := store.IdentityKind(ids[i].Name); k != "" {
				ids[i].Kind = tailcat.IdentityKind(k)
			}
		}
		out(ids)
		return 0
	case "create":
		if len(args) < 2 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: identities create <name> [--client] [--region=X]"))
		}
		name := args[1]
		kind := tailcat.IdentityServer
		region := ""
		for _, a := range args[2:] {
			switch {
			case a == "--client":
				kind = tailcat.IdentityClient
			case strings.HasPrefix(a, "--region="):
				region = strings.TrimPrefix(a, "--region=")
			case a == "--region":
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "--region requires a value"))
			}
		}
		id, err := b.CreateIdentity(ctx, name, kind, region)
		if err != nil {
			return errOut(err)
		}
		_ = store.SetIdentityKind(name, string(id.Kind))
		out(id)
		return 0
	case "delete":
		if len(args) < 2 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: identities delete <name>"))
		}
		if err := b.DeleteIdentity(ctx, args[1]); err != nil {
			return errOut(err)
		}
		_ = store.RemoveIdentityKind(args[1])
		out(map[string]bool{"deleted": true})
		return 0
	case "pub":
		pub, err := b.CurrentClientPublicKey(ctx)
		if err != nil {
			return errOut(err)
		}
		out(map[string]string{"publicKey": pub})
		return 0
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown identities subcommand %q", args[0]))
	}
}

// --- serve ---

func serve(ctx context.Context, store *config.Store, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: serve start|stop|restart|status"))
	}
	b := newBackend(store.Config())
	switch args[0] {
	case "status":
		st, _ := b.ListenerStatus(ctx)
		out(st)
		return 0
	case "start", "restart":
		spec, err := parseServeSpec(args[1:])
		if err != nil {
			return errOut(err)
		}
		var st tailcat.ListenerStatus
		if args[0] == "restart" {
			st, err = b.RestartListener(ctx, spec)
		} else {
			st, err = b.StartListener(ctx, spec)
		}
		if err != nil {
			return errOut(err)
		}
		out(st)
		return 0
	case "stop":
		st, _ := b.StopListener(ctx)
		out(st)
		return 0
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown serve subcommand %q", args[0]))
	}
}

// parseServeSpec parses `serve start` flags + positional service specs.
func parseServeSpec(args []string) (tailcat.ListenerSpec, error) {
	var spec tailcat.ListenerSpec
	services := []tailcat.Service{}
	serviceArg := []string{}
	// First pass: separate flags from positional service specs.
	for _, a := range args {
		switch {
		case a == "--full-address":
			spec.FullAddr = true
		case a == "--allow-none":
			spec.AllowNone = true
		case strings.HasPrefix(a, "--allow="):
			spec.Allow = strings.Split(strings.TrimPrefix(a, "--allow="), ",")
		case strings.HasPrefix(a, "--files="):
			v := strings.TrimPrefix(a, "--files=")
			dir, mode, _ := strings.Cut(v, ":")
			spec.FilesDir = dir
			spec.FilesMode = mode
		case strings.HasPrefix(a, "--key="):
			spec.Key = strings.TrimPrefix(a, "--key=")
		case strings.HasPrefix(a, "--"):
			return spec, tailcat.Errf(tailcat.ErrInvalidInput, "unknown serve flag %q", a)
		default:
			serviceArg = append(serviceArg, a)
		}
	}
	for _, s := range serviceArg {
		for _, tok := range strings.Split(s, ",") {
			tok = strings.TrimSpace(tok)
			if tok == "" {
				continue
			}
			svc, err := parseServiceToken(tok)
			if err != nil {
				return spec, err
			}
			services = append(services, svc)
		}
	}
	spec.Services = services
	return spec, nil
}

func parseServiceToken(tok string) (tailcat.Service, error) {
	switch tok {
	case "no-auth-ssh":
		return tailcat.Service{Name: "SSH (built-in)", Kind: tailcat.ServiceNoAuthSSH, Enabled: true}, nil
	case "files":
		return tailcat.Service{Name: "File share", Kind: tailcat.ServiceFiles, Enabled: true}, nil
	case "exit-node":
		return tailcat.Service{Name: "Exit node", Kind: tailcat.ServiceExitNode, Enabled: true}, nil
	case "all":
		return tailcat.Service{}, tailcat.Errf(tailcat.ErrInvalidInput, "use no service argument to serve all ports")
	}
	if n, err := strconv.ParseUint(tok, 10, 16); err == nil {
		return tailcat.Service{Name: "Port " + tok, Kind: tailcat.ServicePortForward, Port: uint16(n), Enabled: true}, nil
	}
	return tailcat.Service{}, tailcat.Errf(tailcat.ErrInvalidInput, "%q is not a known service (ports, no-auth-ssh, files, exit-node)", tok)
}

// --- ping ---

func ping(ctx context.Context, store *config.Store, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: ping <target> [--until-direct] [--timeout=D]"))
	}
	var target string
	untilDirect := false
	timeout := 10 * time.Second
	for _, a := range args {
		switch {
		case a == "--until-direct":
			untilDirect = true
		case strings.HasPrefix(a, "--timeout="):
			d, err := time.ParseDuration(strings.TrimPrefix(a, "--timeout="))
			if err != nil {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "invalid --timeout: %v", err))
			}
			timeout = d
		case strings.HasPrefix(a, "--"):
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown ping flag %q", a))
		default:
			if target == "" {
				target = a
			} else {
				return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "too many arguments"))
			}
		}
	}
	if target == "" {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: ping <target>"))
	}
	b := newBackend(store.Config())
	pr, err := b.Ping(ctx, target, untilDirect, timeout)
	if err != nil {
		return errOut(err)
	}
	out(pr)
	return 0
}

// --- devices ---

func devices(reg *domain.Registry, args []string) int {
	if len(args) == 0 {
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: devices list|add|remove|rename|touch"))
	}
	switch args[0] {
	case "list":
		devs, err := reg.List()
		if err != nil {
			return errOut(err)
		}
		out(devs)
		return 0
	case "add":
		if len(args) < 3 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: devices add <name> <target>"))
		}
		d, err := reg.Add(args[1], args[2])
		if err != nil {
			return errOut(err)
		}
		out(d)
		return 0
	case "remove":
		if len(args) < 2 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: devices remove <id>"))
		}
		if err := reg.Remove(args[1]); err != nil {
			return errOut(err)
		}
		out(map[string]bool{"removed": true})
		return 0
	case "rename":
		if len(args) < 3 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: devices rename <id> <name>"))
		}
		if err := reg.Rename(args[1], args[2]); err != nil {
			return errOut(err)
		}
		out(map[string]bool{"renamed": true})
		return 0
	case "touch":
		if len(args) < 2 {
			return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "usage: devices touch <id>"))
		}
		if err := reg.MarkConnected(args[1]); err != nil {
			return errOut(err)
		}
		out(map[string]bool{"updated": true})
		return 0
	default:
		return errOut(tailcat.Errf(tailcat.ErrInvalidInput, "unknown devices subcommand %q", args[0]))
	}
}
