// Dev harness: drives the TailcatBridge file-transfer methods exactly as the
// Manager.qml Files section does, under a real quickshell Process.
//   OMARCHY_TAILCAT_BIN=... quickshell -p ui/HarnessFile.qml
import QtQuick
import Quickshell
import qs.Commons

Item {
  id: root

  TailcatBridge { id: bridge }

  property string addr: ""
  property int step: 0
  property string testDir: ""

  function log(msg) { console.log("TCFILE: " + msg) }

  Component.onCompleted: {
    log("starting")
    bridge.refresh()
    timer.start()
    stepTimer.start()
  }

  Timer {
    id: timer
    interval: 25000
    onTriggered: { log("TIMEOUT step=" + root.step + " err=" + bridge.lastError); cleanup(); Qt.quit() }
  }

  Timer {
    id: stepTimer
    interval: 500
    repeat: true
    onTriggered: root.runStep()
  }

  function runStep() {
    bridge.refreshFileRecv()
    switch (root.step) {
    case 0:
      // Start the receiver.
      root.testDir = "/tmp/tc-filetest"
      bridge.fileRecvStart(root.testDir, "", function(data) {
        root.addr = data ? data.addr : ""
        log("recv-start addr=" + (root.addr ? root.addr.substr(0,16) + "…" : "NONE"))
        root.step = 1
      })
      root.step = -1 // wait for callback
      break
    case 1:
      // Create a source file and send it.
      if (root.addr === "") { root.step = 0; return }
      var path = "/tmp/tc-filetest-src.bin"
      bridge.fileSend(root.addr, path, "hello.bin")
      log("send started")
      root.step = 2
      break
    case 2:
      // Wait for a pending offer, then accept.
      if (bridge.fileRecvPending.length > 0) {
        var o = bridge.fileRecvPending[0]
        log("offer: " + o.name + " " + o.size + " state=" + o.state)
        bridge.fileRecvRespond(o.id, true, "/tmp/tc-filetest/hello.bin")
        root.step = 3
      }
      break
    case 3:
      if (!bridge.sendActive) {
        log("send finished: result='" + bridge.sendResult + "'")
        log("recvStatus running=" + bridge.fileRecvState.running + " pending=" + bridge.fileRecvPending.length + " done=" + bridge.fileRecvDone.length)
        root.step = 4
      }
      break
    case 4:
      cleanup()
      log("DONE")
      Qt.quit()
      root.step = -1
      break
    }
  }

  function cleanup() {
    if (bridge.fileRecvState && bridge.fileRecvState.running === true) bridge.fileRecvStop()
  }
}
