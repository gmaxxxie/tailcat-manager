import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — slim bar popup. Shows listener status and quick
// start/stop/restart, copy-address and self-ping, plus one-click SSH to a
// peer (opens a terminal running `tailcat ssh <target>`; the peer must serve
// `no-auth-ssh` — the tunnel itself is the identity). Everything else — saved
// devices, identities, shared services, diagnostics, and file transfer — is
// handled by an AI agent via the `omarchy-tailcat` / `tailcat` CLIs (see the
// `tailcat` skill); file transfer is managed from the web UI
// (`omarchy-tailcat web`), not the popup.
//
// Keyboard: Esc close · s start/stop · p ping · c copy address.
Item {
  id: root

  required property var bridge
  property QtObject bar: null
  property bool opened: false
  signal closeRequested()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var listenerState: root.bridge ? (root.bridge.listener || {}) : ({})
  readonly property bool running: listenerState.running === true

  // Height of the visible content so the popup hugs its content. body is
  // defined below; implicitHeight resolves after creation.
  readonly property real pageImplicitHeight: {
    var extra = (root.bridge && root.bridge.lastError !== "" ? errLine.implicitHeight : 0) + Style.space(4)
    return (body ? body.implicitHeight : 0) + hero.implicitHeight + extra + Style.space(28)
  }
  implicitHeight: root.pageImplicitHeight

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refresh()
  }

  onOpenedChanged: {
    if (opened) Qt.callLater(function() {
      root.grabNavFocus()
      if (root.bridge) {
        root.bridge.refresh()
        root.bridge.refreshDevices()
      }
    })
  }

  function grabNavFocus() { root.forceActiveFocus() }

  function shortTarget(t) {
    var s = String(t || "")
    if (s.indexOf("tc") === 0 && s.length > 12) return "tc…" + s.substr(s.length - 4)
    return s
  }

  function startOrStop() { if (root.running) { root.bridge.stopServer() } else { root.bridge.startServer() } }
  function restartServer() { if (root.running) root.bridge.restartServer() }
  function copyAddr() { if (listenerState.addr) root.copyText(listenerState.addr) }
  function pingSelf() {
    if (!listenerState.addr) return
    root.bridge.ping(listenerState.addr, true, function(res) {
      root.bridge.lastError = res.ok ? "" : (res.message || "Ping failed")
    })
  }

  function copyText(t) {
    if (!t) return
    // wl-copy -- <text>: pass text as argv (no shell, no stdin-EOF dependency).
    // The old createQmlObject/Process+StdioWriter version never closed stdin,
    // so wl-copy blocked and nothing was copied.
    Quickshell.execDetached(["wl-copy", "--", String(t)])
  }

  function sshToTarget(target) {
    target = String(target || "").trim()
    if (!target) return
    // Open a terminal running `tailcat ssh <target>`. The peer must serve
    // `no-auth-ssh`; the tailcat tunnel itself is the identity/auth. The
    // target is passed as an argv position ($1) so nothing is shell-parsed.
    Quickshell.execDetached([
      "sh", "-c",
      'T=${TERMINAL:-}; [ -z "$T" ] && for c in kitty foot alacritty; do command -v "$c" >/dev/null 2>&1 && T=$c && break; done; [ -z "$T" ] && T=xterm; exec "$T" -e tailcat ssh "$1"',
      "tc-ssh", target])
    root.bridge.lastError = ""
  }
  function sshTo() { sshToTarget(sshTarget.text) }

  Keys.onPressed: function(event) {
    var key = event.key
    if (key === Qt.Key_Escape) { root.closeRequested(); event.accepted = true }
    else if (key === Qt.Key_S) { root.startOrStop(); event.accepted = true }
    else if (key === Qt.Key_P) { root.pingSelf(); event.accepted = true }
    else if (key === Qt.Key_C) { root.copyAddr(); event.accepted = true }
  }

  // ---- Render ----
  ColumnLayout {
    id: body
    anchors.fill: parent
    spacing: Style.space(5)

    PanelHero {
      id: hero
      Layout.fillWidth: true
      title: "Tailcat"
      meta: {
        if (!root.bridge.available) return "NOT INSTALLED"
        return root.running ? "RUNNING · " + (listenerState.keyInUse || "ephemeral") : "STOPPED"
      }
      detail: {
        if (!root.bridge.available) return "Install `tailcat` (paru -S tailcat) and restart the shell"
        if (root.running && listenerState.addr) return root.shortTarget(listenerState.addr)
        return "No listener running"
      }
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconComponent: Component {
        Text {
          text: "󰞀"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }
      }
      trailingControl: Component {
        Button {
          text: "Copy"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          foreground: root.foreground
          onClicked: root.copyAddr()
        }
      }
    }

    // Status + quick actions.
    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      Button { text: root.running ? "Stop" : "Start"; onClicked: root.startOrStop() }
      Button { text: "Restart"; enabled: root.running; onClicked: root.restartServer() }
      Button { text: "Ping"; enabled: root.running; onClicked: root.pingSelf() }
      Item { Layout.fillWidth: true; height: 1 }
      Text {
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        text: root.running ? "● Running" : "○ Stopped"
        color: root.running ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    // Address + listener details.
    Text {
      Layout.fillWidth: true
      visible: root.running
      text: "Addr " + root.shortTarget(listenerState.addr)
          + "  ·  key " + (listenerState.keyInUse || "ephemeral")
          + (listenerState.broad === true ? " · serving ALL ports!" : "")
          + (listenerState.region ? " · " + listenerState.region : "")
      color: listenerState.broad === true ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    // Error line (only takes space when present).
    Text {
      id: errLine
      Layout.fillWidth: true
      visible: root.bridge && root.bridge.lastError !== ""
      text: root.bridge ? root.bridge.lastError : ""
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    PanelSeparator { Layout.fillWidth: true; foreground: root.foreground; strength: 0.32 }

    // ---- Saved devices: one-click SSH ----
    Text {
      Layout.fillWidth: true
      text: "SAVED DEVICES"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Repeater {
      model: root.bridge.devices
      RowLayout {
        width: parent.width
        spacing: Style.space(6)
        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: modelData.name + "  ·  " + root.shortTarget(modelData.target)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Button {
          text: "SSH"
          onClicked: root.sshToTarget(modelData.target)
        }
      }
    }
    Text {
      Layout.fillWidth: true
      visible: !root.bridge.devices || root.bridge.devices.length === 0
      text: "No saved devices. Add one in a terminal: omarchy-tailcat devices add <name> <tc…>"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // ---- One-click SSH to a peer ----
    Text {
      Layout.fillWidth: true
      text: "SSH TO A PEER"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      TextField {
        id: sshTarget
        Layout.fillWidth: true
        placeholderText: "tc… address or DNS name"
        foreground: root.foreground
        accent: root.accent
        onAccepted: root.sshTo()
        Keys.onEscapePressed: root.grabNavFocus()
      }
      Button {
        text: "SSH"
        enabled: sshTarget.text.trim() !== ""
        onClicked: root.sshTo()
      }
    }
    Text {
      Layout.fillWidth: true
      text: "Peer must run: omarchy-tailcat serve start no-auth-ssh (tunnel = identity, no password)"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    PanelSeparator { Layout.fillWidth: true; foreground: root.foreground; strength: 0.32 }

    // Point to an AI agent / terminal for the rest.
    Text {
      Layout.fillWidth: true
      text: "Devices, identities, and file transfers are handled by an AI agent in the terminal — say “manage tailcat”."
          + " (Receive: tailcat recv <dir>; Send: tailcat cp <file> <addr>:)"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
