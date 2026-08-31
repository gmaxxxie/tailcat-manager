# Project State

## Tailcat Manager for Omarchy (`/home/max/项目/tailcat-manager`)

### Status: Phase 0 complete; V0.1 not started

- **Phase 0 (technical spike) — DONE.** Upstream Tailcat
  (`github.com/tailscale/tailcat`) cloned to `upstream-tailcat/` (pinned
  commit `4d50a34f`, 2026-08-30, `go 1.27.0`) and analyzed from source.
- **Docs produced:** `docs/tailcat-analysis.md`, `docs/architecture.md`,
  `docs/security.md`. Repo skeleton created (`backend/`, `ui/`, `tests/`,
  `packaging/omarchy/`).
- **tailcat binary is NOT installed** on this machine (Arch; AUR `tailcat` /
  `tailcat-bin`). The V0.1 backend must detect presence and guide install.

### Next actions (in order)
1. `docs/security.md` is drafted; review once before V0.1 file-transfer work.
2. V0.1 backend skeleton: `backend/go.mod`,
   `backend/cmd/omarchy-tailcat` (JSON subcommands), `backend/config/` atomic
   config, `backend/domain/devices`, `backend/process/` supervised lifecycle.
3. CLI adapter (`backend/tailcat/cli.go`) wiring: `parse`, `genkey`,
   `ping`, `serve` + `TAILCAT_ADDR_FILE`.
4. Minimal hermetic connection prototype using `TS_DEBUG_TAILCAT_LOCAL_DERP=1`.
5. Quickshell GUI (`ui/manifest.json`, `Panel.qml`, `Manager.qml`).
6. Two-machine testing; then V0.2 native file transfer.

### Key technical facts (verified from source)
- Tailcat server address = `tc` + base64url(CBOR) token; default DERP map
  `https://tailcat.dev/derpmap.json`; short token carries region ID only.
- No-arg `tailcat` = one-shot stdout pipe that EXITS after one connection;
  persistent listener requires `tailcat serve <ports|services>`.
- CLI machine hooks: `TAILCAT_ADDR_FILE`, `--json`, `parse` (JSON),
  `ping` line, `genkey --list`. Errors always exit 1 (no taxonomy).
- `tailcat cp`/`ssh` wrap system `scp`/`ssh`; no GUI-friendly progress/cancel.
- File/text transfer with progress needs the NATIVE Go library (V0.2), using a
  thin framing protocol over a TCP stream (web-demo model).
- Keys live in `~/.config/tailcat/keys/` (0600). Manager config lives in
  `~/.config/omarchy-tailcat/` (0700/0600, atomic, versioned).

### Open questions
- License choice (BSD-3-Clause vs MIT) — deferred to first release.
- Exact Quickshell window vs popup-panel layout for Manager.
