// Dev validation harness (not shipped with the plugin). Runs the Tailcat
// Manager content in a standalone Quickshell window so QML errors and the
// backend bridge can be exercised outside the full shell:
//
//   OMARCHY_TAILCAT_BIN=/path/to/omarchy-tailcat \
//   PATH=/tmp/tailcat-build:$PATH \
//   quickshell -p /path/to/ui/Harness.qml
import QtQuick
import Quickshell
import qs.Commons

Window {
  id: win
  width: 520
  height: 620
  visible: true
  color: Color.background

  TailcatBridge { id: bridge }

  Manager {
    id: manager
    anchors.fill: parent
    bar: null
    bridge: bridge
    opened: true
    onCloseRequested: Qt.quit()
  }

  Text {
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    text: "harness · quits in 6s"
    color: Qt.darker(Color.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Timer {
    interval: 6000
    onTriggered: Qt.quit()
  }

  Component.onCompleted: {
    bridge.refresh()
    Qt.callLater(function() { manager.grabNavFocus() })
  }
}
