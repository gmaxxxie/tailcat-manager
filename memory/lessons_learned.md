# Lessons Learned

### 2026-08-31 — Tailcat CLI is far more machine-readable than expected

Type: lesson

Summary:
The `tailcat` CLI ships explicit machine hooks — `TAILCAT_ADDR_FILE` (server
writes its blob to a file), `--json` (server prints `{"listenAddr":...}`),
`parse` (token → JSON, no network), a regex-friendly `ping` line — that make a
CLI adapter low-risk for V0.1, contradicting the initial assumption that
"stdout parsing" would be painful.

Details:
- Server address should be read from `TAILCAT_ADDR_FILE`/`--json`, not the
  human `# 🐈 Server listening...` stderr line.
- Default no-arg mode is a one-shot stdout pipe that exits after one
  connection; persistent listeners need `serve <ports|services>`.
- Errors always exit 1 (no exit-code taxonomy); infer meaning from the known
  subcommand + stderr phase.

Evidence:
`upstream-tailcat/cmd/tailcat/tailcat.go`; `docs/tailcat-analysis.md` §3.

Action:
Keep defensive parsing; don't over-engineer a parser. Use `parse` for token
validation before any network operation.

Status: active

---

### 2026-08-31 — QML layout rules that must not be mixed (caused the "版面乱")

Type: lesson

Summary:
The Manager popup's layout was rebuilt twice for "版面乱". Root causes and the
strict rules that fixed it:

- ColumnLayout children must NEVER also use `anchors.fill` (layout engine and
  anchors fight; content scrambles). Use Layout.fillWidth/fillHeight only.
- Row/Column positioner children must never use Layout.* (`Item {
  Layout.fillWidth: true }` inside a Row is invalid); size them with `width:`.
- Don't give a Flickable `Layout.fillHeight` inside a page where other rows
  must stay visible (it eats all remaining space and pushes them out); instead
  wrap the WHOLE page in one Flickable (contentHeight = inner Column
  implicitHeight) so tall content scrolls and short content sits naturally.
- Content area = a plain `Item` with fillWidth+fillHeight+clip; each page is a
  Flickable anchored inside it.
- Findings come from 0-warnings live-shell journal (the broken version logged
  layout/anchor warnings every load).

Action:
Follow these rules in every Quickshell panel; validate with the harness and
journal before declaring a layout done.

Status: active

---

### 2026-08-31 — Embedded (full-address) tailcat tokens break DERP routing; use short tokens

Type: lesson

Summary:
Tailcat tokens that EMBED the DERP region (the "full address" form, and what
`tailcat.Server.ConnBlob()` produces) fail to connect over a non-1 DERP region:
`ParseConnBlob` restores the elided RegionID as 1, so the client thinks the
server is on DERP region 1 while the server is actually on e.g. 304 → the
meow is routed to the wrong region and the handshake times out
("derp-1 does not know about peer …", removed route). SHORT tokens (RegionID
reference) work because the client fetches the DERP map and uses the real ID.

Details:
- Local-DERP tests passed with embedded tokens only because the local region
  happens to be ID 1.
- Real-DERP native transfer failed until the receiver emitted a short token
  (`ConnInfo{ServerPublic, ServerDiscoPublic, RegionID}.ConnBlob()` built from
  the key the Server runs with).
- The upstream CLI's own `serve --full-address` is also broken for region != 1;
  its default short form is the reliable path.

Evidence:
`backend/tailcat/native.go` StartReceiver (short-token construction); e2e
passes locally and over real DERP after the fix.

Action:
Always emit region-ID-referencing tokens, never embedded regions, until
upstream fixes the restore logic.

Status: active

---

### 2026-08-31 — Shell pkill self-match trap

Type: lesson

Summary:
`pkill -f "pattern"` matches the CURRENT shell when the pattern text appears in
its own command line, silently killing the script (no output). Use the
classic `[f]ile` bracket trick so the pattern doesn't match itself.

Status: active

---

### 2026-08-31 — Tailcat native endpoints must run in separate processes

Type: lesson

Summary:
Two `tailcat` magicsock instances (a native Server and a Client) in the SAME
process cannot establish a tunnel: the client's magicsock logs "derp-N does
not know about peer" and removes the route, so the meow handshake times out.
Run the receiver and sender as SEPARATE processes (which is also the correct
product architecture).

Details:
- Symptom: `Ping`/`DialTCPPort` context deadline exceeded; client logs
  `derp-1 does not know about peer [X], removing route` even though the server
  logs `derp-1 connected`.
- The upstream e2e tests always run the two ends as separate CLI processes;
  in-process dual magicsock is untested upstream and breaks.
- Fix in tests: exec a small helper binary (`cmd/nativedemo`) for each end
  against a local DERP map (integration.RunDERPAndSTUN + httptest serving the
  map JSON, the upstream CLI-test pattern).

Evidence:
`backend/e2e/native_test.go` (TestNativeEndToEndThroughDERP) vs the earlier
in-process debug attempt.

Action:
Always validate native transfers via separate processes.

Status: active

---

### 2026-08-31 — File/text transfer needs the native library, not the CLI

Type: lesson

Summary:
Tailcat's file features (`recv`/`cp`/`ls`) are SFTP/dropbox/scp-oriented with
no GUI-facing progress, cancel, accept/reject, or filename-over-wire; text
transfer exists only as a raw stream in the browser demo. Any GUI file/text
transfer therefore requires the native Go library + a thin framing layer.

Evidence:
`tailcat_files.go`, `tailcat_sftp.go`, `web/app.js`; `docs/tailcat-analysis.md` §11.

Action:
Plan V0.2 as native backend; reuse the raw-TCP-stream + half-close model, not a
heavy protocol.

Status: active

---

### 2026-08-31 — Hermetic offline e2e testing pattern for the backend

Type: lesson

Summary:
Set `TS_DEBUG_TAILCAT_LOCAL_DERP=1` + `--derpmap-url=none` on a real tailcat
binary to run fully offline two-endpoint tests (the upstream Homebrew test
trick). TAILCAT_ADDR_FILE gives the server's blob deterministically.

Details:
- The dev DERP embeds a NEW local DERP node (with an ephemeral port) in the
  token every run, so full tokens differ across runs even for a saved key.
  Address stability must be asserted on the SERVER PUBLIC KEY (nodekey via
  `tailcat parse`), not the whole token.
- Always isolate `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `HOME` in e2e tests;
  genkey/ssh-host-key write to real `~/.config/tailcat` otherwise. Backend
  passes os.Environ() to children, so t.Setenv propagates.
- Tests must not leave saved keys in the real tailcat keys dir.

Evidence:
`backend/e2e/prototype_test.go`; `upstream-tailcat/cmd/tailcat/pipe_test.go`.

Action:
Keep the hermetic e2e; reuse the pattern for V0.2 file-transfer tests.

Status: active

---

### 2026-08-31 — `tailcat genkey --region=list` is a listing mode, not a region

Type: lesson

Summary:
Passing `--region=list` to genkey prints the region list and exits 0 WITHOUT
creating a key, so a wrapper must reject it explicitly rather than treat it as
an identity region.

Status: active

---

### 2026-08-31 — CLI backend must parse defensively (genkey client output)

Type: lesson

Summary:
`tailcat genkey --client` writes a `# wrote file ...` note to stderr before the
`nodekey:` public key on stdout; combined-output wrappers must scan all lines
for the key, not take the first line.

Status: active

---

### 2026-08-31 — Omarchy shell disables file watching: plugin edits need a shell restart

Type: lesson

Summary:
The running omarchy-shell process has `QS_DISABLE_FILE_WATCHER=1`, so editing
plugin files under `~/.config/omarchy/plugins/` does NOT reliably hot-reload.
After copying changed plugin files you must `omarchy restart shell` to load
them; otherwise the shell silently runs a stale cached component and you debug
against dead code (a "Start button does nothing" bug was exactly this).

Details:
- Symptoms of stale load: journal shows `Manager.qml[72]`/`[76]` errors whose
  line numbers don't match the current file (line 72 is `}`, line 76 is a
  console.log in the new file but `refresh of undefined` in the old).
- `omarchy-shell shell rescanPlugins` re-discovers new plugin folders but does
  NOT necessarily reload changed QML in an existing plugin.
- QML `console.log` in the live shell goes to `journalctl --user _PID=<shell>`
  (stdout of the shell process), not to log.qslog.
- Validate QML locally first with the harness (`quickshell -p ui/Harness.qml`
  + module symlinks) before touching the live shell.

Evidence:
`journalctl --user` for omarchy-shell pids 1303 vs 59194 vs 62236.

Action:
After any plugin file change: (1) harness-validate, (2) copy, (3)
`omarchy restart shell`, (4) check journal for the NEW pid.

Status: active

---

### 2026-08-31 — Passing a child id into a KeyboardPanel content component works

Type: lesson

Summary:
A Manager declared inside a `KeyboardPanel` in Panel.qml CAN receive a
sibling id (`bridge: tcBridge`) — the earlier dead-Start bug was not the id
mechanism but the stale-load issue above (the shell was running the older
`bridge: root.bridge`/`bridge: bridge` versions). After a real reload,
`bridge` is correctly defined.

Status: active

---

### 2026-08-31 — Quickshell/QML gotchas for Omarchy plugins

Type: lesson

Summary:
Specific QML rules that bit while building the Tailcat Manager widget; they
apply to any Omarchy plugin work.

Details:
- `Keys {}` as a child object is invalid; use attached `Keys.onPressed:` on the
  root Item (bare-name child form fails with "Keys is only available via
  attached properties").
- Bare property names do NOT resolve from nested child objects; only
  `root.`-prefixed names and ids are in scope. Always use `root.x` in the
  render tree (matches how omarchy's own widgets write `root.` everywhere).
- A required property named the same as an id passed to it self-references
  (`bridge: bridge` ⇒ undefined). Name the id differently (`tcBridge`).
- The bar object exposes `foreground`/`barForeground`/`urgent`/`fontFamily`
  but NOT `accent` — use `Color.accent` (single source from theme).
- `anchors.fill` is rejected on direct children of Row/Column; wrap in a
  Rectangle/Item and put the MouseArea as a sibling.
- Quickshell resolves `qs.Commons`/`qs.Ui` from the config dir; standalone
  validation needs a harness dir symlinking those modules + plugin files
  (recipe in `ui/README.md`).
- The shell hot-reloads plugin files under ~/.config/omarchy/plugins/ on save;
  `omarchy-shell shell rescanPlugins` re-discovers new plugin folders.
- `omarchy-shell shell summon <id> '{}'` opens a bar-widget popup — a great
  scripted way to exercise the popup without clicking.

Evidence:
`ui/Manager.qml`, `ui/Panel.qml`, `ui/Harness.qml`, shell logs.

Action:
Follow these conventions for any future Omarchy QML; validate with the harness
before touching the live shell.

Status: active

---

### 2026-08-31 — A brace-leaving cleanup commit can kill the whole widget silently

Type: lesson

Summary:
Removing a debug block's last lines (`onTriggered` + closing `}`) but leaving
the object's opening lines (`Timer { interval/repeat/running`) dangling turns
every subsequent root `onOpenedChanged:` handler and all render code into a
nested child of that object, ending in an unbalanced brace and a total QML
parse failure ("Expected token `}'" at EOF). Manager became unavailable, the
Plugin widget failed to load, and the ENTIRE bar widget vanished — the user
reported it as "icons gone".

Details:
- Symptom path: journal shows `Plugin widget dev.omarchy.tailcat failed: Type
  Manager unavailable` + `Manager.qml:1185:2: Expected token '}'`.
- The failing file had 295 `{` vs 294 `}` (find: strip strings/comments, count
  braces). Matching the same line numbers in a known-good history commit
  (`git show 9487a77:ui/Manager.qml`) shows the intended clean structure.
- Rendering still "worked" at the previous commit; the breakage came from the
  LAST cleanup commit, which deleted only the tail of a debug Timer block.
- Fix: delete the orphaned block head entirely and re-validate: harness load
  (zero errors), `omarchy restart shell`, journal grep for the plugin-failed
  line, then pixel/OCR verify (grim + tesseract + accent-pixel scan).

Action:
After ANY cleanup/edit commit of QML, run the harness validation and check
brace balance before declaring done. "Icons missing" from a whole widget is a
parse-error smoke signal, not a font problem.

Status: active
