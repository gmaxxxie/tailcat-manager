# Two-Machine Acceptance Test (V0.1 + V0.2)

Goal: prove Tailcat Manager works **between two machines** — listener
(V0.1) and native file transfer (V0.2), both directions, Direct and DERP,
plus reject/cancel/overwrite edge cases.

Reference: `docs/architecture.md` §10 (V0.1 step 9), `docs/file-transfer.md`,
`memory/project_state.md` (Next actions 1).

---

## 0. Machine setup (both machines)

### 0.1 Install Tailcat CLI (required on both)

Arch Linux / Omarchy:

```sh
paru -S tailcat        # or: tailcat-bin
tailcat --help         # sanity: prints help
```

Dev builds (if AUR is unavailable):

```sh
git clone https://github.com/tailscale/tailcat
cd tailcat && go build -o /usr/local/bin/tailcat ./cmd/tailcat
```

Required: `tailcat` **on PATH**, `~/.config/tailcat/keys/` writable (the
widget/bridge creates keys on demand).

### 0.2 Install the manager (GUI) — Omarchy machines

Clone the repo + run the dev install script on EACH machine:

```sh
git clone <repo> ~/tailcat-manager
~/tailcat-manager/packaging/omarchy/install.sh   # builds backend, installs plugin, enables, places on bar
# then: omarchy restart shell   (plugin edits are not hot-reloaded)
```

Verify on each box: `omarchy-tailcat version` prints JSON with `available:
true`; the bar shows the 🐈 widget; the manager popup opens (click it).

### 0.3 CLI-only fallback (non-Omarchy second machine)

The GUI is optional for testing. A bare Linux box needs only:

```sh
go build -o omarchy-tailcat ./cmd/omarchy-tailcat   # from backend/
# tailcat on PATH
export PATH=$HOME/.local/bin:$PATH
```

Every step below has a CLI equivalent, so a CLI-only second machine works.

### 0.4 Network expectations

- Both machines reach the public DERP map (`https://tailcat.dev/derpmap.json`)
  over HTTPS/443 for the relay path; or use one of the machines as a LAN DERP.
- NAT traversal needs outbound UDP (STUN, WireGuard) for **direct**; if the
  network blocks it, transfers still work over DERP (slower).
- Test both same-LAN (easy direct) and, if available, across different networks
  (forces DERP / hole punching).

---

## 1. V0.1 — Listener + connectivity

On **machine A** (call it `A`):

1. Open the manager → **LISTENER** → **Start**.
2. Status turns `● Running`; an address line appears (`Addr tc…`). Note it —
   or press **Copy** in the hero.
3. From a terminal: `omarchy-tailcat serve status` → JSON with `running: true`
   and the same `addr`.

On **machine B** (`B`):

4. Manager → **Manage → Devices → Save device** → paste A's address → Save.
5. Select the device, press **Ping** (Devices page).
   - Expected: a result line. If ping succeeds over DERP it shows
     `DERP(<region>)`; once NAT traversal kicks in it shows `direct`.
6. Manual: `omarchy-tailcat ping <addr>` on B.

Acceptance:
- [ ] A starts/stops listener via GUI; state survives backend restarts
- [ ] B pings A's address (Direct or DERP) with a visible result
- [ ] Stop listener on A → B ping fails cleanly (no crash, clear error)
- [ ] Restart A listener → B ping works again with the SAME address
      (address is stable per key; device record keeps working)

> Address stability: the listener address is derived from the identity key.
> On first start it uses an ephemeral key — **save an identity first**
> (Manage → Identities → create, e.g. `home`) and start LISTENER with that
> key (`serve start <port> --key=home` via CLI, or the GUI identity picker)
> to keep the address across reboots/re-starts.

---

## 2. V0.2 — File transfer (both directions)

### 2.1 A receives → B sends (GUI)

On **A**:

1. Manager → **RECEIVE FILE** → **Start receiving** (optionally set a recv
   dir, default `~/Downloads`).
2. A "Share:" line appears with a short token (`tc…`). Press **Copy** — this
   token is what the sender dials. It is **short form** (region-referencing).
3. Status shows `● Receiving · Waiting for incoming…`.

On **B**:

4. Manager → **SEND FILE** → paste A's token into Target (or pick a saved
   device) → browse/fill the file path → **Send**.
5. Back on **A**: an incoming offer appears (file name, size, sender) →
   **Accept** (destination defaults to the recv dir).
6. A shows progress (percent); B shows progress (percent) too.
7. On completion A shows a "done" line; verify content:

```sh
# on A, in the recv dir:
sha256sum <file>          # compare with the source on B:
# on B:
sha256sum <original>
```

Acceptance:
- [ ] B→A over DERP: progress both sides, SHA-256 identical
- [ ] B→A direct (same LAN): progress + verify again
- [ ] GUI survives a receiver restart: stop receiving on A, start again —
      the token changes (ephemeral), B must use the NEW token
- [ ] CLI-equivalent path works too (see §2.3)

### 2.2 B receives → A sends (reverse direction)

Repeat §2.1 with roles swapped. This proves each box can be receiver AND
sender (separate processes, keys independent).

CLI equivalent on the CLI-only machine:

```sh
# receiver role (long-running):
omarchy-tailcat file recv-start --dir=/tmp/inbox
omarchy-tailcat file recv-status          # prints addr + pending
# sender role (one-shot):
omarchy-tailcat file send <token> <path>  # emits progress + done JSON lines
```

### 2.3 Interop: GUI on A, CLI on B

Great for the second machine without a GUI:

```sh
# B → A: B sends via CLI
omarchy-tailcat file send "$(paste A's token)" /home/b/something.txt

# A → B: B receives via CLI, A sends via GUI
omarchy-tailcat file recv-start --dir=/tmp/inbox   # on B, note its token
# on A GUI: SEND FILE target = B's token
```

Acceptance:
- [ ] CLI sender → GUI receiver (accept in GUI)
- [ ] GUI sender → CLI receiver (auto-accept? — CLI receiver may
      auto-accept to a dir; GUI shows pending, CLI `recv-respond <id> accept`)
- [ ] File names with spaces / non-ASCII survive; large file (≥100 MB) OK

---

## 3. Edge cases to prove (choose per run)

| Case | How | Expected |
|---|---|---|
| **Reject** | B sends; A presses **Reject** | B gets a clean failure; no file written |
| **Cancel (sender)** | B starts sending a big file; B presses **Cancel** | Both sides stop; A removes partial file |
| **Cancel (receiver)** | same, but A cancels | same |
| **Overwrite / collision** | A already has a file with the same name; B sends again | GUI asks before writing; no silent overwrite (O_EXCL first) |
| **Wrong token** | B sends to a bogus token | B fails fast with a clear parse/connect error; A unaffected |
| **Not running** | B sends while A's receiver is stopped | B times out/fails cleanly; A's GUI unchanged |
| **Identity reuse** | A uses a saved identity for receiver | Address stable across restarts; token can be reused |

Record results in `memory/project_state.md` (new section) after the run.

---

## 4. Direct vs DERP — how to tell

- **GUI:** ping result / transfer result lines show `direct` or `DERP(<code>)`.
- **CLI:**
  ```sh
  omarchy-tailcat ping <addr> --until-direct   # succeeds only when direct works
  omarchy-tailcat ping <addr>                  # reports direct/DERP
  ```
- **Logs:** the native receiver/sender log peer path selection
  (magicsock "derp-N" vs "direct"); `tailcat` stderr shows STUN results.

Same-LAN machines should go direct after the initial handshake. Cross-network
start DERP, then switch to direct if hole punching succeeds.

If DERP path fails (timeout, "derp-N does not know about peer"):
- Both machines must use **short tokens** (region-referencing), never
  full-address/embedded tokens (known upstream bug — see memory
  `lessons_learned.md`).
- Check `tailcat` version on both sides is recent (2-endpoint token parity).

---

## 5. Troubleshooting quick reference

| Symptom | Check |
|---|---|
| Widget shows "Tailcat not installed" | `tailcat` on PATH; restart shell |
| Popup won't open / disappears | `journalctl --user` for `Plugin widget dev.omarchy.tailcat failed`; QML syntax (missing `}`) |
| Buttons/rows missing | `journalctl --user \| grep polish` — layout loop; give Rows explicit widths |
| Listener addr empty after Start | `omarchy-tailcat serve status`; journal of detached serve process |
| Send fails: "does not know about peer" | short token only; DERP region 1 restore bug |
| Send times out | receiver not running / wrong token / firewall (443, UDP) |
| Incoming shown but Accept does nothing | shell reload issue: after plugin changes, `omarchy restart shell` (NO hot reload) |
| Keys collide / permission | `~/.config/tailcat/keys/` must be 0600, owned by the user |

---

## 6. After the run

- Update `memory/project_state.md`: mark two-machine acceptance done,
  note which cases passed, any failures + fixes.
- Update `memory/lessons_learned.md` with anything new (e.g. LAN-DERP setup,
  NAT quirks).
- Commit the doc + memory.