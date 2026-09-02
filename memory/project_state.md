# Project State

## Tailcat Manager for Omarchy (`/home/max/tailcat-manager`)

### Status: **PAUSED (2026-09-02) — tailcat itself is immature; local install removed, source kept for future research**

On 2026-09-02 the user paused the whole project because upstream Tailcat is
not mature enough. Local runtime was removed; source/R&D remains. Details:

- **GitHub backup (2026-09-02):** the local slim line (master @ f47b02f) was
  fast-forwarded to the remote **`slim`** branch (`13ce219..f47b02f`) — 18
  commits incl. WIP SSH-server allow-list and the archived agent skill
  (`docs/tailcat-agent-skill.md`). `master` on GitHub is **NOT** this line.
- **Two diverged lines of work exist:** local `/home/max/tailcat-manager` =
  slim v0.3.0 line (→ GitHub `slim`); `/home/max/项目/tailcat-manager` = full
  GUI line, in sync with GitHub **`master`** (84bd240, incl. device-hub,
  allow-list, 5-tab popup, SOCKS5/exit-node/SFTP). Both folders kept as R&D.
- **Locally removed (2026-09-02):** all `tailcat --json serve …` processes;
  `~/.local/bin/{tailcat,omarchy-tailcat}`; plugin
  `~/.config/omarchy/plugins/dev.omarchy.tailcat/` (full-GUI version, incl.
  bin/{omarchy-tailcat,tc-filepicker}); agent skill `~/.agents/skills/tailcat/`
  (content archived to `docs/tailcat-agent-skill.md`); runtime configs
  `~/.config/tailcat/` + `~/.config/omarchy-tailcat/`; cache
  `~/.cache/tailcat`; tmp build artifacts. No autostart/rc/systemd refs.
- **To resume:** restore `~/.agents/skills/tailcat/SKILL.md` (from
  `docs/tailcat-agent-skill.md`), rebuild `omarchy-tailcat` from `backend/`,
  reinstall the plugin + `tailcat` CLI (AUR), regenerate keys.

### Prior status — SIMPLIFIED (2026-09-01) — widget = status+start/stop; management = AI agent skill; transfers = terminal; **v0.3.0 released**

The project was deliberately de-complexified by splitting by surface:

- **Top-bar widget** = listener status + Start/Stop/Restart + copy-address +
  self-ping only. `ui/Manager.qml` went from **1186 → ~190 lines**;
  `TailcatBridge.qml` trimmed to status/serve/ping. Devices/identities/
  services/diagnostics/file-transfer pages were removed from the GUI.
- **AI-agent skill `tailcat`** (`~/.agents/skills/tailcat/SKILL.md`, shared —
  moved out of `~/.pi/agent/skills/` on 2026-09-01 so any AI agent can use it)
  drives the `omarchy-tailcat` CLI for everything else: devices, identities,
  shared services, diagnostics, connect/ping. User asks an AI agent
  "帮我管理 tailcat". User-facing copy says **"an AI agent"**, never a tool name.
- **File transfer in the terminal**: `tailcat recv <dir>` (receive) and
  `tailcat cp <file> <addr>:` (send). The **V0.2 native Go adapter was
  removed entirely** — `native.go`, `cmd/nativedemo`, the `file` subcommand +
  recv daemon, native e2e tests, and the `tailscale.com`/gVisor dep tree.
  Backend binary ~20MB → **~5MB**; build is fast; all unit tests pass.
- **v0.3.0 released 2026-09-01** (slim backend, static x86_64+arm64 assets,
  `quick-install.sh` → v0.3.0). GitHub master = slim version (force-pushed).
  v0.2.0 release re-titled "superseded"; v0.1.0 kept as-is. NOTE: master was
  later force-pushed to the full-GUI line again (see PAUSED status above).
- Installed binary updated at `~/.local/bin/omarchy-tailcat` (removed 2026-09-02).

### Next actions (all on hold — project PAUSED 2026-09-02)
1. ~~Restore `tailcat` binary~~ **DONE** (rebuilt to `~/.local/bin/tailcat` as a
   real file on 2026-09-01; `available:true`). Removed again on 2026-09-02.
2. ~~Install the slim plugin to the live shell~~ **DONE** (synced to
   `~/.config/omarchy/plugins/dev.omarchy.tailcat/` + `omarchy restart shell`,
   loaded clean). Plugin removed again on 2026-09-02.
3. **Two-machine acceptance** (revised `docs/two-machine-test.md`): listener
   + terminal file transfer both ways, Direct vs DERP — deferred to resume.
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
- Which line to treat as canonical on resume: GitHub `master` (full GUI,
  `/home/max/项目/tailcat-manager`) vs `slim` (slim v0.3.0,
  `/home/max/tailcat-manager`). Decided implicitly 2026-09-01 (full GUI won
  on master) but worth re-confirming when work resumes.
