// Reproduce the shell popup container in a harness: KeyboardPanel + fake bar
// + Manager, so we can see whether the container hides the LISTENER buttons.
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root

  QtObject {
    id: fakeBar
    property string position: "top"
    property int barSize: 30
    property int barH: 30
    property int barW: 2000
    property color foreground: "#d8dee9"
    property color accent: "#7aa2f7"
    property color urgent: "#f7768e"
    property string fontFamily: "sans-serif"
    property var clickTargets: []
    function targetBelongsToWindow() { return false }
  }

  TailcatBridge { id: bridge }

  KeyboardPanel {
    id: kp
    anchorItem: root
    bar: fakeBar
    contentWidth: 460
    contentHeight: 520
    open: true
    focusTarget: manager

    Manager {
      id: manager
      width: parent.width
      height: parent.height
      bar: fakeBar
      bridge: bridge
      opened: true
      onCloseRequested: Qt.quit()
    }
  }

  Timer { interval: 6000; onTriggered: Qt.quit() }
  Component.onCompleted: bridge.refresh()
}