# Project State

## Tailcat Manager for Omarchy (`/home/max/项目/tailcat-manager`)

### Status: Phase 0 done; V0.1 backend implemented & tested; GUI next

- **Phase 0 (technical spike) — DONE.** Upstream Tailcat
  (`github.com/tailscale/tailcat`) cloned to `upstream-tailcat/` (pinned
  commit `4d50a34f`, 2026-08-30, `go 1.27.0`) and analyzed from source.
- **Docs:** `docs/tailcat-analysis.md`, `docs/architecture.md`, `docs/security.md`.
- **V0.1 backend — DONE (backend/):**
  - `omarchy-tailcat` Go binary, JSON subcommands: version/status/validate/
    parse/identities/serve/ping/devices/diagnostics.
  - `TailcatBackend` interface (`tailcat/backend.go`) + CLI adapter
    (`tailcat/cli.go`); listener is a detached `tailcat serve` process with
    persisted state (`listener.json`/`addr`), so serve status/stop work across
    backend invocations.
  - `config/` atomic 0600 versioned config; `domain/` device registry;
    `process/` supervised child; `validate/` shape checks; `atomicfile/`.
  - Tests: unit (fake tailcat in `testdata/fake-tailcat.sh`) + hermetic e2e
    (`backend/e2e/`) vs REAL tailcat binary with localhost DERP
    (`TS_DEBUG_TAILCAT_LOCAL_DERP=1`, `--derpmap-url=none`) — offline.
  - Verified end-to-end: start listener, validate token, ping direct,
    echo round-trip through the tunnel, saved devices, identities
    (persistent address / ephemeral), diagnostics redaction.
- **Go toolchain installed via mise: go@1.27.0.**
- **Real tailcat binary built** to /tmp/tailcat-build/tailcat (pseudo-version
  `v0.0.0-2026...`; versionOK accepts pseudo/devel builds).
- **tailcat NOT installed on system PATH** (Arch AUR: `tailcat`/`tailcat-bin`);
  the V0.1 backend detects presence and guides install.

### Next actions (in order)
1. Quickshell GUI shell (`ui/`: manifest.json, Panel.qml bar widget,
   Manager.qml window, TailcatBridge.qml calling the backend).
2. Wire GUI ↔ backend; V0.1 acceptance walkthrough (14 criteria).
3. Two-machine testing.
4. V0.2 native file transfer (`native.go` + framing protocol).

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
