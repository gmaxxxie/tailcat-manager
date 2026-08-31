# Tailcat Manager for Omarchy

A lightweight, native-feeling **Omarchy** extension providing a graphical
management interface for [Tailcat](https://github.com/tailscale/tailcat) —
"Tailscale without Tailscale": point-to-point, control-plane-free connectivity
over Tailscale's WireGuard data plane + NAT traversal.

> **Goal:** make Tailcat easy to use *without* remembering or typing CLI
> commands. Not a VPN, not a subnet router, not a control plane.

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

Next up: Quickshell GUI shell (`ui/`) wired to the backend, then the V0.1
acceptance walkthrough on two machines, then V0.2 native file transfer.

## License

TBD — likely BSD-3-Clause (matching upstream Tailcat) or MIT (matching Omarchy
plugin conventions). Decide at first release.
