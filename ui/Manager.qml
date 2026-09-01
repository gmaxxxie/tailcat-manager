import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — slim bar popup. Deliberately minimal by design:
// it shows listener status and does quick start/stop/restart, plus
// copy-address and self-ping. Everything else — saved devices,
// identities, shared services, diagnostics, and file transfer — is
// handled by pi via the `omarchy-tailcat` / `tailcat` CLIs (see the pi
// `tailcat` skill). File transfer runs in the terminal, not here.
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
      if (root.bridge) root.bridge.refresh()
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
    var proc = Qt.createQmlObject(
      'import Quickshell; import Quickshell.Io; Item { Process { id: p; running: false; command: ["wl-copy"]; stdin: StdioWriter { } ; onExited: function(c) { p.destroy(); } } function run(t) { p.stdin.write(t); p.running = true; } }',
      root, "clipcopy")
    if (proc) proc.run(String(t))
  }

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

    // Point to pi / terminal for the rest.
    Text {
      Layout.fillWidth: true
      text: "设备 / 身份 / 传文件交给 pi —— 在终端里说“帮我管理 tailcat”。"
          + "（收文件：tailcat recv <目录>；发文件：tailcat cp <文件> <地址>:）"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
