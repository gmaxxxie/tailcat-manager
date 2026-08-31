// Dev harness: open the Manager directly on a Manage sub-page (manageSection
// from env MANAGE_SEC) so the page can be OCR'd without shell/window noise.
//   MANAGE_SEC=2 OMARCHY_TAILCAT_BIN=... quickshell -p ui/HarnessManage.qml
import QtQuick
import Quickshell
import qs.Commons

Window {
  id: win
  width: 460
  height: 560
  visible: true
  color: Color.background

  TailcatBridge { id: bridge }

  Manager {
    id: manager
    anchors.fill: parent
    bar: null
    bridge: bridge
    opened: true
    sectionIndex: 1
    manageSection: Number(Quickshell.env("MANAGE_SEC") || 0)
    onCloseRequested: Qt.quit()
  }

  Timer { interval: 8000; running: true; onTriggered: Qt.quit() }

  Component.onCompleted: bridge.refresh()
}