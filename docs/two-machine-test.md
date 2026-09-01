# Two-Machine Acceptance Test (revised 2026-09)

Goal: prove Tailcat works **between two machines** — listener + connectivity
(backend `omarchy-tailcat`), and file transfer in the **terminal**
(`tailcat recv` / `tailcat cp`), both directions, Direct and DERP, plus the
edge cases that matter.

Reference: `docs/architecture.md` §0 (2026-09 simplification),
`docs/file-transfer.md`, `docs/security.md`.

---

## 0. Machine setup (both machines)

### 0.1 Install Tailcat CLI (required on both)

Arch Linux / Omarchy:

```sh
paru -S tailcat        # or: tailcat-bin
tailcat --help         # sanity: prints help
```

Dev builds (if AUR is unavailable): clone `github.com/tailscale/tailcat`,
`go build -o ~/.local/bin/tailcat ./cmd/tailcat`.

Required: `tailcat` **on PATH**, `~/.config/tailcat/keys/` writable (keys are
created on demand).

### 0.2 Install the manager (widget) — Omarchy machines

```sh
git clone <repo> ~/tailcat-manager
~/tailcat-manager/packaging/omarchy/install.sh   # builds backend, installs plugin, enables, places on bar
omarchy restart shell                             # plugin edits are not hot-reloaded
```

Verify on each box: `omarchy-tailcat version` prints JSON with
`available: true`; the bar shows the 🐈 widget; the popup opens (status +
Start/Stop).

### 0.3 CLI-only fallback (non-Omarchy second machine)

The widget is optional. A bare Linux box needs only:

```sh
go build -o omarchy-tailcat ./cmd/omarchy-tailcat   # from backend/
# tailcat on PATH
```

### 0.4 Network expectations

- Both machines reach the public DERP map (`https://tailcat.dev/derpmap.json`)
  over HTTPS/443 for the relay path; or run a LAN DERP.
- NAT traversal needs outbound UDP (STUN, WireGuard) for **direct**; if the
  network blocks it, transfers still work over DERP (slower).
- Test both same-LAN (easy direct) and, if available, across different networks
  (forces DERP / hole punching).

---

## 1. Listener + connectivity

On **machine A**:

1. Open the widget popup → **Start**. Status turns `● Running`; the address
   line shows `Addr tc…`. Press **Copy** to grab the full token.
2. From a terminal: `omarchy-tailcat serve status` → JSON with `running: true`
   and the same `addr`.

On **machine B**:

3. `omarchy-tailcat validate <A的地址>` → decodes the token locally (no net).
4. `omarchy-tailcat ping <A的地址> --until-direct --timeout=30s` →
   succeeds direct (same LAN) or DERP (cross-network).

Acceptance:
- [ ] A starts/stops via the widget; state survives backend restarts
- [ ] B pings A's address (Direct or DERP) with a visible result
- [ ] Stop listener on A → B ping fails cleanly (no crash, clear error)
- [ ] Restart A listener → B ping works again with the SAME address
      (address is stable per identity key)

> Address stability: the address derives from the identity key. First start
> uses an ephemeral key — save an identity first
> (`omarchy-tailcat identities create home --region=<常用区域>`) and start with
> it (`omarchy-tailcat serve start --key=home`) to keep the address across
> reboots.

---

## 2. File transfer via terminal (both directions)

### 2.1 A receives → B sends

On **A** (receiver):

```sh
tailcat recv ~/Downloads      # write-only drop box; prints a tc… address
```

On **B** (sender):

```sh
tailcat cp ./report.pdf <A的地址>:
```

Verify on A:

```sh
sha256sum ~/Downloads/report.pdf    # compare with the source on B
```

### 2.2 B receives → A sends (reverse direction)

Swap roles; each box is both receiver and sender (independent keys/processes).

### 2.3 Interop

Same two commands on either box — no GUI dependency. The widget is not
involved in transfers at all.

Acceptance:
- [ ] B→A over DERP: SHA-256 identical
- [ ] B→A direct (same LAN): verify again
- [ ] File names with spaces / non-ASCII survive; large file (≥100 MB) OK

---

## 3. Edge cases to prove (choose per run)

| Case | How | Expected |
|---|---|---|
| **Wrong token** | B sends to a bogus token | B fails fast with a clear parse/connect error; A unaffected |
| **Receiver stopped** | B sends while A's `recv` is not running | B times out/fails cleanly |
| **Identity reuse** | A uses a saved identity for the listener | Address stable across restarts; token reusable |

Record results in `memory/project_state.md` (new section) after the run.

---

## 4. Direct vs DERP — how to tell

- `omarchy-tailcat ping <addr>` → reports `direct` or `DERP(<region>)`.
- `omarchy-tailcat ping <addr> --until-direct` → succeeds only when direct works.
- `tailcat` stderr shows STUN / magicsock path selection.

Same-LAN machines should go direct after the initial handshake. Cross-network
start DERP, then switch to direct if hole punching succeeds.

If DERP path fails (timeout, "derp-N does not know about peer"):
- Both machines must use **short tokens** (region-referencing), never
  full-address/embedded tokens (known upstream bug — see memory
  `lessons_learned.md`).
- Check `tailcat` version on both sides is recent.

---

## 5. Troubleshooting quick reference

| Symptom | Check |
|---|---|
| Widget shows "Tailcat not installed" | `tailcat` on PATH; restart shell |
| Popup won't open / disappears | `journalctl --user` for `Plugin widget dev.omarchy.tailcat failed`; QML syntax (missing `}`) |
| Listener addr empty after Start | `omarchy-tailcat serve status`; journal of the detached serve process |
| Ping fails: "does not know about peer" | short token only; DERP region-1 restore bug |
| Ping/transfer times out | receiver not running / wrong token / firewall (443, UDP) |
| Widget shows stale state | after plugin changes, `omarchy restart shell` (NO hot reload) |
| Keys collide / permission | `~/.config/tailcat/keys/` must be 0600, owned by the user |

---

## 6. After the run

- Update `memory/project_state.md`: mark two-machine acceptance done, note
  which cases passed, any failures + fixes.
- Update `memory/lessons_learned.md` with anything new.
- Commit the doc + memory.
