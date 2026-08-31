# Tailcat Manager — Omarchy packaging

Install Tailcat Manager as an Omarchy bar widget. It follows the standard
third-party plugin convention: a QML plugin folder under
`~/.config/omarchy/plugins/dev.omarchy.tailcat/` plus a bundled Go backend
binary.

## Quick install (dev)

```sh
./packaging/omarchy/install.sh
```

The script:
1. Builds the Go backend (`omarchy-tailcat`) into `ui/bin/`.
2. Copies `manifest.json`, `Panel.qml`, `Manager.qml`, `TailcatBridge.qml`
   and the backend binary into `~/.config/omarchy/plugins/dev.omarchy.tailcat/`.
3. Rescans shell plugins, enables the widget, and puts it in the bar's right
   section.

## Requirements

- **tailcat** installed and on `PATH` (Arch: `paru -S tailcat` or
  `tailcat-bin`). The widget shows "not installed" and a hint if it's missing.
- The Omarchy shell (Quickshell) running; the plugin hot-reloads on save.

## After install

- Click the Tailcat widget in the bar (or `omarchy-shell shell summon
  dev.omarchy.tailcat '{}'`) to open the manager.
- Right-click the widget to force-refresh status.

## Structure of a shipped plugin

```
~/.config/omarchy/plugins/dev.omarchy.tailcat/
├── manifest.json        # schemaVersion 1, kind bar-widget
├── Panel.qml            # bar widget entry point
├── Manager.qml          # the manager popup (Dashboard/Connect/Devices/…)
├── TailcatBridge.qml    # QML↔backend bridge (structured argv, JSON)
└── bin/omarchy-tailcat  # Go backend (JSON subcommands)
```

## PKGBUILD (Arch/Omarchy)

An example `PKGBUILD` is provided in this directory. It installs the plugin
into `/usr/share/omarchy/shell/plugins/dev.omarchy.tailcat/` (first-party style)
and the backend binary into `/usr/bin/omarchy-tailcat`. User-level install via
`install.sh` is the simpler option for now.

## Dev validation (no full shell needed)

`ui/Harness.qml` runs the manager content in a standalone Quickshell window:

```sh
OMARCHY_TAILCAT_BIN=$PWD/ui/bin/omarchy-tailcat \
PATH=/path/to/tailcat:$PATH \
quickshell -p ui/Harness.qml
```

(The `qs.Commons`/`qs.Ui` modules resolve because the harness runs from a
config dir that also links the modules — see `ui/README.md` for the recipe.)
