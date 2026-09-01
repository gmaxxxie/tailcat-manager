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

**2026-09 — simplified.** The project was split by surface:

- **Top-bar widget = status + start/stop only.** The popup is now a slim panel
  (listener status, Start/Stop/Restart, copy-address, self-ping). See `ui/`.
- **Everything else = pi + CLI.** Saved devices, identities, shared services,
  diagnostics, and **file transfer** are driven by pi via the `omarchy-tailcat`
  / `tailcat` CLIs. A pi skill (`tailcat`) teaches this; ask pi to "manage
  tailcat" in a terminal.
- **Native file-transfer backend removed.** The V0.2 native Go adapter
  (`native.go`, file daemon, `file` subcommand) and its huge
  `tailscale.com`/gVisor dependency tree were deleted. File transfer runs in
  the terminal: `tailcat recv <dir>` (receive) and `tailcat cp <file> <addr>:`
  (send).

### V0.1 (what remains)

**Phase 0 (technical spike) — done.** Upstream Tailcat analyzed; see:

- `docs/tailcat-analysis.md` — the Phase 0 source analysis (CLI/API/file
  transfer/security/testing).
- `docs/architecture.md` — architecture and implementation notes.
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
  `Panel.qml`, `Manager.qml`, `TailcatBridge.qml`) — **slim**: bar status
  glyph + popup with status/start/stop/restart/copy-address/ping.
- Backend bridge calls `omarchy-tailcat` with structured argv + JSON.
- Install: `./packaging/omarchy/install.sh` (builds backend, installs the
  plugin, enables it, puts it on the bar).
- Dev validation harness: `quickshell -p ui/Harness.qml` (see `ui/README.md`).

Upstream reference copy (pinned for study): `upstream-tailcat/` (a clone of
`github.com/tailscale/tailcat`, do not edit).

## Integration decision (revised 2026-09)

One `TailcatBackend` interface, one **CLI adapter**:

- **V0.1 — CLI adapter:** wrap the `tailcat` binary with structured argv
  (`TAILCAT_ADDR_FILE`, `--json`, `parse`, `ping`, `genkey`). Fast, low
  coupling, no heavy dependency tree.
- **V0.2 native library adapter: WITHDRAWN (2026-09).** File/text transfer
  with progress was the reason for the native adapter, but it is no longer
  part of the GUI. Transfers run in the terminal (`tailcat recv`/`cp`), where
  scp-style progress and accept behavior are already fine, so the native
  dependency was removed entirely.
- The UI talks only to the interface. If a GUI transfer UI is ever wanted
  again, re-introduce a native adapter behind the same interface.

## Structure

```
docs/            analysis, architecture, security, file-transfer (terminal)
backend/         Go backend (interface, cli adapter, config, process)
ui/              Quickshell/QML plugin (manifest.json, Panel.qml, Manager.qml)
packaging/       Omarchy/Arch packaging
memory/          project memory (decisions, lessons, state)
```

## Development

See `docs/architecture.md` for the architecture and the backend plan. This
project follows the memory protocol in `AGENTS.md` (`memory/`).

Current state: slim widget (status + start/stop) is live; management and file
transfer happen via pi (`tailcat` skill) and the CLIs. Next up: refresh the
widget/backend on the second machine and re-run the acceptance walkthrough
(`docs/two-machine-test.md`), and decide whether to keep `upstream-tailcat/`
in the repo.

## License

TBD — likely BSD-3-Clause (matching upstream Tailcat) or MIT (matching Omarchy
plugin conventions). Decide at first release.
