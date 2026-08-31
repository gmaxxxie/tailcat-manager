# omarchy-tailcat — backend

The Go backend behind the Tailcat Manager. It is a **machine interface**: every
subcommand prints one JSON object on stdout (an error object with `kind`,
`message`, `detail` on failure, exit code 1) and is invoked with structured
argument arrays — never a shell.

It isolates all Tailcat integration behind the `TailcatBackend` interface
(`tailcat/backend.go`), implemented today by the CLI adapter (`tailcat/cli.go`).

## Build

```sh
go build -o omarchy-tailcat ./cmd/omarchy-tailcat
```

Requires Go 1.27+. No external Go dependencies for the V0.1 CLI backend.

## Subcommands

```
version                     availability + version JSON
status                      backend + listener snapshot JSON
validate <target>           validate a token/DNS name (local, no network)
parse <token>               alias for validate
identities list             saved identities (with client-kind hints)
identities create <name> [--client] [--region=X]
identities delete <name>
identities pub              current client public key
serve start <spec...> [--key=X] [--allow=a,b] [--allow-none] [--files=D[:mode]] [--full-address]
serve stop
serve restart <spec...> (same flags as start)
serve status
ping <target> [--until-direct] [--timeout=D]
devices list|add <name> <target>|remove <id>|rename <id> <name>|touch <id>
diagnostics
```

`<spec...>` is a comma-separated list of ports and named services
(`no-auth-ssh`, `files`, `exit-node`). An empty spec serves all localhost ports
(`serve all`, flagged as `broad` in status).

## Config & state

- Manager config: `~/.config/omarchy-tailcat/config.json` (0600, atomic,
  versioned). Override with `OMARCHY_TAILCAT_CONFIG_DIR` (tests/portability).
- Listener state: `~/.config/omarchy-tailcat/listener.json` + `addr`. The
  listener is a detached `tailcat serve` process that survives backend
  invocations; `serve status`/`serve stop` work from any invocation.
- Tailcat's own keys/cache live under `~/.config/tailcat/` and
  `~/.cache/tailcat/` and are never written by this backend.

## Tests

```sh
go test ./...                 # unit tests use a fake tailcat (testdata/)
TAILCAT_BIN=/path/to/tailcat go test ./...   # + hermetic e2e vs real binary
```

The hermetic e2e (`e2e/`) runs a real tailcat server against a **localhost DERP
server** (`TS_DEBUG_TAILCAT_LOCAL_DERP=1`, `--derpmap-url=none`), so no
internet is needed. It sets isolated `XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`HOME`
so it never touches real user config.

Build a tailcat binary for it from the pinned upstream checkout:

```sh
cd ../upstream-tailcat && go build -o /tmp/tailcat-build/tailcat ./cmd/tailcat
```

## Security

See `../docs/security.md`. Highlights: argv-only process execution, token
redaction in all logs/diagnostics, 0600 atomic config writes, private keys
never read/displayed.
