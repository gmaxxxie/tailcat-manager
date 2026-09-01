import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Tailcat Manager — Omarchy bar widget. Shows listener status in the bar and
// opens a keyboard-friendly manager popup. Mirrors the omarchy.tailscale /
// herdr widget structure: Panel root, WidgetButton, KeyboardPanel popup.
Panel {
  id: root

  moduleName: "dev.omarchy.tailcat"
  ipcTarget: "dev.omarchy.tailcat"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Shared backend bridge: the bar widget and the popup read the same state.
  // The id is tcBridge (not "bridge") so passing `bridge: tcBridge` to the
  // Manager does not self-reference the Manager's own `bridge` property.
  TailcatBridge {
    id: tcBridge
  }

  readonly property bool available: tcBridge.available
  readonly property bool running: tcBridge.listener && tcBridge.listener.running === true
  readonly property bool recvRunning: tcBridge.fileRecvState && tcBridge.fileRecvState.running === true
  readonly property bool socksRunning: tcBridge.socksState && tcBridge.socksState.running === true

  readonly property string barText: {
    if (!available) return "󰞀 ×"
    if (running) {
      var n = tcBridge.listener.services ? tcBridge.listener.services.length : 0
      return "󰞀 " + (tcBridge.listener.broad === true ? "all" : String(n))
    }
    if (recvRunning) return "󰞀 ⇩"
    if (socksRunning) return "󰞀 ⇅"
    return "󰞀"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.running
    activeColor: root.accent
    fontSize: Style.font.bodySmall
    horizontalMargin: 3.5
    tooltipText: root.running ? "Tailcat running — click to manage" : "Tailcat — click to manage"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) tcBridge.refresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: manager
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(manager.implicitHeight + Style.space(16), Style.space(660))

    Manager {
      id: manager
      width: parent.width
      height: parent.height
      bar: root.bar
      bridge: tcBridge
      opened: root.opened
      onCloseRequested: root.close()
    }
  }

  onOpenedChanged: if (opened) Qt.callLater(function() {
    tcBridge.refresh()
    manager.grabNavFocus()
  })

  Component.onCompleted: tcBridge.refresh()
}
