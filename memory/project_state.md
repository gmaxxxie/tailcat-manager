# Project State

## Tailcat Manager for Omarchy (`/home/max/项目/tailcat-manager`)

### Status: V0.1 done & live; V0.2 file transfer DONE (backend + GUI + real-DERP verified); two-machine next

- **V0.2 file transfer — COMPLETE on this machine:**
  - `omarchy-tailcat file send` (one-shot, JSON-lines progress + result) and
    `file recv` daemon + `recv-start/stop/status/respond` (file-based IPC
    state + decisions, mirrors the serve listener pattern).
  - GUI Files tab (7 tabs): receive service (start/stop, addr+copy, incoming
    offers with Accept/Reject + progress bars, completed list) and send
    (target + file path, progress bar, cancel) via TailcatBridge streaming
    (`file send` Process with waitForEnd:false collector).
  - KEY FIX: embedded-region tokens break real-DERP routing (ParseConnBlob
    restores RegionID=1); StartReceiver now emits a short RegionID token.
    Sender retries the meow handshake (startup race).
  - Verified: full backend suite green (protocol + local-DERP e2e + CLI file
    flows); real-DERP CLI ping 152ms; real-DERP 400KB transfer intact with
    SHA-256; GUI bridge (HarnessFile) real-DERP transfer intact; live shell
    loads 7 tabs clean (pid journal clean).

### Next actions
1. **Two-machine acceptance** (V0.1 + V0.2 together) — needs the user's 2nd
   machine: install tailcat + plugin on both, share listener addr / receiver
   addr, transfer a file both ways, test Direct-vs-DERP, reject/cancel.
2. V0.3 text transfer (same port/protocol, `op:"text"` message; Add a Send
   Text UI row + incoming text notification).

- **V0.1** backend + GUI (Quickshell bar widget) live on this machine; layout
  + Start fixed (stale-reload issue). See earlier sections.
- **V0.2 native file transfer — foundation DONE:**
  - `backend/tailcat/native.go`: framing protocol (JSON-line header + raw
    body; file/accept/reject/error/done/cancel/text) over TCP; `SendFileStream`
    / `ReceiveFileStream` with progress, accept/reject, SHA-256 verify,
    safe-name (`filepath.Base`), O_EXCL collision refusal, partial cleanup;
    `StartReceiver` (native tailcat.Server on TransferPort 42421, DERP map or
    embedded region) and `DialToken`/`SendFileToToken` (native Client).
  - `backend/cmd/nativedemo` (recv/send test+prod-shape binary).
  - `docs/file-transfer.md` (protocol + architecture + security).
  - Tests (offline): protocol edge cases over TCP loopback + full
    end-to-end through real WireGuard data plane (local DERP,
    separate processes) — all pass.
  - KEY lesson: two tailcat magicsock instances must run in SEPARATE
    processes (same-process breaks the meow handshake).
  - Deps: `github.com/tailscale/tailcat` (+ tailscale.com/gvisor) added to
    backend module; builds are slower now.

### Next actions
1. V0.2 GUI + backend CLI: `omarchy-tailcat file send/recv` subcommands;
   Manager.qml Send File / Incoming (accept/reject) + progress UI.
2. Two-machine acceptance (V0.1 + V0.2 together) — needs the user's 2nd machine.
3. V0.3 text transfer (reuse the same port/protocol).

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
- **V0.1 GUI — DONE and LIVE on this machine (ui/):**
  - Quickshell plugin `dev.omarchy.tailcat` (bar-widget), installed & enabled
    at `~/.config/omarchy/plugins/dev.omarchy.tailcat/`, placed on the bar
    (right section). Popup opens with zero errors; OCR-verified rendering
    (Dashboard/Connect/Devices/Identities/Services/Diagnostics tabs, Start/
    Restart/Ping self, listener status).
  - Files: `manifest.json`, `Panel.qml` (bar widget), `Manager.qml` (popup),
    `TailcatBridge.qml` (structured-argv JSON bridge), `Harness.qml`
    (dev-only standalone validation).
  - Backend binary bundled at `ui/bin/omarchy-tailcat`; install script
    `packaging/omarchy/install.sh`; packaging README.
- **Go toolchain: mise go@1.27.0.** Real tailcat binary at
  `/tmp/tailcat-build/tailcat`, symlinked to `~/.local/bin/tailcat` (dev
  convenience; on the shell PATH).
- **tailcat NOT installed via pacman** (Arch AUR: `tailcat`/`tailcat-bin`); the
  widget detects presence and shows install help.

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
