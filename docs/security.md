# Tailcat Manager — Security Model

**Date:** 2026-08-31
**Applies to:** V0.1 (CLI backend) and V0.2+ (native backend).

## 1. Assets to protect

| Asset | Sensitivity | Where it lives | Rules |
|---|---|---|---|
| Connection tokens (`tc...`) | **High** — a token is an unguessable capability: anyone holding it can connect to a listener using that key | clipboard, our `config.json`, in-flight CLI argv/env | validate shape; **redact in logs/diagnostics** (`tc` + last 4); never log full token; copy-to-clipboard is explicit user action |
| Saved private keys (`~/.config/tailcat/keys/*.private.json`) | **Critical** — server keys grant stable addresses; anyone with the address can reach future listeners | owned by `tailcat` CLI, 0600 | **never** read/display/export/copy by our manager; identity UI shows names + public info only |
| Client identity public key (`nodekey:...`) | Low (public) — used for `--allow` allowlists | stdout of `tailcat printpub` / `genkey --client` | safe to display and copy |
| Manager config (`~/.config/omarchy-tailcat/config.json`) | High (contains device tokens) | ours, 0600 | atomic writes, corrupt-file recovery |
| SSH host key (`~/.config/tailcat/ssh/`) | Medium | owned by `tailcat` | never touched by us |
| DERP map cache (`~/.cache/tailcat/`) | Low | owned by `tailcat` | leave alone |

## 2. Process execution rules

- **Only** `exec.Command("tailcat", argv...)` with literal argument arrays.
- **Never** `sh -c`, shell interpolation, string-built commands, or passing
  user input as a flag value that could be parsed as an option.
- User inputs are validated before use:
  - token: must match `tc[0-9A-Za-z_-]{...}` (base64url, no dots) **or** be an
    explicit DNS name (resolution only after explicit UI action); confirm via
    `tailcat parse` (no network) before connecting.
  - ports: numeric 1–65535 (or validated range) only.
  - key names: `[A-Za-z0-9._-]+`, never a path separator (no
    `../`/absolute-path injection into `genkey --key`).
  - directories (`--files`): user-picked path only, existence checked; served
    dir is confined upstream by `os.Root`.
- Backend subprocesses are supervised: start with clean env (no accidental
  token env leakage), SIGTERM on stop, wait with timeout, capture stderr into a
  bounded redacted ring buffer (tokens scrubbed).

## 3. Key handling

- The manager **never** reads or displays private key material.
- `genkey --client` prints the **public** key — the only key-related output we
  surface, for building `--allow` lists.
- Identity deletion = `tailcat genkey --delete --key=<name>` (name-only, no
  path), which is irreversible; require confirmation in the UI.

## 4. Configuration integrity

- Dir `~/.config/omarchy-tailcat/` created `0700`; files written `0600`.
- Atomic write: write `config.json.tmp` in the same directory → `fsync(file)`
  → `rename(tmp, config.json)` → `fsync(dir)`.
- On load failure (corrupt JSON): move aside to
  `config.json.corrupt-<unix-ts>` and start with defaults; **never** silently
  overwrite an existing valid config with partial data; never block startup
  forever on a corrupt file (log a redacted reason + keep the backup).
- Versioned schema (`"version": 1`); migrations run explicitly and also
  atomically (write new file, then rename).

## 5. File transfer (terminal; native receiver removed 2026-09)

Transfers now run in the terminal via `tailcat recv <dir>` (write-only drop
box) and `tailcat cp <file> <addr>:` (scp-style). The GUI native receiver
(with accept/reject dialogs and O_EXCL collision handling) was removed, so the
per-transfer hardening below applied to the deleted code and is archived here
in case a GUI transfer is ever re-added behind the `TailcatBackend` interface:

- Receiver **chooses/confirms** the destination path, and sees name + size
  before accepting.
- Sanitization: `filepath.Base` on the incoming filename; reject `/`, `\`, NUL,
  `.`/`..`; truncate overlong names.
- Collision: never overwrite silently (prefer `O_CREATE|O_EXCL`; explicit
  overwrite after confirmation).
- Symlink safety: `O_NOFOLLOW`, reject resolved-path symlinks.
- Optional integrity: SHA-256 in header, verified on receive.

Current transfer surface notes:
- `tailcat recv` is write-only and scoped to the chosen directory.
- The tc… address is a capability — share privately (this section's §6 applies).
- The manager never writes into `~/.config/tailcat/` during transfers.

## 6. Tokens in logs and diagnostics

- Logging: never log full tokens. Use a `redact()` helper: keep `tc` + last 4.
- Diagnostics export (`Diagnostics(ctx)`) returns a redacted report; full logs
  are shown only behind a "Details" disclosure in the UI, still token-scrubbed.
- No telemetry; nothing is sent off-machine by the manager itself.

## 7. Network trust boundaries

- Default DERP map `https://tailcat.dev/derpmap.json` is fetched over HTTPS;
  cached under `~/.cache/tailcat/`. DERP relays are **rate-limited, no SLA, and
  Tailscale may revoke them** — the UI should surface relay status as advisory,
  never assume availability.
- The WireGuard tunnel is end-to-end encrypted; the DERP relay is a relay, not
  a plaintext observer (it sees only encrypted packets).
- `--allow` allowlists are the only way to restrict who can connect to a saved
  key. The UI should warn when serving a saved (stable-address) key without an
  allowlist.

## 8. Threats out of scope (V0.1)

- We do not build a remote-control plane, accounts, or telemetry.
- Tailcat itself is not patched or forked; security properties of the
  underlying tunnel are inherited from upstream and its DERP operators.
