# Project State

## Tailcat Manager for Omarchy (`/home/max/tailcat-manager`)

### Status: SIMPLIFIED (2026-09-01) — widget = status+start/stop; management = pi skill; transfers = terminal

The project was deliberately de-complexified by splitting by surface:

- **Top-bar widget** = listener status + Start/Stop/Restart + copy-address +
  self-ping only. `ui/Manager.qml` went from **1186 → ~190 lines**;
  `TailcatBridge.qml` trimmed to status/serve/ping. Devices/identities/
  services/diagnostics/file-transfer pages were removed from the GUI.
- **pi skill `tailcat`** (`~/.pi/agent/skills/tailcat/SKILL.md`) drives the
  `omarchy-tailcat` CLI for everything else: devices, identities, shared
  services, diagnostics, connect/ping. User asks pi "帮我管理 tailcat".
- **File transfer in the terminal**: `tailcat recv <dir>` (receive) and
  `tailcat cp <file> <addr>:` (send). The **V0.2 native Go adapter was
  removed entirely** — `native.go`, `cmd/nativedemo`, the `file` subcommand +
  recv daemon, native e2e tests, and the `tailscale.com`/gVisor dep tree.
  Backend binary ~20MB → **~5MB**; build is fast; all unit tests pass.
- Installed binary updated at `~/.local/bin/omarchy-tailcat`.

### Next actions
1. **Restore `tailcat` binary** (currently MISSING — the dev build in
   `/tmp/tailcat-build/` was wiped). Either `paru -S tailcat`/`tailcat-bin` or
   rebuild from `github.com/tailscale/tailcat` (pinned commit `4d50a34f`,
   2026-08-30) into `~/.local/bin/tailcat`. Until then the widget shows
   "NOT INSTALLED" (handled gracefully).
2. **Install the slim plugin to the live shell** (copy `ui/*.qml` to
   `~/.config/omarchy/plugins/dev.omarchy.tailcat/`, then
   `omarchy restart shell`) — pending user confirmation.
3. **Two-machine acceptance** (revised `docs/two-machine-test.md`): listener
   + terminal file transfer both ways, Direct vs DERP.
4. Optional: drop the archived `upstream-tailcat/` clone / decide license.

### Historical (pre-simplification)
- V0.1 backend + GUI were implemented and live; V0.2 native file transfer was
  implemented on this machine with real-DERP SHA-256 verification. All of that
  V0.2 native code is now deleted; the design/lessons live in git history +
  `docs/file-transfer.md` (rewritten as the terminal guide) and
  `docs/architecture.md` §0.
- Old UI lessons (layout rules, shell reload, token pitfalls) remain in
  `memory/lessons_learned.md` and still apply.

### Key technical facts (verified from source, still true)
- Tailcat server address = `tc` + base64url(CBOR) token; default DERP map
  `https://tailcat.dev/derpmap.json`; short token carries region ID only.
- No-arg `tailcat` = one-shot stdout pipe that EXITS after one connection;
  persistent listener requires `tailcat serve <ports|services>` — the manager
  runs it as a detached, state-persisted process (`serve start/stop/restart`).
- CLI machine hooks: `TAILCAT_ADDR_FILE`, `--json`, `parse` (JSON), `ping`
  line, `genkey --list`. Errors always exit 1 (no taxonomy).
- Embedded (full-address) tokens break DERP routing for region != 1; use short
  tokens. Native endpoints must run in separate processes.
- Keys live in `~/.config/tailcat/keys/` (0600). Manager config lives in
  `~/.config/omarchy-tailcat/` (0700/0600, atomic, versioned).

### Open questions
- License choice (BSD-3-Clause vs MIT) — deferred to first release.
- Whether to keep `upstream-tailcat/` clone in the repo (currently absent).
