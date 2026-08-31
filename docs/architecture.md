# Omarchy Tailcat Manager — Architecture (Draft v0)

**Date:** 2026-08-31
**Status:** Proposed, derived from the Phase 0 analysis in `docs/tailcat-analysis.md`.
**Decision recorded before any GUI work begins.**

---

## 1. Goal

A lightweight, native-feeling **Omarchy** extension that gives users a graphical
management interface for Tailcat, so they never need to type `tailcat` CLI
commands. First milestone (V0.1) is a dashboard + connect + saved devices +
identities + diagnostics + shared services. V0.2 adds file transfer; V0.3 adds
text transfer.

Tailcat is treated strictly as upstream code we wrap — never forked, never
patched (no clear technical reason to; its CLI/library surface is sufficient).

---

## 2. Integration decision (the Phase 0 question)

**Recommendation: hybrid, phased, behind one interface.**

- **V0.1 backend = CLI adapter (`backend/tailcat/cli.go`).**
  Rationale from the analysis (§13): every V0.1 operation has a
  machine-readable CLI hook (`TAILCAT_ADDR_FILE`, `--json`, `parse`,
  `ping`, `genkey --list`). It is fast, low-coupling, and avoids linking the
  huge `tailscale.com`/gVisor tree and the `go 1.27.0` floor into our binary.
- **V0.2 backend = native Go library adapter (`backend/tailcat/native.go`).**
  File/text transfer needs streaming with progress, cancellation,
  accept/reject, and filename framing — none of which the CLI exposes
  (analysis §11). The native adapter uses `github.com/tailscale/tailcat`
  (`Client.DialTCPPort`, `Server.OnTCP`) with a **thin framing protocol**.
- Both implement the same `TailcatBackend` interface. The UI talks only to the
  interface. A runtime/config flag (`backend: "cli" | "native"`, default per
  operation) selects the implementation. Migrating an operation from CLI→native
  is a backend-only change.

Long-term direction per the brief: `GUI → our stable backend abstraction →
Tailcat Go library`. We simply get there in two steps instead of one, so V0.1
is shippable quickly and V0.2 has the streaming surface it needs.

---

## 3. System architecture

```
┌────────────────────────────────────────────────────────────┐
│  Omarchy (Quickshell) GUI                                  │
│  manifest.json  Panel.qml (bar widget)  Manager.qml (window)│
│  TailcatBridge.qml  →  runs backend subcommands / JSON     │
└───────────────────────────┬────────────────────────────────┘
                            │ JSON over process (argv arrays) / Unix socket
┌───────────────────────────▼────────────────────────────────┐
│  Go backend binary:  omarchy-tailcat                       │
│  cmd/omarchy-tailcat  (subcommands, each → JSON on stdout) │
│                                                            │
│  domain/  (devices, transfers, config, diag — no tailcat)  │
│                                                            │
│  tailcat/  TailcatBackend interface                        │
│     ├── cli.go      (V0.1: wraps `tailcat` CLI, argv only) │
│     └── native.go   (V0.2: wraps github.com/tailscale/tailcat)
│                                                            │
│  config/  atomic 0600 JSON writes (~/.config/omarchy-tailcat/)
└───────────────────────────┬────────────────────────────────┘
                            │ structured argv (never shell)
                 ┌──────────▼──────────┐
                 │  tailcat binary     │  (from PATH; required)
                 │  DERP relays        │  (bootstrap + fallback)
                 └─────────────────────┘
```

**Principles**
- The UI never knows whether the backend is CLI or native.
- The backend never shells out to a string; it always builds `exec.Cmd` with
  argument arrays (`tailcat`, `serve`, `--key=...`, `--json`, ...).
- The backend is the only component that holds Tailcat integration, config
  writes, and process supervision.

---

## 4. Backend interface (Go)

`backend/tailcat/backend.go` — the single integration chokepoint.

```go
package tailcat

// TailcatBackend is the integration boundary. The UI/domain layer depends only
// on this. Implementations: cli.go (V0.1), native.go (V0.2).
type TailcatBackend interface {
    // Presence / version
    Available() (bool, VersionInfo)          // installed? version? supported?
    ValidateToken(ctx, string) (TokenInfo, error) // trim, shape, parse, no network

    // Identity / keys (delegates to `tailcat genkey`)
    ListIdentities(ctx) ([]Identity, error)        // names + kind (server|client) + region
    CreateIdentity(ctx, IdentitySpec) (Identity, error) // name, kind, region, fixed
    DeleteIdentity(ctx, name string) error
    CurrentClientPublicKey(ctx) (string, error)    // printpub

    // Listener lifecycle
    StartListener(ctx, ListenerSpec) (ListenerStatus, error) // serve ports/services, key, allow
    StopListener(ctx) error
    RestartListener(ctx, ListenerSpec) (ListenerStatus, error)
    ListenerStatus(ctx) (ListenerStatus, error)   // running? addr? region? key? since

    // Connectivity
    Ping(ctx, target string, untilDirect bool, timeout time.Duration) (PingResult, error)
    // PingResult{Ok, Direct bool, Endpoint, DERPRegionID, DERPRegionCode, Latency}

    // Services are encoded in ListenerSpec; see §7.

    // Diagnostics
    Diagnostics(ctx) (DiagReport, error)         // version, backend, listener, relay reachability, redacted logs
}

// V0.2 additions (same interface growth, not a fork):
//   SendFile(ctx, target, path, opts) (Transfer, error)
//   Receive(port int) (Stream, error)            // accept/reject/cancel/progress
//   SendText(ctx, target, text) error
//   OnIncoming(cb IncomingHandler)               // for accept/reject UI
```

Shared domain types (`backend/tailcat/types.go`):

```go
type VersionInfo struct {
    Available bool
    Version   string
    MinOK     bool // satisfies our known-good version pin
}
type TokenInfo struct {
    Valid      bool
    IsDNSName  bool
    RegionID   int
    RegionName string
    ServerPub  string // nodekey:... (public only — never private)
    Embedded   bool   // full address (self-contained) vs region-ID form
}
type Identity struct {
    Name   string
    Kind   IdentityKind // Server | Client
    Region string       // "auto", region code/name, or custom DERP host
    IsDefault bool
}
type ListenerSpec struct {
    Services []Service // ports + named services
    Key      string    // "" => default/auto, "new" => ephemeral
    Allow    []string  // nodekey allowlist (or AllowNone)
    FilesDir string    // for `files` service (ro/rw/wo)
    FullAddr bool      // embed region (long token)
    Region   string    // pinned region if any
}
type ListenerStatus struct {
    Running  bool
    Addr     string   // tc... (redacted in logs)
    KeyInUse string   // name or "ephemeral"
    Region   string
    Services []Service
    StartedAt time.Time
}
type Service struct {
    Name      string // display name
    Kind      ServiceKind // PortForward | NoAuthSSH | Files | ExitNode
    Port      uint16 // for PortForward
    Enabled   bool
}
type PingResult struct {
    Ok       bool
    Direct   bool
    Endpoint string // ip:port when direct
    RegionID int
    RegionCode string
    RegionName string
    Latency  time.Duration
}
```

---

## 5. Manager config (devices + settings)

Location: `~/.config/omarchy-tailcat/` (manager-owned, separate from Tailcat's
own `~/.config/tailcat/`).

Files:
- `config.json` — versioned, atomic writes, `0600`:
  ```json
  {
    "version": 1,
    "devices": [
      {
        "id": "uuid-v4",
        "name": "ThinkPad X12",
        "target": "tcAAA...",          // token OR dns name
        "kind": "token",               // token | dns
        "createdAt": "2026-08-31T...",
        "lastConnectedAt": "...",
        "notes": ""
      }
    ],
    "settings": {
      "backend": "cli",                 // "cli" | "native"
      "derpmapURL": "",
      "defaultRegion": "auto",
      "allowUninstallCmd": false
    }
  }
  ```
- Atomic write policy: write `config.json.tmp` in the same dir, `fsync`, then
  `rename()` over `config.json`, `fsync` dir. On load: if the file is corrupt,
  rename to `config.json.corrupt-<ts>` and start fresh (never clobber silently,
  never lose the original). Directory created `0700`.

Devices store only what the manager needs (display + target). **Tokens are
capabilities** — stored in the manager config (0600) and **redacted** in logs
and diagnostics by default.

---

## 6. Security design (summary; details in `docs/security.md`)

1. **Process execution:** `exec.Command("tailcat", args...)` with literal
   argument arrays. No `sh -c`, no `$USER_INPUT` interpolation, no string
   concatenation into a shell. Input (token/ports/names) validated before use.
2. **Keys:** never displayed, copied automatically, or logged. Identity screens
   show names + public info only. `genkey --client` prints the *public* key
   (safe to show) — that is the allowlist identifier.
3. **Config:** `0700` dir, `0600` files, atomic same-dir writes, fsync, corrupt
   handling as in §5.
4. **Tokens:** validate shape client-side (must be `tc`+base64url or a DNS
   name), then confirm via `tailcat parse` (no network). Redact in diagnostics
   (`tcXXXX…last4`). Never log full tokens.
5. **File transfer (V0.2):** receiver chooses/confirms destination; basename
   sanitized (`filepath.Base`, reject `..`/`/`/NUL); collision → always ask
   (overwrite/rename/skip); open with `O_CREATE|O_EXCL` then optional
   overwrite; no symlink following on the receive side; size shown before
   accept; optional SHA-256 verification both sides.
6. **DNS tokens:** resolved via TXT lookup only after explicit user action in
   the UI ("Resolve DNS name"), and the resolved token is treated like a pasted
   token.
7. **No telemetry.** Diagnostics export redacts tokens/keys; nothing leaves the
   machine without explicit user choice.

---

## 7. Service model (V0.1 "Shared Services")

The listener is described by a list of `Service` entries, mapped to a
`tailcat serve` spec:

| UI concept        | Backend mapping                                  |
|-------------------|--------------------------------------------------|
| TCP port forward  | `serve <port>` → forwarded to `localhost:<port>` |
| "SSH (built-in)"  | `serve no-auth-ssh` (auth-free; tunnel = identity)|
| "SSH (system, 22)"| `serve 22` (proxy to system sshd on the server)   |
| "File share"      | `serve --files=<dir>[:ro\|rw\|wo] files`          |
| "Exit node"       | `serve exit-node` (exposed as optional; no routing UI) |
| Pipe/stdin mode   | not a GUI service; excluded from V0.1 UI          |

Restrictions enforced by the UI: port must be 1–65535 (single port or range in
advanced mode); at most one `no-auth-ssh`; `files` requires a directory; no
arbitrary shell commands — only explicit TCP services.

---

## 8. Omarchy integration (how it ships)

The Omarchy shell is **Quickshell/QML**; every current extension is a QML
plugin with a `manifest.json` plus helper scripts/binaries (see
`~/.config/omarchy/plugins/*`). We follow that convention exactly.

```
~/.config/omarchy/plugins/dev.omarchy.tailcat/          # user-owned install
├── manifest.json          # schemaVersion 1, kinds: ["bar-widget","window"]
├── Panel.qml              # bar widget (status dot + popup actions)
├── Manager.qml            # main window: dashboard/devices/connect/...
├── TailcatBridge.qml      # JSON-over-process bridge (like state.sh pattern)
└── bin/omarchy-tailcat    # Go backend binary (single static binary)
```

- **Bar widget:** shows running/idle + direct/DERP state; opens the manager
  window. Polls the backend like the `state.sh` pattern (`Quickshell.Io`).
- **Manager window:** a Quickshell `Window` (Wayland-native, Qt), keyboard
  friendly, theme-aware via `qs.Commons` `Color`/`bar` (dark-theme
  compatible), touch-friendly buttons.
- **Backend protocol:** per-command JSON-over-process for V0.1 (identical to the
  existing plugin `state.sh` model), with a Unix-socket streaming endpoint
  added in V0.2 for progress events.
- **Packaging:** `packaging/omarchy/` holds a `PKGBUILD` (Arch/Omarchy)
  providing the Go binary on PATH (or bundled in the plugin dir) + the plugin
  files; `omarchy plugin` compatible. A `omarchy`-style launcher entry
  (`omarchy launch tailcat` via `.desktop`) is included.
- **No Electron.** No separate GTK stack. Least-complex native solution =
  Quickshell plugin (matches every existing extension) + Go backend.

---

## 9. Repository structure (this project)

```
omarchy-tailcat/                       # = /home/max/项目/tailcat-manager
├── README.md
├── LICENSE                            # BSD-3-Clause (aligns with upstream + Omarchy MIT-style) — decide
├── docs/
│   ├── tailcat-analysis.md            # Phase 0 (this repo, done)
│   ├── architecture.md                # this file
│   └── security.md                    # security model & threat notes (next)
├── backend/
│   ├── go.mod                         # module dev.omarchy.tailcat/backend; go >= 1.27 (V0.2)
│   ├── cmd/omarchy-tailcat/           # main: subcommands → JSON
│   ├── tailcat/
│   │   ├── backend.go                 # TailcatBackend interface
│   │   ├── types.go                   # shared domain types
│   │   ├── cli.go                     # V0.1 CLI adapter
│   │   ├── native.go                  # V0.2 Go-library adapter
│   │   └── version.go                 # known-good CLI version pin
│   ├── domain/                        # devices, transfers, diag (no tailcat dep)
│   ├── config/                        # atomic JSON config
│   └── process/                       # supervised child process lifecycle (start/stop/restart)
├── ui/
│   ├── manifest.json
│   ├── Panel.qml
│   ├── Manager.qml
│   └── TailcatBridge.qml
├── tests/
│   ├── unit/                          # token validation, config atomicity, devices
│   └── e2e/                           # hermetic local-DERP two-endpoint tests
└── packaging/
    └── omarchy/
        ├── PKGBUILD
        └── README.md                  # install instructions (paru tailcat + plugin)
```

Deliberately **no** abstractions with no immediate use (per brief §15): no
transport abstraction, no continuity layer yet — but the `TailcatBackend`
interface and the config schema are shaped so that later transports
(Tailscale, LAN) can be added without redesign.

---

## 10. Implementation plan

### Phase 0 (now)
- [x] Clone + analyze upstream (`upstream-tailcat/` reference copy, pinned commit).
- [x] `docs/tailcat-analysis.md`.
- [ ] `docs/security.md` (threat model for tokens/keys/config/file transfer).
- [ ] Decide + record: hybrid CLI→native backend (§2). (This doc.)

### V0.1 — Core manager (CLI backend)
1. Backend skeleton: `go.mod`, `cmd/omarchy-tailcat` subcommands
   (`version`, `status`, `parse`, `identities list|create|delete|pub`,
   `serve start|stop|restart`, `ping`, `diagnostics`), all JSON-out.
2. `config/` atomic config + `domain/devices` (add/remove/rename/list) with
   unit tests (corruption, atomicity, duplicate names, token validation).
3. `process/` supervised listener lifecycle (spawn `tailcat serve` with
   `TAILCAT_ADDR_FILE`, watch, restart, clean SIGTERM + drain).
4. CLI adapter wiring: `parse` for validation, `genkey` for identities,
   `ping`/`--until-direct` for diagnostics, `--json`/addr-file for listener.
5. Unit tests for all of the above (hermetic; mock/no network where possible).
6. **Minimal connection prototype**: scripted `serve` + `ping` + `cp`
   round-trip using `TS_DEBUG_TAILCAT_LOCAL_DERP=1` (offline) to prove the
   adapter end-to-end.
7. Quickshell GUI shell: `manifest.json`, `Panel.qml` bar widget,
   `Manager.qml` dashboard/connect/devices/identities/diagnostics/services,
   `TailcatBridge.qml`.
8. Wire GUI ↔ backend. Acceptance walkthrough of the 14 V0.1 criteria.
9. Test on two Omarchy machines.

### V0.2 — File transfer (native backend)
1. Add `native.go` adapter linking `github.com/tailscale/tailcat` (requires
   Go 1.27+ toolchain and the large dep tree).
2. Thin framing protocol on a TCP stream (magic + name + size + direction;
   half-close EOF semantics; web-demo model) — reused later by text/clipboard.
3. Progress/cancel/accept-reject UI; safe destination handling (§6.5).
4. Hermetic two-endpoint transfer tests (local DERP).

### V0.3 — Text/clipboard foundation
- `SendText`/receive-with-Copy over the same stream protocol; no automatic
  clipboard sync yet.

### V1+ — evaluate transports (Tailscale, LAN) behind the same interface.

---

## 11. Testing strategy

- **Unit (no network):** token validation, DNS-vs-token detection, port
  validation, device registry CRUD, duplicate names, config corruption recovery,
  atomic write behavior, redaction helpers, service-spec mapping.
- **Backend (hermetic, local DERP):** two-endpoint `serve`+`ping`
  (DERP-only and direct), `--until-direct` success/failure, SSH no-auth shell
  round-trip, file dropbox put, CLI-not-installed, CLI failure, invalid token,
  cancelled connection, listener restart/stop.
- **GUI:** QML smoke tests (open window, render states) + manual acceptance
  checklist (the 14 + 21 criteria in the brief).
- File-transfer tests (V0.2): collision behavior, name sanitization, cancelled
  transfer, integrity (SHA-256 both sides), size display.

---

## 12. Error UX model

- Backend returns typed errors: `ErrNotInstalled`, `ErrInvalidToken`,
  `ErrConnectTimeout`, `ErrNoDirectPath`, `ErrPortInUse`, `ErrDuplicateDevice`,
  `ErrTransferCancelled`, etc., each with a `Message` (user-friendly) and
  `Detail` (raw, redacted) surfaced only behind a "Details" disclosure.
- Never show "exit code 1". Map CLI stderr to the typed error where possible.
- Example:
  > **Could not connect to ThinkPad X12.** Tailcat could not establish a
  > connection before the timeout. [Retry] [Diagnostics] [Details]
