#!/usr/bin/env bash
# Install Tailcat Manager as an Omarchy bar widget (dev install).
# Usage: ./packaging/omarchy/install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_DIR="$REPO_ROOT/ui"
PLUGIN_ID="dev.omarchy.tailcat"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "==> Building backend binary (ui/bin/omarchy-tailcat)"
( cd "$REPO_ROOT/backend" && go build -o "$UI_DIR/bin/omarchy-tailcat" ./cmd/omarchy-tailcat )

echo "==> Installing plugin to $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/bin"
cp "$UI_DIR/manifest.json"   "$PLUGIN_DIR/"
cp "$UI_DIR/Panel.qml"       "$PLUGIN_DIR/"
cp "$UI_DIR/Manager.qml"     "$PLUGIN_DIR/"
cp "$UI_DIR/TailcatBridge.qml" "$PLUGIN_DIR/"
cp "$UI_DIR/bin/omarchy-tailcat" "$PLUGIN_DIR/bin/"
cp "$UI_DIR/bin/tc-filepicker" "$PLUGIN_DIR/bin/" && chmod +x "$PLUGIN_DIR/bin/tc-filepicker"

echo "==> Rescanning shell plugins"
omarchy-shell -q shell rescanPlugins || true
sleep 0.5

echo "==> Enabling widget (idempotent)"
omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
sleep 0.5

if ! omarchy plugin list 2>/dev/null | grep -q "$PLUGIN_ID.*enabled"; then
  omarchy-shell -q shell rescanPlugins || true
  sleep 1
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
fi

echo "==> Placing widget on the bar (right section)"
omarchy bar put "$PLUGIN_ID" --section right >/dev/null 2>&1 || \
  echo "    (bar placement skipped; add manually: omarchy bar put $PLUGIN_ID --section right)"

echo "==> Done. Click the Tailcat widget in the bar to open the manager."
echo "    (Requires 'tailcat' on PATH; the widget shows install help otherwise.)"
