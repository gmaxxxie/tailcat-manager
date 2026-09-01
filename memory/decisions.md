# Decisions

### 2026-09-01 — GUI = 5 primary tabs; serve spec persisted; SSH/SOCKS backend subcommands

Type: decision

Summary:
Restructured the Manager popup into tabs Status / SSH / Files / Proxy / Manage
(1-5 keys, ←/→ switch, m Manage), added SSH + SOCKS5 proxy + exit-node + SFTP
folder-share functionality, and persisted the listener serve spec so a bare
`serve start` reuses the last services+key.

Details:
- Status tab owns the listener (start/stop/restart/ping/copy + key chips) and
  shows running services. Files tab owns receive/send + SFTP share. Proxy owns
  the SOCKS5 daemon (`socks start|stop|status`, detached `tailcat socks`, state
  in `~/.config/omarchy-tailcat/socks/`) and the exit-node service toggle.
  SSH opens `tailcat ssh` in a detected terminal (ghostty/alacritty/kitty/foot/…,
  override `OMARCHY_TAILCAT_TERMINAL`).
- Serve spec persisted to `spec.json` (tailcat package, not config, to avoid an
  import cycle); `serve spec` get/set/clear; `status`/`serve status` include
  `configured`. QML loads it on open via syncConfigured (configuredSynced flag).
- The `files` service previously broke start (no dir → serveArgv error); now the
  bridge passes `--files=DIR[:mode]` and Files tab edits the service entry.

Evidence:
2026-09-01 refactor (this session): backend tests green incl. new
socks/ssh/serve-spec tests; harness + OCR verified all 5 tabs render.

Action:
Keep the 4 operational tabs + Manage; extend tabs rather than adding new ones.
Terminal override is env-only (no config field yet) — add a Settings.Terminal
if the user wants to set it from the UI.

Status: active

---

### 2026-08-31 — Hybrid backend: CLI adapter (V0.1) → native Go library (V0.2)

Type: decision

Summary:
Use a single `TailcatBackend` interface with two implementations; ship V0.1 on a
CLI adapter of the `tailcat` binary, then add a native
`github.com/tailscale/tailcat` adapter for V0.2 file/text transfer.

Details:
- V0.1 ops (dashboard, connect, identities, ping, services) are all
  CLI-wrappable via `TAILCAT_ADDR_FILE`/`--json`/`parse`/`ping`/`genkey --list`.
  This avoids the huge `tailscale.com`+gVisor dep tree and the `go 1.27.0`
  floor until streaming is truly needed.
- V0.2 file/text transfer needs progress, cancel, accept/reject, filename
  framing — none exposed by the CLI (`cp`/`recv` are dropbox/scp oriented).
  Use the native library with a thin framing protocol over a TCP stream
  (upstream web-demo model), NOT a heavy custom protocol.
- UI depends only on the interface; migrating an operation CLI→native is a
  backend-only change.
- Never fork/patch Tailcat.

Evidence:
`docs/tailcat-analysis.md` §11, §13, §14; `docs/architecture.md` §2.

Action:
Implement `backend/tailcat/backend.go` (interface) + `cli.go` first; add
`native.go` at V0.2. Keep output parsing defensive; version-pin the CLI.

Status: active

---

### 2026-08-31 — Omarchy integration = Quickshell plugin + Go backend binary

Type: decision

Summary:
Ship as a Quickshell/QML plugin (`manifest.json` + `Panel.qml` + `Manager.qml`)
following the existing Omarchy plugin convention, driving a Go backend binary
that emits JSON (process-per-command for V0.1, Unix-socket streaming for V0.2).

Details:
- Every current Omarchy extension is QML + manifest.json + helper scripts
  (`~/.config/omarchy/plugins/*`); the shell is Quickshell. No Electron, no
  separate GTK stack.
- Backend = one static Go binary (`omarchy-tailcat`) doing config/process
  supervision/JSON; QML is UI-only.
- Packaging via `packaging/omarchy/PKGBUILD` (Arch/Omarchy); tailcat itself
  comes from AUR (`tailcat`/`tailcat-bin`).

Evidence:
Inspection of `~/.config/omarchy/plugins/` and `/usr/share/omarchy/shell/`;
`docs/architecture.md` §8.

Action:
Follow manifest schemaVersion 1 + entryPoints conventions; poll backend like
the existing `state.sh` pattern.

Status: active

---

### 2026-08-31 — Manager config location/schema

Type: decision

Summary:
Manager-owned config at `~/.config/omarchy-tailcat/config.json`, versioned
schema `{"version":1,"devices":[...],"settings":{...}}`, 0700 dir / 0600 file,
same-dir atomic writes (tmp + fsync + rename + dir fsync), corrupt-file
move-aside recovery.

Details:
- Separate from Tailcat's own `~/.config/tailcat/` (keys, ssh host keys) which
  we never write.
- Devices store only display data + target token/DNS name (tokens are
  capabilities — redact in logs).
- Settings include `backend: "cli"|"native"` selector.

Evidence:
`docs/architecture.md` §5; `docs/security.md` §4.

Action:
Implement in `backend/config/` with unit tests (atomicity, corruption,
duplicates).

Status: active

---

### 2026-08-31 — Rejected: pure-CLI backend for file transfer

Type: decision (rejected alternative)

Summary:
Do NOT implement V0.2 file transfer by wrapping `tailcat cp`/`recv` or system
`scp`; they expose no programmatic progress, cancellation, accept/reject, or
filename framing, and require system `ssh`/`scp` binaries.

Status: superseded by the hybrid decision above.

---

### 2026-08-31 — Rejected: exit-node / subnet-routing UI in V0.1

Type: decision (rejected alternative)

Summary:
Expose `serve exit-node` only as an optional named service. Do not build any
subnet-routing/192.168.x.x configuration UI — out of project scope.

Status: active (constraint, not a feature).
