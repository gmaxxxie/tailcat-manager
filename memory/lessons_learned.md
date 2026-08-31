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
