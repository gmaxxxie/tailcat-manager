# File Transfer (via terminal / AI agent)

**Status:** 2026-09 — the native (GUI) transfer backend was removed. Transfers
run in the terminal, driven by an AI agent via the `tailcat` skill or directly.

## Why the native backend was removed

- The V0.1 CLI adapter cannot express a *GUI* file transfer: `tailcat cp` wraps
  system `scp` (no programmatic progress/cancel/accept), `tailcat recv` is a
  write-only drop box, and text transfer has no CLI at all.
- Those limits only matter for a **GUI**. In a terminal (an AI agent's context) the CLI
  is exactly what you want: `scp` prints its own progress, `recv` accepts
  headlessly, and errors surface on stderr. So the V0.2 native adapter
  (`native.go`, file daemon, `file` subcommand) and its huge
  `tailscale.com`/gVisor dependency tree were deleted.

## The two commands

| Direction | Command | Notes |
|---|---|---|
| Receive | `tailcat recv <目录>` | write-only drop box; prints the tc… address to share |
| Send | `tailcat cp <本地文件> <tc…地址>:` | scp-style, terminal progress; `:` = keep basename |

## Walkthrough

1. **Receiver** starts the drop box:
   ```sh
   tailcat recv ~/Downloads
   # …prints a tc… address (also see TAILCAT_ADDR_FILE / --json)
   ```
2. **Receiver** shares that tc… address with the sender (it is a capability —
   treat it as a credential, see `docs/security.md`).
3. **Sender** pushes the file:
   ```sh
   tailcat cp ./report.pdf tc…:
   ```
   Progress comes from scp; failures are on stderr and non-zero exit.

## Security notes (carried over from the old native design)

- Filenames are written under the chosen directory only; `tailcat recv` is
  write-only and does not overwrite arbitrary paths.
- The tc… address grants connectivity — do not paste it into public channels.
- Manager config (`~/.config/omarchy-tailcat/`) and tailcat keys
  (`~/.config/tailcat/keys/`, 0600) are never written by the transfer path.

## If a GUI transfer UI is ever wanted again

Re-introduce a native adapter behind the same `TailcatBackend` interface
(see `docs/architecture.md` §0 note); the old design in this file's git history
documents the framing protocol and accept/reject model.
