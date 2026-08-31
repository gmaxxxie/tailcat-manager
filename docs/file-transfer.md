# V0.2 — Native File Transfer (Design)

**Status:** Design — implementation starts from this doc.
**Upstream basis:** `docs/tailcat-analysis.md` §11 (the web-demo raw-stream model) and
`docs/architecture.md` §2 (native Go library adapter behind `TailcatBackend`).

---

## 1. Why the native backend

The V0.1 CLI adapter cannot express a GUI file transfer:
- `tailcat cp` wraps system `scp` (no programmatic progress/cancel/accept, needs
  an `scp` binary).
- `tailcat recv` is a write-only drop box (no per-transfer UI, no accept/reject).
- Text transfer has no CLI command at all.

So V0.2 adds `backend/tailcat/native.go`, an implementation of the same
`TailcatBackend` interface backed by `github.com/tailscale/tailcat`
(`Server` + `Client`), used **for file/text transfer only** (V0.1 operations
stay on the CLI adapter). Selection is per-operation / configurable
(`settings.backend: "cli" | "native"`).

## 2. Architecture

```
GUI (Manager.qml)  ── TailcatBridge (structured argv / JSON) ──  omarchy-tailcat
                                                                    │
                                                                    ├─ serve start|stop|status   (V0.1 CLI adapter)
                                                                    ├─ file send|recv           (V0.2 NATIVE adapter)
                                                                    │
                                                                    ▼
                                              native listener process (long-running)
                                              ─  speaks the framing protocol on a
                                                 dedicated stream port (see §4)
```

- The **receiver** is a long-running native process: `omarchy-tailcat file recv
  <port> [--key=...]`. It starts a `tailcat.Server` whose `OnTCP` for the
  transfer port hands each connection to the receive handler. It reports
  inbound-transfer **events** as JSON lines on stdout and accepts
  accept/reject/abort commands on stdin (or a unix socket).
- The **sender** is a short-lived native command: `omarchy-tailcat file send
  <token> <port> <path> [--name=...]`. It dials with a `tailcat.Client`,
  speaks the protocol, and prints progress as JSON lines (or `--json` once at
  the end for simple callers).
- `tailcat`'s own encryption/NAT traversal is untouched; we only add a thin
  application layer on the stream.

## 3. Transfer port

A single dedicated, documented port carries all manager file/text traffic:
**`42421`** (unassigned IANA range). It is not proxied to localhost (native
`OnTCP` handles it directly). Text (V0.3) reuses the same port with a
different message type. Clients always dial `DialTCPPort(connBlob, 42421)`.

## 4. Framing protocol (v1)

One TCP stream, bidirectional, **JSON line header then raw body** (the
upstream web demo already uses "raw stream + app framing"; we keep framing
minimal — no big custom protocol).

### 4.1 Sender → Receiver: file offer

```
{ "v":1, "op":"file", "name":"presentation.pdf", "size":27053271,
  "sha256":"<hex, optional>", "sender":"ThinkPad X12", "mime":"" }\n
```

### 4.2 Receiver → Sender: decision (before any file bytes)

```
{ "v":1, "op":"accept" }\n
{ "v":1, "op":"reject", "reason":"user declined" }\n
{ "v":1, "op":"error", "message":"destination not writable" }\n
```

### 4.3 Data + completion

After `accept`, the sender streams **raw file bytes** and half-closes
(`CloseWrite`). The receiver writes to its chosen destination (see §5),
verifies `sha256` if offered, then replies:

```
{ "v":1, "op":"done", "sha256":"<verified hex>" }\n
{ "v":1, "op":"error", "message":"integrity mismatch" }\n
```

The sender treats the receiver's `done` (after its own EOF) as success — the
same "peer EOF confirms delivery" rule the upstream CLI uses.

### 4.4 Cancel / progress

- **Cancel:** either side sends `{ "v":1, "op":"cancel" }\n` and closes.
  The sender aborts mid-stream; the receiver deletes the partial file (unless
  the user opts to keep it).
- **Progress:** both sides know `size`; the sender reports bytes written, the
  receiver reports bytes read. The GUI renders percent + speed from those.

### 4.5 Text (V0.3, same port)

```
{ "v":1, "op":"text", "text":"<utf8>", "sender":"Home Server" }\n
```

---

## 5. Receiver-side file safety (security)

- Destination is always **chosen/confirmed by the receiver UI**; never derived
  from the sender alone.
- `filepath.Base(name)`; reject names with `/`, `\`, NUL, `.`/`..`, or >255
  bytes; strip control chars.
- Collision → the receiver UI is asked **before** any write (Overwrite /
  Rename / Reject). No silent overwrite.
- Open with `O_CREATE|O_EXCL` on first attempt; explicit overwrite re-opens
  with `O_TRUNC` after confirmation.
- `O_NOFOLLOW` on the final path where supported; never follow a symlink the
  sender could control.
- Optional `sha256` in the offer → verify on receive; mismatch = failure with
  the partial file removed (or kept only if the user opts in).

## 6. Backend interface additions

`native.go` implements the same `TailcatBackend` plus V0.2 extensions
(small, deliberate):

```go
type TransferStatus struct {
    ID         string    `json:"id"`
    Direction  string    `json:"direction"` // send | receive
    File       string    `json:"file"`
    TotalBytes int64     `json:"totalBytes"`
    SentBytes  int64     `json:"sentBytes"`
    State      string    `json:"state"`     // offered | accepted | transferring | done | cancelled | failed
    Error      string    `json:"error,omitempty"`
}

// Native-only additions (not on the V0.1 CLI adapter):
type FileTransferBackend interface {
    StartReceive(ctx, ListenerSpec) (ListenerStatus, error) // native listener w/ OnTCP(42421)
    OnIncoming(cb func(IncomingFile) error)                  // offered-file events → GUI
    Respond(id string, accept bool, dest string) error
    SendFile(ctx, target string, path string, name string) (<-chan TransferStatus, error)
    CancelTransfer(id string) error
}
```

The GUI bridge talks to the native listener process via JSON-lines stdout +
commands on stdin (mirroring the `serve` + `TAILCAT_STATUS_LOOP` pattern but
interactive).

## 7. GUI (V0.2)

- **Send File** (Devices/Connect): pick device → file chooser (path string via
  text field for v1, native dialog later) → progress bar (percent + speed +
  remaining) → Cancel.
- **Incoming** (receiver): a notification/badge + panel row: file name, size,
  sender; **[Accept / Reject]**; after accept, progress; on completion a
  "Reveal" action.

## 8. Tests (hermetic, no internet)

- Start a local DERP+STUN server (the upstream `integration.RunDERPAndSTUN`
  helper from `tailscale.com/tstest/integration`), build a `tailcfg.DERPRegion`
  pointing at it, start the native `Server` with that region, and a `Client`
  with the produced `ConnBlob`.
- Cover: offer→accept→transfer→done; reject; cancel mid-stream; collision
  (reject before write); name sanitization (`../`, NUL, absolute); SHA-256
  verify + mismatch; size display; partial-file cleanup on cancel/failure.
- The whole matrix runs on one machine, offline (like `backend/e2e/` today).

## 9. What stays CLI-backed

V0.1 dashboard/connect/devices/identities/ping/services remain on the CLI
adapter. Only `file` (and later `text`) use native. `settings.backend`
defaults to `cli`; no UI change is required when we flip a transfer to native.
