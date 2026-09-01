# Lessons Learned

### 2026-09-01 — KeyboardPanel's `bar` is injected AFTER the bar loads; don't read position at onCompleted

Type: lesson

Summary:
`qs.Ui.KeyboardPanel` binds `bar` only once the real Bar instance is injected
(which happens after the shell mounts the bar). In a plugin's
`Component.onCompleted` the panel's `bar` is still null and `cardOrigin`
falls back to `(margin, margin)` — so reading bar/position/cardOrigin there
gives the WRONG answer (and `centerOnBar` appears broken when it isn't). The
bar resolves to the real Bar later; `barPos` then reads "top" and
`cardOrigin` computes the centered position correctly.

Details:
- Symptom: popup looked off-center; `panel.cardOrigin` printed QPointF(5,5)
  and `panel.bar`=null at onCompleted, so I suspected centerOnBar failed.
- Reality: 4s later `panel.bar`=Bar instance, `barPos`=top,
  `cardOrigin`=QPointF(395,35) = screenW/2 - contentWidth/2 (centered). OCR
  confirmed the card is centered; the "off-center" was my color-based bbox
  detecting a different window's dark pixels.
- Fixed the popup by setting `centerOnBar: true` in the plugin Panel.qml
  (correct), and measuring position by OCR text coordinates, not bg-color bbox.

Evidence:
2026-09-01 popup-centering pass (this session).

Action:
To verify popup position, use OCR coordinates of known text, never a
background-color bounding box; and read KeyboardPanel state only after open.

Status: active

---

### 2026-09-01 — Tailcat address short form: the tail is fixed, use the random middle

Type: lesson

Summary:
Tailcat tokens are `tco2FwW` + base64url(CBOR) where the FIRST chars and the
LAST ~6 chars are fixed (the DERP region tail `…FpGQEw`), and only the middle
is the per-key randomness. Shortening as `tc…` + last-4 shows the SAME string
for every address — an ephemeral restart changes the full address but the UI
still reads `tc…GQEw`, so users think "the address didn't change". Fix: show
`tc…` + 7 chars from the random middle + `…` + last 4.

Details:
- User: "picked Ephemeral → Restart, address didn't change" — it HAD changed
  (process cmdline showed --key=new, full addr differed), only the short form
  was misleading.
- Verify key/address changes from the full addr or process cmdline, not the UI
  short form.

Evidence:
2026-09-01 address-shortening fix (this session).

Action:
When displaying tailcat addresses, derive the distinguishing part from the
random middle; never from the fixed tail.

Status: active

---

### 2026-09-01 — Verify listener security from the process cmdline, not the popup

Type: lesson

Summary:
The popup's allow-list/services are in-memory UI state until a listener
restart persists them. The actual gate is the running `tailcat serve` process's
`--allow`/`serve …` args — a popup showing "Fixed address · 1 allowed device"
can be a lie if that key was never restarted into the process. To answer "can
any device connect?", read `/proc/<pid>/cmdline` of the listener (pid from
`serve status`): presence of `--allow=nodekey:…` = whitelist enforced; a bare
`serve all` with no `--allow` = anyone with the address, all ports.

Details:
- Found this machine's listener running `--key=default serve all` with NO
  --allow while the popup showed 1 allowed device (in-memory only) → open to
  everyone. Fixed by persisting the device key to spec.json + `serve restart`;
  the new process cmdline then carries `--allow=nodekey:8f18…`.
- The popup key's short form (nodekey:8f..ec73ae65) is this machine's own
  client-default — OCR had misread the tail (aeb5 vs ae65).

Evidence:
2026-09-01 security review (this session).

Action:
When asked whether a machine is locked down, trust the listener cmdline
(--allow/--allow=none), and always restart after adding allow-list keys.

Status: active

---

### 2026-09-01 — Hide config blocks that depend on a master switch; show why

Type: lesson

Summary:
When a settings section only makes sense while a master toggle is on (e.g.
WHO CAN CONNECT only matters while Allow connections is on), hide the whole
block when the switch is off and show a one-line explanation instead — don't
leave a confusing status like "open to anyone" visible while nothing is open.

Details:
- This Device: WHO CAN CONNECT is wrapped in `Column { visible:
  listener.running === true }`; when off, a Text explains "Connections are off —
  nobody can reach this machine…". RECEIVE FILES stays visible (independent).
- Pattern: wrap dependent UI in a Column and bind its visible to the switch;
  give the off-state an explanatory Text, not silence.

Evidence:
2026-09-01 This-Device clarity pass; verified both on (block shown) and off
(prompt + hidden) states on the live shell.

Action:
Use conditional Columns for switch-dependent config; always explain the off
state in words.

Status: active

---

### 2026-09-01 — Omarchy `Toggle` elides its label at 240px; stretch to full width

Type: lesson

Summary:
The kit's `Toggle.qml` has `implicitWidth: Style.space(240)` and renders its
label with `elide: Text.ElideRight` (no wrap), so any label longer than ~240px
shows as `Label na…`. In a popup/panel, every Toggle must be stretched to the
column width (`width: parent.width` inside a Column, `Layout.fillWidth: true`
inside a RowLayout) or its label gets silently truncated.

Details:
- Symptom: "Allow connections from other devices" → "Allow connections fr..".
- Fix: added `width: parent.width` / `Layout.fillWidth: true` to every Toggle;
  split the Receive-files row so the toggle has its own line instead of sharing
  a row with a text field + button.

Evidence:
2026-09-01 device-hub pass (this session); OCR-verified labels now render whole.

Action:
Any Toggle added in the future must set an explicit full-width width/fillWidth.

Status: active

---

### 2026-09-01 — Go json `omitempty` does NOT skip zero `time.Time`; QML mis-parses it as ancient

Type: lesson

Summary:
`json:"lastConnectedAt,omitempty"` on a `time.Time` still serializes the zero
value (`0001-01-01T00:00:00Z`), because omitempty only skips scalar zero
values, not structs. QML's `Date.parse` then turned it into a ~2000-year-old
timestamp (UI showed "seen 739860d"). Fix: when rendering, omit zero timestamps
by building the output map explicitly (`devicesOut`), and defensively return
"" from the formatter when `Date.parse` is NaN.

Details:
- Symptom: Devices list showed "seen 739860d" for a never-connected device.
- Fix: `devicesOut()` maps devices to plain maps and only sets
  `lastConnectedAt` when `!IsZero()`; `fmtAgo` bails on NaN.

Evidence:
2026-09-01 device-hub refactor (this session).

Action:
Never rely on `omitempty` to hide a zero time.Time when serializing for the
QML UI; drop the field explicitly when it is zero.

Status: active

---

### 2026-09-01 — Omarchy plugin hot-reload is unreliable; clear qmlcache + restart shell to load new QML

Type: lesson

Summary:
`packaging/omarchy/install.sh`'s `omarchy-shell -q shell rescanPlugins` can fail
silently (-q swallows errors) and Quickshell's QML disk cache
(`~/.cache/quickshell/qmlcache/`) holds stale compiled components, so a local
plugin update showed the OLD popup even though the files on disk were new. Fix:
`rm -rf ~/.cache/quickshell/qmlcache`, then restart the shell (`pkill -f
"quickshell -n -p /usr/share/omarchy/shell"`; the `omarchy-launch-shell`
supervisor auto-relaunches it). Verify via the shell log
(`/run/user/1000/quickshell/by-id/*/log.qslog` shows "Local plugin changed,
reloading") and by OCR-ing the popup after `omarchy-shell shell summon
<pluginId> '{}'`.

Details:
- After copying new files + rescan, the popup still showed the old slim UI
  (hero "STOPPED", ALLOW-LIST/TO-A-PEER sections) for many minutes — stale
  QML cache at 21:08 vs new files at 21:59.
- `omarchy-shell -q shell hide <id> '{}'` with an extra `'{}'` arg fails
  silently (hide takes only the id) → popup stays open and state seems to
  drift; use the exact signature.
- The live popup persists QML state across hide/summon (same Manager
  instance), so don't read "wrong tab" into a bug.
- Screenshots: launch quickshell with `setsid … </dev/null >log 2>&1 &
disown`; find the popup by scanning for its bg color (13,19,25) bbox, then
  grim that bbox. Never `pkill -f "quickshell -p"` (matches the live shell).

Evidence:
2026-09-01 (this session): local popup stayed old after install; fixed with
cache clear + shell restart; new 5-tab popup + ALLOW LIST block verified by OCR.

Action:
After any QML edit that must appear locally: copy files, clear qmlcache,
restart the shell. For a release, rely on the installer's fresh shell start
rather than hot-reload.

Status: active

---

### 2026-09-01 — Omarchy `Toggle` uses `label` (not `text`); test harness screenshots need full detachment

Type: lesson

Summary:
(1) The Omarchy kit's `Toggle.qml` exposes `label`/`description`, not `text`
— using `text:` on a Toggle fails QML load with "Cannot assign to non-existent
property \"text\"". (2) To screenshot a Quickshell harness: launch with
`setsid quickshell -p … </dev/null >log 2>&1 & disown` (backgrounding without
full detach makes the bash tool hang on the inherited output pipe), then use
`hyprctl clients -j` for the window geometry and `grim -g "x,y wxh"`.
`pkill -f "quickshell -p"` is dangerous — it can match the user's live shell
(`quickshell -n -p /usr/share/omarchy/shell`); target the harness file name
instead (e.g. `pkill -f LongHarness`).

Details:
- Manager.qml Toggle rows must use `label:` (+ optional `description:`);
  `ToggleSwitch` is the bare switch inside a row.
- The bash tool returned "no output" for any command after a non-detached
  backgrounded quickshell; `setsid … </dev/null >/log 2>&1 & disown` fixed it.

Evidence:
2026-09-01 tab refactor (this session): first harness load failed at
`Manager.qml[1224:15]` on a Toggle `text:`; screenshot workflow developed.

Action:
Always use `label:` on Toggle. When capturing UI, fully detach the harness
process and never pkill the live shell pattern.

Status: active

---

### 2026-09-01 — `gh release upload file#label` is a display label, NOT a rename; ship the right filename

Type: lesson

Summary:
`gh release upload vX file#newname` sets a *display label* on the asset; the
actual GitHub asset **name is the source filename**. `quick-install.sh`
downloads by asset name (`omarchy-tailcat-<arch>-linux`), so a label-only
upload silently breaks the prebuilt path (installer falls back to a source
build). Fix: name the local file exactly what the asset must be and upload
that; verify with `gh api .../releases/tags/<tag> --jq '.assets[].name'`.

Details:
- `gh release create` with bare paths also keeps source filenames.
- Also: `gh release view --json assets` can show stale names right after
  delete+upload; trust `gh api` for the ground truth.

Evidence:
2026-09-01 v0.2.0 publish (assets came out as `tc-static`/`tc-arm64` twice).

Action:
When publishing releases, cp the binary to the exact target asset name before
`gh release upload`, then confirm via `gh api` before telling the user it's
live.

Status: active

### 2026-09-01 — Dev binaries must NOT live in /tmp behind a symlink (cleanup → dangling)

Type: lesson

Summary:
The dev `tailcat` was built to `/tmp/tailcat-build/tailcat` with
`~/.local/bin/tailcat` as a symlink. Any `/tmp` cleanup (reboot, tmpreaper)
leaves the symlink dangling; the manager then reports `available:false`
("tailcat is not installed") even though the user installed it — a confusing
false negative. Install dev tools as **real files** under `~/.local/bin` (or
`~/.local/share/...`), never a symlink into /tmp.

Details:
- Symptom: `omarchy-tailcat version` → `{"available":false,...}`; `which
  tailcat` finds the symlink but executing it gives "No such file or directory".
- Fix: `rm ~/.local/bin/tailcat && cd upstream-tailcat && go build -o
  ~/.local/bin/tailcat ./cmd/tailcat`; `available:true` restored.

Evidence:
2026-09-01 — found while preparing the two-machine acceptance after a /tmp
cleanup wiped the build dir.

Action:
Keep `tailcat` as a real binary in `~/.local/bin`. If a build dir in /tmp is
needed, copy the result out, don't symlink.

Status: active

### 2026-09-01 — XDG Desktop Portal file chooser via gdbus + dbus-monitor

Type: lesson

Summary:
When no zenity/kdialog/yad is installed, the native file/folder picker on
Wayland/Hyprland is the XDG Desktop Portal (`org.freedesktop.portal.FileChooser
.OpenFile`, `directory:true` for folders) over the session bus. Call it with
`gdbus call`, take the returned Request object path, then `dbus-monitor` on
`type='signal',interface='org.freedesktop.portal.Request',member='Response',path=<req>`
to get the async result. Response code is the first integer line after the
header (portal emits `uint32`, gdbus may emit `int32` — extract with
`grep -oE '[0-9]+' | tail -1` because `int32` itself contains digits); chosen
files arrive as `string "file://…"` URIs that need percent-decoding.

Details:
- `file://` URIs may contain %20 etc.; decode with python3 `urllib.parse.unquote`.
- A debug hook (`TC_PICKER_ECHO_REQ=1`) lets scripts simulate the Response for
  automated testing without GUI interaction.
- This machine's Hyprland 0.56 `hyprctl dispatch` uses a Lua dispatcher
  (`hl.dsp.*`) and rejects the classic `focuswindow address:…` syntax.

Evidence:
`ui/bin/tc-filepicker`; scripted end-to-end tests on 2026-09-01.

Action:
Reuse `ui/bin/tc-filepicker` (`file`/`dir`) as the native picker for any
path input; keep the text field as a fallback.

Status: active

---

### 2026-09-01 — QML: `!== ""` is a trap for backend-omitted fields; function lookup is lexical

Type: lesson

Summary:
Two QML bugs from the overall-test pass: (1) a backend JSON field with
`omitempty` is `undefined` in QML, and `undefined !== ""` is `true`, so a
`visible: x.addr !== ""` check still shows an empty row — use truthiness
(`!!x.addr`), which also avoids "Unable to assign [undefined] to bool".
(2) `root.fmtBytes(...)` fails at runtime if the function is only defined on
the bridge, not the Manager — QML has no cross-object fallback for method
lookup; every helper used in a component's bindings must live in that
component (or be reached through the explicit `bridge.` object).

Details:
- Stale-share-address bug: backend cleared `addr` but left it in state.json;
  fixed backend (`fileRecvStop`/`fileRecvStatus` clear `st.Addr`) AND made the
  UI visibility a truthiness check.
- heroMeta gated on the file receiver made a running listener show "READY".

Evidence:
`backend/cmd/omarchy-tailcat/file.go`, `ui/Manager.qml`; OCR + harness runs
on 2026-09-01.

Action:
Prefer `!!`/`Boolean()` for `visible:` checks on fields that can be omitted;
keep formatting helpers (fmtBytes etc.) in the same QML component that calls
`root.<fn>()`.

Status: active

---

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

---

### 2026-08-31 — Unbounded Row + `width: parent.width - N` child = polish() loop, UI elements silently vanish

Type: lesson

Summary:
A `Row` (or any unbounded positioner) whose child sets `width: parent.width - N`
creates a layout feedback loop: the Row's implicitWidth depends on the child's
width, which depends on the Row's width. Qt then logs an endless
`possible QQuickItem::polish() loop` / `Row called polish() inside
updatePolish() of Row` warning spam, starves layout computation, and can leave
sibling rows (e.g. the LISTENER Start/Restart/Ping button row) collapsed to
0px or misrendered — reported by the user as "the start button is gone".

Details:
- Fix pattern: give the Row an explicit `width: parent.width` (the Column chain
  above it has a defined width, so this is not a cycle), or use anchors on a
  parent with defined size.
- The identical wrong pattern appeared in Six places (RECEIVE share row, SEND
  target row, rename row, connect row, create-identity row, add-service row);
  all were `Row { ... TextField/Text { width: parent.width - N } }`.
- Rows using `anchors.fill: parent` (device/identity/service list rows) are
  fine — no loop.
- Detection: `journalctl --user | grep polish` — 4620 warnings before fix, 0
  after. The live shell keeps running through it, so it hides serious layout
  breakage.
- Keep the `0 warnings` journal bar: any polish/ReferenceError warning is a
  signal to stop and fix, because the user-visible effect can be "a row of
  buttons disappeared" while the popup otherwise looks fine.

Action:
Grep `width: parent.width - ` inside any Row/RowLayout-less positioner and fix
before rendering; treat polish-loop warnings as blocking bugs.

Status: active
