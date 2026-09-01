# Tailcat Manager for Omarchy

A lightweight, native-feeling **Omarchy** extension providing a graphical
management interface for [Tailcat](https://github.com/tailscale/tailcat) —
"Tailscale without Tailscale": point-to-point, control-plane-free connectivity
over Tailscale's WireGuard data plane + NAT traversal.

> **Goal:** make Tailcat easy to use *without* remembering or typing CLI
> commands. Not a VPN, not a subnet router, not a control plane.

## Install (one line) — other machines / Omarchy

```sh
# 1. tailcat (the thing being managed) — required, on PATH
paru -S tailcat        # or: tailcat-bin

# 2. Tailcat Manager (backend + Omarchy bar widget, no Go needed)
curl -sL https://raw.githubusercontent.com/gmaxxxie/tailcat-manager/master/quick-install.sh | bash
```

The script downloads the prebuilt backend from the GitHub release for your
architecture (fallback: builds from source with Go 1.27+), installs it to
`~/.local/bin/omarchy-tailcat`, and on Omarchy systems installs + enables the
bar widget and restarts the shell. Re-run to update. See `quick-install.sh`.

## Status

**Phase 0 (technical spike) — done.** Upstream Tailcat analyzed; see:

- `docs/tailcat-analysis.md` — the Phase 0 source analysis (CLI/API/file
  transfer/security/testing).
- `docs/architecture.md` — recommended architecture, backend interface, and
  implementation plan.
- `docs/security.md` — threat model for tokens, keys, config, and file transfer.

**V0.1 backend — implemented and tested** (`backend/`):

- `omarchy-tailcat` Go binary: JSON subcommands for version/status/validate/
  identities/serve/ping/devices/diagnostics.
- `TailcatBackend` interface + CLI adapter (`tailcat/cli.go`) with a
  state-persisted, detached listener lifecycle (`serve start/stop/restart`
  survive backend invocations).
- Atomic 0600 config (`config/`), device registry (`domain/`), supervised
  process helper (`process/`), input validation (`validate/`).
- Unit tests (fake tailcat) + **hermetic e2e against a real tailcat binary**
  with a localhost DERP server — fully offline.

**V0.1 GUI — implemented and live on Omarchy** (`ui/`):

- Quickshell bar-widget plugin `dev.omarchy.tailcat` (`manifest.json`,
  `Panel.qml`, `Manager.qml`, `TailcatBridge.qml`) with Dashboard / Connect /
  Saved Devices / Identities / Shared Services / Diagnostics.
- Backend bridge calls `omarchy-tailcat` with structured argv + JSON.
- Install: `./packaging/omarchy/install.sh` (builds backend, installs the
  plugin, enables it, puts it on the bar).
- Dev validation harness: `quickshell -p ui/Harness.qml` (see `ui/README.md`).

**V0.2 native file transfer — implemented and tested** (`backend/` + `ui/`):

- Native Go adapter (`tailcat/native.go`) with a thin framing protocol over
  TCP (JSON-line header + raw body): `file`/`accept`/`reject`/`error`/`done`/
  `cancel` ops, progress, SHA-256 verify, safe-name + O_EXCL collision
  refusal, partial cleanup.
- CLI: `omarchy-tailcat file send|recv-start|recv-stop|recv-status|recv-respond`
  (send one-shot with JSON-lines progress; recv is a state-persisted daemon
  mirroring the serve listener pattern).
- GUI: RECEIVE FILE (start/stop, share address + copy, incoming
  Accept/Reject + progress, completed list) and SEND FILE (device chips +
  target/path, progress, cancel) on Home; native XDG Desktop Portal file/
  folder picker (`ui/bin/tc-filepicker`) on the Browse… buttons.
- Tests: protocol edge cases over TCP loopback + end-to-end through a real
  WireGuard data plane (local DERP, separate processes); real-DERP 400 KB
  transfer verified SHA-256-intact. See `docs/file-transfer.md`.

**V0.3 tabbed UI + SSH / SOCKS5 proxy / exit node — implemented**

- **Tabbed popup:** Manager.qml restructured into five tabs — **Status**
  (listener start/stop/restart/ping, running services, address, key), **SSH**
  (open the system ssh client through a tailcat server in a terminal),
  **Files** (receive + send + SFTP folder share), **Proxy** (SOCKS5 proxy +
  exit node), and **Manage** (devices / identities / services / diagnostics).
- **SSH tab:** `omarchy-tailcat ssh open <target> [--port] [--user] [--cmd]`
  builds `tailcat ssh …` and launches it in a detected terminal
  (ghostty/alacritty/kitty/foot/…, override `OMARCHY_TAILCAT_TERMINAL`); a
  Copy-command button gives the raw command for manual use.
- **SOCKS5 proxy:** `omarchy-tailcat socks start [--port] [--target]` runs a
  detached `tailcat socks` daemon (state-persisted, like the listener) and
  reports `socks5h://127.0.0.1:port` for copying into apps; `stop`/`status`.
- **Exit node:** Proxy tab toggles the `exit-node` serve service (restarts
  the listener); Status tab shows running services.
- **SFTP folder share:** the `files` service now actually works — a directory
  + ro/rw/wo mode is passed through as `--files=DIR[:mode]` (this was a
  latent broken path: adding a files service used to fail at start).
- **Allow list (who can connect):** Status tab gained an ALLOW LIST block —
  add/remove client public keys (`nodekey:…`), a `--allow=none`
  "block all clients" toggle, and a warning when a fixed (stable-address)
  identity is served with no allow list (anyone with the address could
  connect). The allow-list persists with the serve spec and is passed to
  `tailcat serve --allow=…`.
- **Persisted serve spec:** the listener's services+key are saved to
  `spec.json`; a bare `serve start`/`serve restart` reuses them instead of
  silently going broad, and the Status/Manage tabs load them on open.

Upstream reference copy (pinned for study): `upstream-tailcat/` (a clone of
`github.com/tailscale/tailcat`, do not edit).

## Integration decision (Phase 0 outcome)

Hybrid, behind one `TailcatBackend` interface:

- **V0.1 — CLI adapter:** wrap the `tailcat` binary with structured argv
  (`TAILCAT_ADDR_FILE`, `--json`, `parse`, `ping`, `genkey`). Fast, low
  coupling, no heavy dependency tree.
- **V0.2 — native Go library adapter:** file/text transfer with progress,
  cancel, accept/reject needs streaming the CLI cannot expose; use
  `github.com/tailscale/tailcat` directly behind the same interface.

## Structure

```
docs/            analysis, architecture, security
backend/         Go backend (interface, cli/native adapters, config, process)
ui/              Quickshell/QML plugin (manifest.json, Panel.qml, Manager.qml) — next
packaging/       Omarchy/Arch packaging — next
tests/           (unit tests live inside backend/; hermetic e2e in backend/e2e)
```

## Development

See `docs/architecture.md` §10 for the plan. This project follows the memory
protocol in `AGENTS.md` (`memory/`).

Next up: V0.3 text transfer (same port/protocol, `op:"text"`), then the
V0.1+V0.2 two-machine acceptance walkthrough (`docs/two-machine-test.md`).

## License

TBD — likely BSD-3-Clause (matching upstream Tailcat) or MIT (matching Omarchy
plugin conventions). Decide at first release.
