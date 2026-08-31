# Tailcat Manager for Omarchy

A lightweight, native-feeling **Omarchy** extension providing a graphical
management interface for [Tailcat](https://github.com/tailscale/tailcat) —
"Tailscale without Tailscale": point-to-point, control-plane-free connectivity
over Tailscale's WireGuard data plane + NAT traversal.

> **Goal:** make Tailcat easy to use *without* remembering or typing CLI
> commands. Not a VPN, not a subnet router, not a control plane.

## Status

**Phase 0 (technical spike) — in progress.** Upstream Tailcat has been analyzed;
see:

- `docs/tailcat-analysis.md` — the Phase 0 source analysis (CLI/API/file
  transfer/security/testing).
- `docs/architecture.md` — recommended architecture, backend interface, and
  implementation plan.
- `docs/security.md` — threat model for tokens, keys, config, and file transfer.

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
ui/              Quickshell/QML plugin (manifest.json, Panel.qml, Manager.qml)
tests/           unit + hermetic e2e (local-DERP)
packaging/       Omarchy/Arch packaging
```

## Development

See `docs/architecture.md` §10 for the plan. This project follows the memory
protocol in `AGENTS.md` (`memory/`).

## License

TBD — likely BSD-3-Clause (matching upstream Tailcat) or MIT (matching Omarchy
plugin conventions). Decide at first release.
