# Decisions

### 2026-09-01 — User-facing copy says "AI agent", never a tool name

Type: preference

Summary:
All user-facing copy (popup help, README, docs) must refer to the assistant
that handles advanced management as **"an AI agent"** — not "pi" or any
specific tool. The user runs several AI agents (pi, codex, claude, opencode),
so tool names must not leak into product copy.

Details:
- Applied to the slim popup's bottom line (was Chinese "交给 pi"), manifest
  descriptions, README Status/Development sections, `docs/architecture.md` §0,
  and `docs/file-transfer.md`.
- The `tailcat` skill file itself is already tool-agnostic (0 mentions of pi
  in SKILL.md); only its location is pi-specific
  (`~/.pi/agent/skills/tailcat/`). Re-locating it to a shared skills dir
  (e.g. `~/.agents/skills/`) is an open option for other agents.

Evidence:
User instruction 2026-09-01: "弹窗的说明用英文描述，而且不只是 pi，用 ai agent 即可".

Action:
When writing popup/UI/doc copy for this project, use English + "an AI agent".

Status: active

### 2026-09-01 — Simplify: slim widget (status+start/stop), management via pi skill, transfers in terminal

Type: decision

Summary:
The GUI was over-built. Split the project by surface: the top-bar widget only
shows listener status and does start/stop/restart + copy-address + self-ping;
all management (devices, identities, services, diagnostics, file transfer) moved
to pi via a `tailcat` skill that drives the `omarchy-tailcat` CLI; file transfer
runs in the terminal (`tailcat recv`/`tailcat cp`). The V0.2 native Go adapter
(`native.go`, file daemon, `file` subcommand, `cmd/nativedemo`, native e2e tests)
and the whole `tailscale.com`/gVisor dep tree were deleted — the backend binary
went from ~20MB to ~5MB and the build is fast.

Details:
- Rationale: a bar widget is the wrong surface for complex ops; the native
  library existed only to give a GUI transfer progress/accept, which the
  terminal already provides. pi is the natural surface for the rest.
- Widget (`ui/Manager.qml`): 1186 → ~190 lines. `TailcatBridge.qml` trimmed to
  status/serve/ping only. Removed `ui/HarnessManage.qml`, `ui/HarnessFile.qml`.
- Skill: `~/.agents/skills/tailcat/SKILL.md` (shared across AI agents since
  2026-09-01; formerly `~/.pi/agent/skills/tailcat/`) — CLI reference, security
  rules
  (tokens = capabilities), workflows (start/stop, share address, ping/connect,
  devices, identities, transfer, diagnostics), troubleshooting.
- Backend: `Backend` interface unchanged (it never included transfer methods);
  only the `file` dispatch was removed. All unit tests pass; `go mod tidy`
  dropped the tailscale deps.
- Docs: README, `docs/architecture.md` (§0 note), `docs/file-transfer.md`
  (rewritten as terminal guide), `docs/two-machine-test.md` (revised),
  `docs/security.md` (§5 archived).

Evidence:
The `tailcat cp`/`recv` limitations (§11 analysis) only matter for a GUI;
user confirmed file transfer via terminal and a slim popup.

Action:
Keep the widget minimal going forward; put new capabilities in the skill/CLI,
not the widget. If a GUI transfer is ever wanted again, re-add a native adapter
behind the existing `TailcatBackend` interface.

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
