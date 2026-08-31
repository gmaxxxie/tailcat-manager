# Tailcat Technical Analysis (Phase 0)

**Date:** 2026-08-31
**Upstream analyzed:** `github.com/tailscale/tailcat` @ commit `4d50a34f315d593d03c31f12a20ba8d163cbf321` (2026-08-30), v0.1.0-era source.
**Scope:** Source-level analysis of the upstream repository only. No code was written against it yet.

> This document is the technical spike required before choosing the integration
> implementation for the Omarchy Tailcat Manager. Everything below is derived
> from reading the upstream source, not from the project brief. Where the brief
> disagrees with the source, the source wins (see §16).

---

## 1. Repository layout (what exists upstream)

```
tailcat/
├── README.md                    # usage docs; "Tailscale without Tailscale"
├── go.mod                       # module github.com/tailscale/tailcat, go 1.27.0
├── build-tags.txt / build-tags.md   # ts_omit_* tags for smaller release binaries
├── tailcat.go                   # core library: Server, Client, ConnBlob, locoBackend
├── tailcat_files.go             # FileService, FileServeMode, SSHOptions types
├── tailcat_sftp.go              # rooted SFTP server (os.Root) for file services
├── tailcat_ssh.go               # auth-free SSH server (gliderssh) + host keys
├── tailcat_ssh_{unix,windows}.go# platform command execution for SSH sessions
├── wire.go                      # CBOR wire types behind ConnBlob
├── disco.go                     # Meow/Meowed ping packets
├── pickregion.go                # PickBestRegion (netcheck latency probe)
├── readme.go                    # embeds README for `tailcat readme`
├── cmd/tailcat/                 # the CLI (single main)
│   ├── tailcat.go               # command tree, server(), client modes, genkey
│   ├── ssh.go, cp.go, ls.go     # SSH/scp/SFTP client modes
│   ├── *_test.go                # unit + hermetic end-to-end tests
├── cmd/tailcat-web/, web/, webdemo/   # browser (js/wasm) demo + hosting
└── internal/buildtags/          # release build-tag computation
```

Note: `tailcat.go` in the repo **root** is the **Go library**. `cmd/tailcat/tailcat.go`
is the **CLI**. Do not confuse the two.

---

## 2. What Tailcat actually is

- A point-to-point, control-plane-free network pipe: `netcat` over Tailscale's
  **data plane** (userspace WireGuard + `magicsock` NAT traversal + DERP relay),
  with **no Tailscale account/control plane**, no root, no routing/DNS changes.
- One side runs a **server** (listener) and produces a **connection token**
  (`ConnBlob`). The other side uses that token to connect. All traffic is
  encrypted end-to-end with WireGuard; the initial bootstrap rides DERP and
  upgrades to direct UDP when NAT traversal succeeds.
- The whole network stack runs **in userspace** (gVisor `netstack` + userspace
  WireGuard engine), so there is no kernel state to manage.
- DERP relays are used for rendezvous + fallback. Default map:
  `https://tailcat.dev/derpmap.json` (rate-limited, no SLA). Custom DERP servers
  are supported by baking their hostname(s) into the token.

---

## 3. CLI capability matrix (current)

Global flags (`cmd/tailcat/tailcat.go`): `--serve`, `--key`, `--verbose`,
`--json` (server only), `--derpmap-url`. `serve`-only: `--allow`, `--full-address`,
`--files`.

| Command / mode | Flags | Behavior | Machine-readable hooks |
|---|---|---|---|
| *(no args)* | `--serve`, `--key`, `--json` | **One-shot stdout pipe**: accepts ONE connection on any port, writes it to stdout, then exits | `--json` → `{"listenAddr": ...}` on stdout; `TAILCAT_ADDR_FILE` env → writes blob to file (or `tcp:` host) |
| `serve [ports,services...]` | `--serve`, `--key`, `--allow`, `--full-address`, `--files`, `--json` | Persistent listener proxying served ports to `localhost:<port>`; named services: `all`, `exit-node`, `no-auth-ssh`, `files` | same as above |
| `ping [--until-direct] [--timeout=D] <addrblob>` | | Connectivity + path probe | prints `pong in <ms> via DERP(<code>)` or `via <ip:port>`; exit 1 if `--until-direct` fails |
| `parse <addrblob>` | | Decode token to JSON (no network) | JSON on stdout |
| `resolve <addrblob>` | | Expand short token → self-contained (embedded DERP) | plain token on stdout |
| `genkey --key=<name> [--client] [--force] [--list] [--delete] [--region=] [--fixed-region] [--embed-derp-map]` | | Key management | `--list` → key names, one per line; create → token on stdout; `--client` → `nodekey:...` public key on stdout |
| `printpub` | | Print public key of the client key that would be used | `nodekey:...` on stdout |
| `socks [--listen=ADDR:PORT] [addrblob] [cmd...]` | | SOCKS5 proxy over the tunnel; optional child command | prints proxy address to stderr/log |
| `recv [dir]` | | Receive files into a **write-only drop box** (shorthand for `serve --files=<dir>:wo files`) | addr blob via normal server hooks |
| `ssh [-p P] [user@]addrblob [cmd...]` | | Execs system `ssh` with a ProxyCommand that pipes through tailcat | n/a (ssh TTY) |
| `cp [-r] [-p] [-P P] src... <addrblob>:dst` | | Execs system `scp` through tailcat | n/a (scp progress) |
| `ls [-l] <addrblob>[:path]` | | Native SFTP listing (no ssh/scp binary) | text |
| `version` / `--version` | | Version string | plain text |
| `readme` | | Prints embedded README | n/a |

**Environment variables (undocumented in help):**
- `TAILCAT_ADDR_FILE=<path|tcp:addr>` — server writes its ConnBlob to a file
  (0600) or sends it to a TCP address. **This is the single most important hook
  for a CLI wrapper** — it decouples the server's address from stdout parsing.
- `TAILCAT_STATUS_LOOP=1` — server logs `status = <JSON ipnstate.Status>` to
  stderr every 5s. Useful for live diagnostics in a wrapper.
- `TS_DEBUG_TAILCAT_LOCAL_DERP=1` — server starts a **localhost DERP+STUN**
  server and embeds it in the token. This makes the whole stack testable
  **offline/hermetically** (used by upstream's own tests and the Homebrew
  formula). We should reuse it for integration tests.
- `TAILCAT_ADDR_FILE` also feeds the client when it's a server; no separate client file hook.

**Output contract for CLI wrapping:**
- Server address: prefer `TAILCAT_ADDR_FILE` (atomic-ish file write) or `--json`.
  The human line `# 🐈 Server listening with ...` goes to **stderr**.
- `parse` gives full JSON (public key, region) — the best token validator.
- `ping` line is regex-friendly: `^pong in (\S+) via (\S+)$`; direct path is a
  bare `ip:port`, DERP is `DERP(<code>)`.
- All errors are `log.Fatalf` → **exit code 1**; help → exit 0. There is **no
  exit-code taxonomy** beyond 0/1.

**Version:** `go 1.27.0` (bleeding edge). Official binaries are static Linux
(tar.gz, .deb, .rpm) for amd64/arm64/armv7 + Windows zip. Arch AUR has
`tailcat` and `tailcat-bin`. **Tailcat is not currently installed on the
target machine** — the manager must detect presence and guide install.

---

## 4. Public Go API relevant to us

Library root package `github.com/tailscale/tailcat` (all unstable by the
project's own statement, §15).

**Core types**
- `ConnBlob string` — the `tc`-prefixed token. `ParseConnBlob(cb) (ConnInfo, error)`
  (validates + restores elided fields); `ParseConnBlobRaw(cb) (any, error)` (raw
  CBOR form, for JSON display). `ConnInfo.ConnBlob()` re-serializes.
- `ConnInfo{ServerPublic NodePublic, ServerDiscoPublic DiscoPublic, Region []*tailcfg.DERPRegion, RegionID tailcfg.DERPRegionID}`.
- `PrivateKey{Private key.NodePrivate, Public ConnInfo}` — what `genkey` persists
  to disk. `NewPrivateKey() *PrivateKey`.
- `NodePublic`/`DiscoPublic` wrappers; `DiscoPublicForNode(k) DiscoPublic`.
- `DERPMapURL string`, `DERPMapCache interface{Get;Put}`, `ExpandForServer`,
  `DefaultDERPMapURL`.

**Server side** (`tailcat.Server`)
- Fields: `Key`, `Logf`, `Region`, `RegionID`, `DERPMapURL`, `DERPMapCache`,
  `AllowedClients`, `OnTCP func(port) func(net.Conn)`, `OnTCPForward func(netip.AddrPort) func(net.Conn)`, `ServedTCPPorts`.
- Methods: `Start()`, `Close()`, `ConnBlob()`, `Addr()`, `Status() *ipnstate.Status`,
  `DrainTCP(ctx)`, `AddAllowedClient(key)`, `SSHConnHandler(SSHOptions)`,
  `HandleTailscaleSSHConn(c)`, `SupportsSSHServer() bool`.
- The zero value works: `Server{OnTCP: ...}` then `Start()`.

**Client side** (`tailcat.Client`)
- Fields: `Server ConnBlob`, `Key key.NodePrivate`, `Logf`, `DERPMapURL`, `DERPMapCache`.
- Methods: `NewClient(blob)`, `Ping(ctx) (PingResult{Latency}, error)`,
  `DiscoPing(ctx) (*ipnstate.PingResult, error)`, `Dial(ctx, net, addr)`,
  `DialTCPPort(ctx, port)`, `DialTCP(ctx, netip.AddrPort)` (exit-node),
  `PublicKey()`, `Close()`, `DrainTCP(ctx)`.
- Tunnel is established **lazily** on first dial/ping.

**Diagnostics**
- `Client.Ping` → DERP meow/meowed RTT (`PingResult.Latency`).
- `Client.DiscoPing` → `*ipnstate.PingResult` with `Endpoint` (non-empty =
  **direct**), `DERPRegionID`, `DERPRegionCode`, `LatencySeconds`. This is the
  Direct-vs-DERP primitive (CLI `ping` is a thin wrapper around it).

**File / SSH**
- `FileService{Dir string, Mode FileServeMode}` with `FileServeRO/RW/WO`.
- `SSHOptions{Shell bool, Files *FileService}`.
- `ProxyConns(a, b net.Conn)` — bidirectional half-close-aware copy.

**Not exported / footguns**
- `tcpipStackOf` is a `reflect+unsafe` cheat (TODO upstream to export); don't
  rely on internals.
- `ipnstate`, `tailcfg`, `key`, `logger` are re-exported transitively from
  `tailscale.com` — a very large dependency tree (see §13).

---

## 5. Persistent key locations

| Artifact | Path (Linux) | Perms | Notes |
|---|---|---|---|
| Saved server/client keys | `$XDG_CONFIG_HOME/tailcat/keys/<name>.private.json` → `~/.config/tailcat/keys/` | 0600 | JSON: `PrivateKey{Private, Public}` |
| DERP map cache | `$XDG_CACHE_HOME/tailcat/derpmap-<escaped-url>.json` (+`.etag`) → `~/.cache/tailcat/` | 0644 | mtime-based freshness (1h) |
| SSH host key (server) | `$XDG_CONFIG_HOME/tailcat/ssh/ssh_host_ed25519_key` | 0600 | auto-generated ed25519 |

Key naming rules (CLI):
- `default` is the magic server key name — once `default.private.json` exists,
  plain `tailcat`/`tailcat serve` uses it automatically. `--key=new` forces an
  ephemeral key; `--key=<name>` uses another saved key.
- `client-default` is the magic **client** key name — client modes auto-load it.
- `genkey --key` accepts a name (written under `keys/`) or a path (if it
  contains `/` or `\`). `genkey --delete` only accepts names.
- `genkey --list` prints names (files ending `.private.json`), one per line.
- Server keys bake in a DERP region (auto at startup, or pinned via
  `--region`/`--fixed-region`). Client keys have **no region**.

This is **private key material**. Our manager must treat `~/.config/tailcat/keys/`
as sensitive, never display/export/log it, and never copy it around. Our own
manager registry (saved *devices*) is separate and stores only display data +
tokens (see architecture doc).

---

## 6. Token lifecycle

1. **Generation:** server key → `ConnInfo{ServerPublic, ServerDiscoPublic, Region|RegionID}`.
   `DiscoPublic` is derived deterministically from the node key (HMAC-SHA256,
   "disco key v1") so direct-path disco frames never reveal the WireGuard
   public key that is the actual access capability.
2. **Serialization:** `ConnBlob = "tc" + base64url(CBOR(wireConnInfo))`.
   Short form ≈ 95 bytes embeds only a **RegionID integer**; the client fetches
   the DERP map to resolve it. `--full-address`/`resolve` produce a longer,
   self-contained form embedding region/nodes (works offline, no map fetch).
3. **Distribution:** out-of-band (chat, DNS TXT, our GUI). Tokens are
   **case-sensitive**. A `.` in the CLI argument means "DNS name with a
   `tailcat=` TXT record", so tokens never contain dots (base64url).
4. **Consumption:** client parses (validation) → `Expand` region (fetch map if
   short form) → connect to DERP → Meow handshake → WireGuard → (disco →
   direct upgrade when possible).
5. **Revocation:** ephemeral keys die with the process. Saved keys keep a stable
   address across restarts — anyone who **ever** got that token can connect to
   any future listener using that key, **unless** the server runs
   `--allow=nodekey:...` (client allowlist). This is the single most important
   security property to surface in the UI.

**Validation:** `tailcat parse <tok>` (CLI) or `tailcat.ParseConnBlob` (library)
both reject malformed tokens (bad `tc` prefix, bad base64, bad CBOR, bad key
lengths). The library additionally rejects legacy blobs lacking a disco key
(`"legacy server address lacks a separate disco key"`).

---

## 7. Listener lifecycle

- **Server:** `Server.Start()` builds the whole stack (magicsock, netstack,
  wgengine, netmon, dialer) in-process, connects DERP, then dispatches inbound
  TCP by port via `OnTCP`/`OnTCPForward`. The CLI then blocks in `select {}`.
  `Close()` tears down. `DrainTCP(ctx)` ensures the peer acked the final FIN
  before a process exits (important for clean shutdown semantics — the whole
  TCP stack lives in the process, so exiting early can drop in-flight FINs).
- **Client:** fully lazy — first `Dial*`/`Ping` calls `ensureStarted`. `Close()`
  tears down.
- Implication for a manager: the server is a **long-running supervised process**
  (or in-process object in the native backend). Stop = SIGTERM/kill + Close +
  DrainTCP in native. Restart = new ephemeral key or re-load saved key.

---

## 8. Port forwarding architecture

- `tailcat serve 8080,8443` → each port is proxied to `localhost:<port>` by a
  `net.Dial("tcp", ...)` + `ProxyConns` bidirectional copy (half-close aware).
- `serve all` → ports 1–65535 all forwarded to localhost.
- Named services: `exit-node` (server relays to **arbitrary** `ip:port`
  destinations on its network — the client uses `Client.DialTCP` with NAT64
  mapping), `no-auth-ssh` (built-in SSH server on port 22), `files` (SFTP file
  server rooted at `--files` dir).
- `ServedTCPPorts` (when set) tightens the packet filter to just the served
  ports — defense in depth behind the `OnTCP` gate.
- A client dials the server itself via `DialTCPPort(ctx, port)` (port on the
  server's address), or any IP through an exit node via `DialTCP`.
- `socks` mode routes by destination: blob hostnames dial servers directly;
  `server.tailcat` = the given blob; everything else = exit node.

---

## 9. SSH architecture

Two distinct features, which the GUI must keep separate:
1. **Built-in auth-free SSH server** (`serve no-auth-ssh`): gliderssh server,
   `NoClientAuthHandler` (the WireGuard tunnel *is* the identity), a per-user
   ed25519 host key under `~/.config/tailcat/ssh/`. Shell/exec sessions run the
   user's shell (PowerShell on Windows). Only on linux/darwin/windows
   (`!ts_omit_ssh`; `tailcat.SupportsSSHServer()`).
2. **Proxy to system SSH** (`serve 22`): forwards port 22 to `localhost:22`
   (OpenSSH/sshd on the server machine provides auth).
3. **Client side** (`tailcat ssh`): execs the **system `ssh`** with a
   `ProxyCommand` that re-invokes the tailcat binary to dial the server — so the
   client always needs an `ssh` binary. `cp` likewise execs **system `scp`**;
   `ls` is native SFTP (`pkg/sftp`) and needs no binary.
4. **SFTP file service** (`serve files`, `recv`): `pkg/sftp` request server
   rooted with `os.Root` (`os.OpenRoot`) so `..` and symlinks cannot escape the
   served dir. Modes: `ro` (list+read), `rw` (read-write), `wo` (write-only drop
   box: no list/read-back, only upload + mkdir + stat-of-own-paths). `no-auth-ssh`
   servers also serve SFTP with full-home access when `--files` is absent.

---

## 10. Ping / Direct-vs-DERP detection

- `Client.Ping` = one meow/meowed round-trip over DERP → `PingResult.Latency`
  (always the DERP path, ~RTT to relay).
- `Client.DiscoPing` = triggers direct-path discovery and reports the *actual*
  path of the pong: `Endpoint` set ⇒ **direct** (`ip:port`); else
  `DERPRegionID`/`DERPRegionCode`. This is exactly the "Direct vs DERP + Region"
  data the UI wants.
- CLI `ping` prints one line per pong; `--until-direct` loops until a direct
  pong arrives (bounded by `--timeout`, default 10s) and exits 1 otherwise. For
  a GUI "Wait for direct connection" we can call `DiscoPing` in a loop (native)
  or run `tailcat ping --until-direct --timeout=N`.

---

## 11. File-transfer capability

Current upstream primitives:
- **`tailcat recv <dir>`** — a write-only **drop box**: sender `tailcat cp file <blob>:`.
  Senders cannot list/read/touch existing files. No per-transfer notification to
  the receiver process, no accept/reject UI, no collision handling on the wire
  (existing files are protected by WO mode, but a *fresh* upload to an existing
  name → `O_EXCL` only if the client sets it; the drop box otherwise can't
  control names from outside).
- **`tailcat serve files` / `--files=dir[:ro|rw|wo]`** — rooted SFTP server;
  `cp`/`ls`/system `scp`/`sftp` can use it. Read-write mode lets clients
  overwrite/rename/delete within the root.
- **`tailcat cp`** — wraps **system scp** via ProxyCommand. Progress/cancel is
  scp's, not ours; **no programmatic progress/cancel/accept API**.
- **Browser web demo** (`web/`): files and text are sent as **raw TCP streams**
  over the tunnel on an arbitrary port (default port 1 for the CLI's pipe mode).
  The sender streams bytes; the receiver buffers to disk/string. **Filename is
  NOT carried over the wire** in the browser demo — the receiver picks a name via
  the File System Access API (save dialog). Progress/cancel are page-level
  (byte counters over the stream; cancel = close the conn).

**Conclusion for the GUI (V0.2):**
- There is **no CLI primitive** that gives the GUI per-transfer progress,
  cancellation, explicit destination, or accept/reject. `recv`/`cp` are batch,
  drop-box oriented.
- The **web demo pattern is the correct model**: one TCP port = one byte stream,
  with the app layering its own thin framing (filename, size, direction) and
  driving progress/cancel at the connection level.
- Therefore **file transfer (V0.2) and text transfer (V0.3) should use the
  native Go library backend**, implementing a minimal framing protocol (see
  architecture doc) on top of `Client.DialTCPPort` / `Server.OnTCP`. Do **not**
  invent a heavyweight protocol; a short header (magic + name length + name +
  size) + raw stream + half-close is enough.
- Integrity: `Client`/`Server` provide no checksum hooks; we can hash on both
  sides in the native backend for optional verification.
- The drop box (`recv`) remains useful as a *headless* receive option and as a
  fallback, and `serve files` remains the "shared directory" service.

---

## 12. Error handling and exit codes

- Success = 0. **All failures = exit 1** (`log.Fatalf`); help = 0. No richer
  taxonomy — a wrapper must infer error meaning from **stderr text + phase**
  (it knows which subcommand it ran and what it was expecting).
- Error strings are plain Go errors, mostly descriptive and stable-ish in
  practice but **not** guaranteed stable.
- Key error surfaces to test: `tailcat not installed`, invalid token
  (`parse` fails), DNS lookup failure, `no "tailcat=" TXT record found`,
  DERP map fetch failure, `no direct path to the server after <timeout>`,
  `already exists; use --force`, SSH not compiled in (build tags), `--files`
  dir missing/not-a-dir, invalid port/service string.
- For the manager: keep a **stable backend error type** (code + message +
  redacted details) so the UI never surfaces raw "exit code 1".

---

## 13. Which operations are safe to wrap via CLI (Option A)

Good CLI-wrappable (structured argv; output already machine-readable):
- Server start/stop/restart (supervised process; address via
  `TAILCAT_ADDR_FILE` or `--json`).
- Token validation (`tailcat parse` → JSON, no network).
- `tailcat resolve` (short → full token) — optional.
- Ping / until-direct (parse the pong line).
- Identity/key management (`genkey --list/create/delete`, `printpub`).
- Serving named services + port forwarding (`serve <spec>` with `--key`,
  `--allow`, `--files`).
- `tailcat ls` for a directory browser (optional).
- Version check / presence check (`tailcat version`).

Poor CLI candidates:
- **File transfer with progress/cancel/accept** (no API; `cp` uses scp).
- **Text transfer** (no CLI command).
- **Live streaming diagnostics** (only `TAILCAT_STATUS_LOOP=1` stderr JSON).
- **Simultaneous/multi-client receive with per-connection UI** (CLI is
  process-per-server).

## 14. Which operations are better via the Go library (Option B)

- Everything in the "poor CLI candidates" list above: streaming file/text
  transfer with progress, cancellation, framing, accept/reject.
- Live `Status()` / `DiscoPing` polling without spawning processes.
- In-process supervision of server + clients with clean `Close`/`DrainTCP`.
- Custom DERP maps, embedded-region control, `--allow` at runtime
  (`AddAllowedClient`).
- Receiving with explicit destination + collision policy (implement on top of
  `Server.OnTCP`).

Trade-off: Option B means linking `tailscale.com` (v1.103.0-pre) + gVisor +
gliderssh into our backend binary — a very large, slow-compiling dependency
tree and a hard `go 1.27.0` floor. The upstream Go API has **no stability
promises**, so Option B must live strictly behind the adapter interface.

**Recommendation (see architecture doc):** build the backend on the **CLI
adapter for V0.1** (fast, low coupling, and the CLI is genuinely
machine-readable enough), keep the full `TailcatBackend` interface, and **add
the native Go library backend for V0.2** (file/text transfer), selected per
operation or via config. The UI never changes.

---

## 15. Upstream instability we must isolate

Per the README: *"no API or CLI stability promises: the Go API, the CLI flags
and output, and the wire format may all change."* Additionally:
- DERP relays are rate-limited with **no SLA** and Tailscale "may revoke access
  at any time" — the manager should surface relay status but not depend on it.
- `go 1.27.0` floor; `tailscale.com` is a `-pre` version (moving target).
- Default DERP map URL (`tailcat.dev/derpmap.json`) is a product-level constant.
- Region auto-selection uses `netcheck` (network-dependent; may fail → random
  fallback region).
- `resolve`/`ParseConnBlob` behaviors could change; token field layout is
  CBOR-coded with single-char names (locked by `TestWireFieldNames`) but not
  guaranteed across majors.
- The manager must therefore: pin a **minimum/maximum known-good CLI version**
  for the CLI backend, treat all CLI output as data (parse defensively, never
  rely on formatting), keep the adapter as the single integration chokepoint,
  and redact tokens/keys in any telemetry/diagnostics.

---

## 16. Assumptions in the project brief that are incorrect or need adjusting

1. **"Tailcat has file/text transfer primitives."** — Partly true but not GUI-ready:
   file transfer is SFTP-dropbox/scp oriented (`recv`/`cp`/`ls`) with **no
   progress/cancel/accept API**; text transfer exists only as a raw stream in
   the **browser** demo. V0.2/V0.3 need a thin framing layer in the native
   backend. The brief's "Prefer existing upstream primitives where appropriate"
   → the right primitive to reuse is the **raw TCP stream + half-close** model,
   not `cp`/`recv`.
2. **Default "server" is always-listening.** The brief implies a persistent
   listener. Upstream's no-arg mode is a **one-shot stdout pipe that exits after
   one connection**. The manager must use `tailcat serve <ports>` /
   `--serve=<spec>` for anything persistent (SSH, services, file sharing).
3. **"SSH" as a single service.** There are two: built-in auth-free SSH
   (`no-auth-ssh`) and proxying to the system SSH on port 22 (`serve 22`). The
   UI must present both explicitly, because their security models differ.
4. **Token shape.** Brief shows `tcXXXX...` (fine) but implies a fixed "bootstrap
   region" is always shown. Actually a token may carry a **region ID** (client
   fetches the DERP map) or **embedded region** (self-contained). "Tokyo" is an
   example from the default map, not a constant. Region may also be **auto** at
   startup. The dashboard should show the *resolved* region name/code when known,
   and "auto/unknown" otherwise.
5. **Identity UX == `genkey`.** Correct that `genkey` is the mechanism, but the
   magic names `default`/`client-default`, `--allow`, `printpub`, `--fixed-region`,
   and `--region=<host>` (custom DERP) are the real surface. Also: a saved
   **server** key and a **client** identity are different kinds; the brief's
   "Identities" screen should model both.
6. **Saved devices are purely manager-local.** Correct, but note the DNS-name
   option: a device may be stored as a DNS name (resolved to a token at
   connect time via TXT). Validation must handle `tc...` vs `name.example.com`.
7. **"Never route 192.168.x.x/24"** — correct non-goal, with one nuance:
   Tailcat's `exit-node` service *does* already let clients reach the server's
   whole network (and `socks` can route arbitrary hosts through it). We should
   expose exit-node as an **optional named service** but must not build any
   subnet-routing UI/config of our own.
8. **Go version.** The native backend requires Go ≥ 1.27.0 (and a huge
   `tailscale.com` tree). Plan CI/build accordingly; the CLI adapter avoids this.
9. **Token validation input forms.** Beyond paste, the manager should also
   accept a DNS name (per upstream's `addrBlobArg` heuristic: anything with a
   `.` is a DNS TXT lookup) — but do this with an **explicit** "resolve DNS"
   step, not silently, for security clarity.
10. **`tailcat cp` availability.** `cp`/`ls`/`ssh` require the system `scp`/
    `ssh` binaries. The GUI file transfer (native backend) avoids this
    dependency; the CLI backend must check for it.

---

## 17. Testing facilities upstream gives us (important for "no internet")

- `TS_DEBUG_TAILCAT_LOCAL_DERP=1` — hermetic localhost DERP+STUN server embedded
  in the token; used with `--derpmap-url=none` to run **fully offline** two-peer
  round-trips. Perfect for our integration tests without internet.
- `integration.RunDERPAndSTUN(t, logf, "127.0.0.1")` + a local DERP-map
  `httptest` server is the upstream e2e pattern for the native/CLI tests.
- `TAILCAT_ADDR_FILE` lets a test/backend wait for the server's blob deterministically.
- Upstream tests build with `buildtags.ReleaseTags()` to match shipped binaries.
- These let us implement: token validation, ping, DERP-only vs direct,
  serve, SSH (no-auth), file dropbox, and two-endpoint transfer tests **locally**.

---

## 18. Bottom line for the manager

- **V0.1 (dashboard/connect/devices/identities/diagnostics/services):** fully
  achievable by wrapping the **CLI** with structured argv + `TAILCAT_ADDR_FILE`
  + `parse`/`ping`/`genkey` outputs. Lowest risk, fastest.
- **V0.2/V0.3 (file transfer, text):** need the **native Go library backend**
  with a thin app-level framing protocol on a TCP stream (web-demo model), for
  progress, cancel, accept/reject, and filename metadata.
- One `TailcatBackend` interface, two implementations (`cli`, `native`),
  selected per operation — UI untouched when we switch/migrate.
- Hermetic local-DERP testing lets us meet the "no internet needed for tests"
  requirement.
