# Project State

## Tailcat Manager for Omarchy (`/home/max/项目/tailcat-manager`)

### Status: V0.1 + V0.2 done & live; **v0.2.0 released**; next: two-machine acceptance + V0.3 text

> **IMPORTANT — second worktree / direction (2026-09-01):** the user's current
> direction lives in a SEPARATE repo **`/home/max/tailcat-manager`** (not this
> one): a **slim popup** branch (master `ee799b3`, ahead of origin) that shows
> only listener status + start/stop/restart + copy-address + self-ping, and
> defers devices/identities/file transfer to **an AI agent in the terminal**
> (`tailcat` skill + `omarchy-tailcat`/`tailcat` CLIs). This repo
> (`/home/max/项目/tailcat-manager`) holds the earlier full 7-tab Home/Manage
> V0.1+V0.2 build. When the user says "the popup" they mean the slim one.
> Follow the latest user direction (slim + AI-agent-managed) over the V0.2
> feature-plan recorded below; keep both repos in sync for backend/installer
> only where they share code.
> **UPDATE 2026-09-01 later:** slim direction is now official — GitHub master
> was force-pushed to the slim version; **v0.3.0** released (slim ~5MB static
> backend, x86_64+arm64); v0.2.0 release re-titled "superseded". The `tailcat`
> skill moved from `~/.pi/agent/skills/tailcat/` to the shared
> `~/.agents/skills/tailcat/`. This full-feature repo is kept as history.
> **UPDATE 2026-09-01 (final): REVERTED — the full GUI version is the product.**
> The slim version was a successful test (two-machine transfer verified in the
> terminal, AI-agent-managed, copy fix) but the user prefers the **full GUI
> popup + native file transfer**. GitHub master is being force-pushed back to
> this full build; the slim work is archived on the `slim` branch. The copy
> fix (`execDetached wl-copy --`, not createQmlObject) and the English+
> "AI agent" copy preference apply to the full build too.

- **Release v0.2.0 (2026-09-01) — DONE, published & verified:**
  - `quick-install.sh` bumped `VERSION=v0.2.0`; README got a V0.2 file-transfer
    section + refreshed "Next up".
  - Static prebuilt binaries (CGO_ENABLED=0, runs on any glibc/musl) uploaded
    as `omarchy-tailcat-x86_64-linux` + `omarchy-tailcat-arm64-linux` (arm64
    is cross-built; first time shipping arm64).
  - Verified end-to-end: raw.githubusercontent CDN serves the new script
    (VERSION=v0.2.0), asset downloads + runs (version/file subcommands), and a
    real install via `curl|bash` took the **prebuilt** path (no source fallback).
  - GOTCHA: `gh release upload file#label` sets a display LABEL, not the asset
    name — the asset keeps the source filename. To ship `omarchy-tailcat-*
    -linux` the local file must be named that. See lessons.
  - Dev-env repair: `~/.local/bin/tailcat` was a symlink into `/tmp` and went
    DANGLING after a `/tmp` cleanup (widget showed "tailcat is not installed",
    `available:false`). Rebuilt upstream tailcat directly to
    `~/.local/bin/tailcat` as a real file; `version` → `available:true`;
    serve start/status/stop verified clean.

- **Overall test + UI optimization pass (2026-09-01) — DONE, pushed:**
  - Full backend suite green (unit + hermetic e2e incl. real-DERP file transfer,
    SHA-verified); all QML harnesses clean (Harness/HarnessManage/HarnessPanel/
    HarnessFile) and now self-quit (their quit Timers were missing `running: true`).
  - Fixed: `root.fmtBytes` was called in Manager.qml but only defined in the
    bridge — would break RECEIVE offer size + SEND progress text the moment a
    transfer ran; added the function to Manager.
  - Fixed: `heroMeta()` gated on the file receiver, so a running listener alone
    showed "READY"; now listener→"RUNNING·key", receiver-only→"RECEIVING".
  - Fixed: backend `file recv-stop`/`recv-status` left a stale `addr` in state,
    so the UI kept showing a dead "Share: … + Copy" row after stopping the
    receiver; now addr is cleared. Regression test `TestFileRecvStopClearsAddr`.
  - Fixed: RECEIVE Share-row `visible` used `addr !== ""`; backend omits addr
    (undefined) when stopped, and `undefined !== ""` is true → row showed
    empty; now `!!addr` (also kills the "Unable to assign [undefined] to bool"
    QML warning).
  - Improved: identity chips (Key: Ephemeral + saved server keys) rendered on
    Home LISTENER so you can pick a listener identity and return to ephemeral
    (`identityChips()` was defined but never rendered); device chips now show
    ALL saved devices in a wrapping Flow and the opaque "Use device" button was
    removed; recv-dir placeholder + waiting line show the effective dir
    (default ~/Downloads); stale `lastError` clears at the start of every
    backend call; bar shows `󰞀 ⇩` while only the receiver is running.

- **Native file picker for SEND/RECEIVE paths (2026-09-01) — DONE, pushed:**
  - SEND FILE now has a "Browse…" button (and keyboard `b`) that opens the
    XDG Desktop Portal file chooser (`ui/bin/tc-filepicker`, a gdbus→portal
    wrapper: `OpenFile` + `dbus-monitor` on the request path; prints the chosen
    local path, empty on cancel). The recv-dir field also got a folder
    Browse… (portal `OpenFile` with `directory:true`). Text entry still works.
  - No zenity/kdialog/yad on this box, so portal via gdbus was the right call;
    GTK portal backend confirmed (Hyprland). Scripted-test hooks:
    `TC_PICKER_ECHO_REQ=1` echoes the request path for simulated responses.
  - Verified: native dialog opens; response parsing (uint32/int32, %-decode,
    cancel) tested with simulated `org.freedesktop.portal.Request.Response`;
    QML bridge `pick()` wiring tested with a fake picker script; harness clean.
  - Gotchas hit: Hyprland 0.56 `hyprctl dispatch` uses a Lua dispatcher
    (`hl.dsp.*`) and rejects classic `focuswindow address:…` syntax; `pkill -f`
    self-match trap hit again (kill in a separate command / use `[f]` bracket).

- **Widget-loading regression (2026-08-31 late) — FIXED:** the cleanup commit
  (82686b9) left an orphaned debug `Timer {` header, swallowing all subsequent
  root handlers → QML parse error (Expected token `}'` at EOF) → Manager
  unavailable → the whole plugin widget vanished from the bar (reported as
  "icons gone"). Fixed by removing the orphan block; verified via harness
  (zero errors), shell restart (no plugin-failed line), pixel/OCR checks
  (bar glyph + hero icon render, popup shows Home/LISTENER/RECEIVE/SEND).

- **UI structure (2026-08-31)** — Manager.qml reworked from 7 tabs to a
  **Home ⇄ Manage** model:
  - Home: command panel with the three core ops on one screen — LISTENER
    (status/start·stop·restart/ping), RECEIVE FILE (start·stop, share address+
    copy, incoming Accept/Reject + progress, done line), SEND FILE (device
    chips + target/path + progress + cancel), plus recent-result line and a
    shortcut cheat-sheet.
  - Manage: Devices / Identities / Services / Diagnostics sub-pages, each with
    a usage-guide line; top nav Home|Manage + a **?** expandable help block
    (both flow walkthroughs + shortcuts).
  - Tabs 7→2; keyboard remapped (s/r/j/k/a/d/t/f/Enter/m/?/Esc; Manage 1-4).
  - Verified: harness clean, live shell clean, OCR shows Home renders.

### Next actions

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

### Next actions (current, 2026-09-01)
1. **Two-machine acceptance** (V0.1 + V0.2 together) — the only remaining gate
   before V0.1+V0.2 is "done for real". Ready to run: `docs/two-machine-test.md`
   checklist, v0.2.0 installer, this box's tailcat restored (available:true).
   Needs the user's 2nd machine: install tailcat + manager on both, share
   listener addr / receiver addr, transfer a file both ways, test
   Direct-vs-DERP, reject/cancel.
2. **V0.3 text transfer** — protocol already reserves `op:"text"`
   (`docs/file-transfer.md` §4.5) but nothing wired: backend message path +
   `file send-text/recv-text` CLI, then a Send Text UI row + incoming text
   notification in Manager.qml.
3. License decision (BSD-3-Clause vs MIT) — deferred to next release.
4. Packaging: `packaging/omarchy/PKGBUILD` referenced in decisions but not yet
   written (only dev install.sh + README). Do if/when distributing via
   AUR/Omarchy repo.
5. README + quick-install.sh are current for v0.2.0 (done this session).

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
- **LISTENER button row investigation (2026-08-31):** user asked "where's the
  Start button". Root cause: six unbounded Rows with `width: parent.width - N`
  children caused endless QML polish() loops that could collapse/misplace
  sibling rows. Fixed by giving each Row an explicit width. Also learned the
  reliable UI verification path: the harness window and popup were being
  covered by the terminal (grim screenshots showed terminal echo, not the
  popup) — verified via right-edge crop of the popup (popup hangs over the
  bar; its right half is unobstructed) and by `journalctl grep polish`
  (4620 -> 0).
- **Published to GitHub (2026-08-31):** `github.com/gmaxxxie/tailcat-manager`
  (public, branch master). One-line installer:
  `curl -sL https://raw.githubusercontent.com/gmaxxxie/tailcat-manager/master/quick-install.sh | bash`
  — downloads prebuilt backend from Release `v0.1.0` (`omarchy-tailcat-<arch>-linux`,
  no Go needed), falls back to source build, installs backend to ~/.local/bin,
  and on Omarchy installs+enables the bar widget. Verified end-to-end locally
  (prebuilt path + fallback). NOTE: raw.githubusercontent.com CDN-cached old
  script versions for a few minutes after push — wait ~2 min before testing a
  freshly pushed script, and verify md5 vs local.
