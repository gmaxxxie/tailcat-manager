#!/usr/bin/env bash
# Tailcat Manager — one-line installer (no Go toolchain needed).
#
#   curl -sL https://raw.githubusercontent.com/gmaxxxie/tailcat-manager/master/quick-install.sh | bash
#
# What it does (idempotent — safe to re-run to update):
#   1. Requires `tailcat` on PATH (installed separately, e.g. `paru -S tailcat`).
#   2. Downloads the prebuilt backend for this architecture from the GitHub
#      release (falls back to building from source if no asset matches).
#   3. Installs the backend to ~/.local/bin/omarchy-tailcat.
#   4. On Omarchy systems: installs the bar widget plugin, enables it, places
#      it on the bar (right section) and restarts the shell.
#
# Env overrides:
#   SKIP_SHELL_RESTART=1   skip the final shell restart (debugging)
set -euo pipefail

REPO="gmaxxxie/tailcat-manager"
BRANCH="master"
VERSION="v0.1.0"
PLUGIN_ID="dev.omarchy.tailcat"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
SOURCE_DIR="${HOME}/tailcat-manager"
BIN_DIR="${HOME}/.local/bin"

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "Checking prerequisites"
command -v tailcat >/dev/null 2>&1 || die "tailcat not found on PATH. Install it first, e.g.:  paru -S tailcat  (or tailcat-bin)"
command -v curl    >/dev/null 2>&1 || die "curl not found"
command -v tar     >/dev/null 2>&1 || die "tar not found"

# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Architecture -> asset suffix.
case "$(uname -m)" in
  x86_64|amd64)    asset="omarchy-tailcat-x86_64-linux" ;;
  aarch64|arm64)   asset="omarchy-tailcat-arm64-linux" ;;
  *)               asset="" ;; # no prebuilt asset for this arch
esac

# 1) Backend binary: prefer the release asset, else build from source.
bin="$work/omarchy-tailcat"
if [ -n "$asset" ] && curl -fsSL --retry 3 --retry-all-errors -o "$bin" \
    "https://github.com/${REPO}/releases/download/${VERSION}/${asset}" 2>/dev/null; then
  say "Downloading prebuilt backend (${asset})"
else
  say "No prebuilt binary — building from source (requires Go 1.27+)"
  command -v go >/dev/null 2>&1 || die "Go not found and no prebuilt binary for $(uname -m). Install Go (paru -S go) or use a supported machine."
  rm -rf "$SOURCE_DIR"
  git clone -q --depth 1 --branch "$BRANCH" "https://github.com/${REPO}" "$SOURCE_DIR"
  ( cd "$SOURCE_DIR/backend" && go build -o "$bin" ./cmd/omarchy-tailcat )
fi
[ -x "$bin" ] || die "backend binary failed to download/build"
chmod +x "$bin"
"$bin" version >/dev/null 2>&1 || die "downloaded backend does not run on this machine"

# 2) Plugin sources (manifest.json + QML) from the branch tarball.
src="$work/src"
archive="$work/src.tar.gz"
curl -fsSL -o "$archive" \
  "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" || die "could not download source tarball"
mkdir -p "$src"
tar -xzf "$archive" -C "$src" --strip-components=1

# 3) Install backend binary.
mkdir -p "$BIN_DIR"
install -m755 "$bin" "$BIN_DIR/omarchy-tailcat"
say "Backend installed: ${BIN_DIR}/omarchy-tailcat"

# 4) GUI plugin (only on Omarchy systems).
if command -v omarchy-shell >/dev/null 2>&1 || command -v omarchy >/dev/null 2>&1; then
  say "Installing Omarchy widget plugin"
  mkdir -p "$PLUGIN_DIR/bin"
  install -m644 "$src/ui/manifest.json"    "$PLUGIN_DIR/"
  install -m644 "$src/ui/Panel.qml"        "$PLUGIN_DIR/"
  install -m644 "$src/ui/Manager.qml"      "$PLUGIN_DIR/"
  install -m644 "$src/ui/TailcatBridge.qml" "$PLUGIN_DIR/"
  install -m755 "$bin" "$PLUGIN_DIR/bin/omarchy-tailcat"

  omarchy-shell -q shell rescanPlugins  >/dev/null 2>&1 || true
  sleep 0.5
  omarchy plugin enable "$PLUGIN_ID"    >/dev/null 2>&1 || true
  sleep 0.3
  omarchy bar put "$PLUGIN_ID" --section right >/dev/null 2>&1 || true

  if [ "${SKIP_SHELL_RESTART:-0}" != "1" ]; then
    say "Restarting omarchy shell"
    omarchy restart shell >/dev/null 2>&1 || true
  else
    say "Skipping shell restart (SKIP_SHELL_RESTART=1) — run 'omarchy restart shell' when ready"
  fi
  say "Plugin installed at ${PLUGIN_DIR} and enabled"
else
  say "No Omarchy shell detected — CLI-only install (backend in PATH)"
fi

say "Done. Verify with:  omarchy-tailcat version  ·  tailcat --help"