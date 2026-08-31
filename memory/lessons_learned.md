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
