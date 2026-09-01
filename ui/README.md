# ui/ — Tailcat Manager Omarchy plugin (Quickshell/QML)

- `manifest.json` — plugin manifest (kind: bar-widget)
- `Panel.qml` — bar widget entry point (status glyph + opens the manager popup)
- `Manager.qml` — the popup: deliberately **slim** — listener status +
  start/stop/restart + copy-address + self-ping. Everything else is handled by
  an AI agent via the `omarchy-tailcat` / `tailcat` CLIs (see the `tailcat`
  skill); file transfer runs in the terminal (`tailcat recv` / `tailcat cp`).
- `TailcatBridge.qml` — QML ↔ backend bridge: runs `omarchy-tailcat` with
  structured argv, serialized FIFO queue, JSON parse
- `bin/omarchy-tailcat` — the Go backend (built; not committed)
- `Harness.qml` / `HarnessPanel.qml` — dev-only standalone validation (not
  shipped)

## Local QML validation (no full shell restart)

Quickshell resolves `qs.Commons`/`qs.Ui` from the config dir, so to run the
harness standalone you need a config dir that links the Omarchy modules next to
the plugin files:

```sh
HARNESS=/tmp/tc-harness
rm -rf "$HARNESS" && mkdir -p "$HARNESS"
ln -sfn /usr/share/omarchy/shell/Commons "$HARNESS/Commons"
ln -sfn /usr/share/omarchy/shell/Ui      "$HARNESS/Ui"
for f in Harness.qml Manager.qml Panel.qml TailcatBridge.qml; do
  ln -sfn "$PWD/ui/$f" "$HARNESS/$f"
done

OMARCHY_TAILCAT_BIN=$PWD/ui/bin/omarchy-tailcat \
PATH=/path/to/tailcat:$PATH \
quickshell -p "$HARNESS/Harness.qml"
```

## QML gotchas learned (see also memory/lessons_learned.md)

- `Keys {}` as a child is invalid here — use attached `Keys.onPressed:` on the
  root Item.
- Bare names don't resolve across nested objects; use `root.`-prefixed
  properties everywhere in the render tree.
- A required property named the same as a passed id self-references
  (`bridge: bridge` ⇒ undefined); name ids differently (`tcBridge`).
- `bar` has no `accent` property — use `Color.accent`.
- `anchors.fill` is not allowed on direct children of Row/Column positioners.
- Row children must never use `Layout.*` or `width: parent.width - N` (creates
  a polish() loop); size rows with explicit widths.
