import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — the popup content. Restructured into a command home:
//
//   Home   — the three core operations on one panel: listener (start/stop/
//            address), receive files (incoming accept/reject/progress), and
//            send a file (target + path + progress). Plus a recent-result
//            line, a shortcut cheat-sheet, and an expandable help block.
//   Manage — secondary configuration: saved devices, identities, shared
//            services, diagnostics. Each page opens with a usage guide line.
//
// Keyboard: Esc close · m toggle Home/Manage · in Home: s listener toggle,
// r receiver toggle, j/k pick incoming, a accept, d reject, t focus target,
// f focus path, Enter send · in Manage: 1-4 pick a page, page keys as before.
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

  // Pages: Home (command panel) ⇄ Manage (configuration).
  property var sections: ["Home", "Manage"]
  property int sectionIndex: 0
  // Manage sub-pages.
  property var manageSections: ["Devices", "Identities", "Services", "Diagnostics"]
  property int manageSection: 0

  // Expandable help ("?").
  property bool showHelp: false

  // Cursors for lists
  property int deviceCursor: 0
  property int identityCursor: 0
  property int serviceCursor: 0
  property int offerCursor: 0

  // Listener identity selection ("new" = ephemeral, else saved key name)
  property string listenerKey: "new"

  // Connect state
  property string connectTarget: ""
  property var connectResult: null
  property string newDeviceName: ""
  property bool renaming: false
  property string renameText: ""

  // Services model (what Start serves)
  property var services: []

  // Identities create form
  property string newIdentityName: ""
  property bool newIdentityClient: false

  // Add-service form
  property string addServiceName: ""
  property string addServicePort: "8080"
  property string addServiceKind: "port-forward"

  // Diagnostics
  property bool showDetails: false

  // Files (V0.2) state
  property string recvDir: ""
  property string sendTarget: ""
  property string sendPath: ""

  // Operations
  property string busyOp: ""
  property var pendingPing: null

  // Convenience view of the listener status (root-scope for QML children).
  readonly property var listenerState: root.bridge ? (root.bridge.listener || {}) : ({})

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refresh()
  }

  // Poll the file receiver state while the Files section is open.
  Timer {
    interval: 1000
    running: root.opened && root.sectionIndex === 0
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refreshFileRecv()
  }

  onOpenedChanged: {
    if (opened) Qt.callLater(function() {
      root.grabNavFocus()
      if (root.bridge) root.bridge.refresh()
    })
  }

  function grabNavFocus() {
    root.forceActiveFocus()
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function shortTarget(t) {
    var s = String(t || "")
    if (s.indexOf("tc") === 0 && s.length > 12) return "tc…" + s.substr(s.length - 4)
    return s
  }

  function fmtLatency(us) {
    if (!us) return ""
    if (us >= 1000) return (us / 1000).toFixed(1) + " ms"
    return Math.round(us) + " µs"
  }

  function pingSelf(untilDirect) {
    if (!root.bridge.listener || !root.bridge.listener.addr) return
    busyOp = "ping"
    root.bridge.ping(root.bridge.listener.addr, untilDirect, function(res) {
      busyOp = ""
      root.bridge.lastError = res.ok ? "" : (res.message || "Ping failed")
      connectResult = res
    })
  }

  function pingDevice(id) {
    var d = deviceById(id)
    if (!d) return
    busyOp = "ping"
    root.bridge.ping(d.target, false, function(res) {
      busyOp = ""
      if (res.ok) root.bridge.touchDevice(id)
      root.bridge.lastError = res.ok ? "" : (res.message || "Ping failed")
      connectResult = res
    })
  }

  function connectDevice(id) {
    var d = deviceById(id)
    if (!d) return
    busyOp = "connect"
    root.bridge.ping(d.target, true, function(res) {
      busyOp = ""
      if (res.ok) root.bridge.touchDevice(id)
      root.bridge.lastError = res.ok ? "" : (res.message || "Connect failed")
      connectResult = res
    })
  }

  function deviceById(id) {
    for (var i = 0; i < root.bridge.devices.length; i++)
      if (root.bridge.devices[i].id === id) return root.bridge.devices[i]
    return null
  }

  function copyText(t) {
    if (!t) return
    var proc = Qt.createQmlObject(
      'import Quickshell; import Quickshell.Io; Item { Process { id: p; running: false; command: ["wl-copy"]; stdin: StdioWriter { } ; onExited: function(c) { p.destroy(); } } function run(t) { p.stdin.write(t); p.running = true; } }',
      root, "clipcopy")
    if (proc) proc.run(String(t))
  }

  // ---- Devices ----
  function moveDeviceCursor(d) { deviceCursor = clamp(deviceCursor + d, 0, Math.max(0, root.bridge.devices.length - 1)) }
  function selectedDevice() { return root.bridge.devices.length ? root.bridge.devices[deviceCursor] : null }
  function copyDevice() { var d = selectedDevice(); if (d) copyText(d.target) }
  function pingSelectedDevice() { var d = selectedDevice(); if (d) pingDevice(d.id) }
  function connectSelectedDevice() { var d = selectedDevice(); if (d) connectDevice(d.id) }
  function removeSelectedDevice() { var d = selectedDevice(); if (d) confirmRemoveDevice.targetDevice = d }
  function startRename() { var d = selectedDevice(); if (d) { renameText = d.name; renaming = true; renameField.forceActiveFocus() } }
  function commitRename() { var d = selectedDevice(); if (d && renameText.trim()) root.bridge.renameDevice(d.id, renameText.trim()); renaming = false }

  // ---- Identities ----
  function moveIdentityCursor(d) { identityCursor = clamp(identityCursor + d, 0, Math.max(0, root.bridge.identities.length - 1)) }
  function selectedIdentity() { return root.bridge.identities.length ? root.bridge.identities[identityCursor] : null }
  function useSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent) { listenerKey = i.name; sectionIndex = 0 } }
  function deleteSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent && i.name !== "new") confirmDeleteIdentity.targetName = i.name }

  // ---- Services ----
  function moveServiceCursor(d) { serviceCursor = clamp(serviceCursor + d, 0, Math.max(0, services.length - 1)) }
  function selectedService() { return services.length ? services[serviceCursor] : null }
  function toggleSelectedService() {
    var s = selectedService()
    if (!s) return
    s.enabled = !s.enabled
    services = services.slice()
    root.bridge.lastError = ""
  }
  function removeSelectedService() {
    if (!services.length) return
    services = services.filter(function(x, i) { return i !== serviceCursor })
    serviceCursor = clamp(serviceCursor, 0, Math.max(0, services.length - 1))
  }
  function addService() {
    var name = addServiceName.trim()
    if (addServiceKind === "port-forward") {
      var port = parseInt(addServicePort, 10)
      if (!(port >= 1 && port <= 65535)) { root.bridge.lastError = "Port must be 1–65535"; return }
      if (services.some(function(s) { return s.kind === "port-forward" && s.port === port })) {
        root.bridge.lastError = "Port " + port + " is already added"
        return
      }
      services = services.concat([{ name: name || ("Port " + port), kind: "port-forward", port: port, enabled: true }])
    } else {
      var kind = addServiceKind
      if (services.some(function(s) { return s.kind === kind })) {
        root.bridge.lastError = kind + " is already added"
        return
      }
      var labels = { "no-auth-ssh": "SSH (built-in)", "files": "File share", "exit-node": "Exit node" }
      services = services.concat([{ name: name || labels[kind] || kind, kind: kind, port: 0, enabled: true }])
    }
    root.bridge.lastError = ""
    addServiceName = ""
  }

  // ---- Listener actions ----
  function startOrStop() {
    if (root.bridge.listener && root.bridge.listener.running === true) stopServer()
    else startServer()
  }
  function startServer() {
    busyOp = "start"
    root.bridge.startServer(services, listenerKey === "new" ? "new" : listenerKey, function() { busyOp = "" })
  }
  function stopServer() {
    busyOp = "stop"
    root.bridge.stopServer(function() { busyOp = "" })
  }
  function restartServer() {
    busyOp = "restart"
    root.bridge.restartServer(services, listenerKey === "new" ? "new" : listenerKey, function() { busyOp = "" })
  }

  // ---- Connect ----
  function runConnect() {
    var t = connectTarget.trim()
    if (!t) { root.bridge.lastError = "Paste a tailcat token or DNS name first"; return }
    busyOp = "connect"
    root.bridge.ping(t, true, function(res) {
      busyOp = ""
      connectResult = res
      root.bridge.lastError = res.ok ? "" : (res.message || "Connect failed")
    })
  }
  function runValidate() {
    var t = connectTarget.trim()
    if (!t) return
    busyOp = "validate"
    root.bridge.validate(t, function(res) {
      busyOp = ""
      connectResult = res
      root.bridge.lastError = res.valid ? "" : (res.message || "Invalid target")
    })
  }
  function saveCurrentAsDevice() {
    var t = connectTarget.trim()
    if (!t) { root.bridge.lastError = "Enter a target first"; return }
    var name = newDeviceName.trim() || shortTarget(t)
    root.bridge.addDevice(name, t, function(d) {
      if (d && d.error) root.bridge.lastError = d.error.message
    })
    newDeviceName = ""
  }

  // ---- Identities create/delete ----
  function createIdentity() {
    var name = newIdentityName.trim()
    if (!name) { root.bridge.lastError = "Enter an identity name"; return }
    root.bridge.createIdentity(name, newIdentityClient ? "client" : "server", "", function(d) {
      if (d && d.error) root.bridge.lastError = d.error.message
    })
    newIdentityName = ""
  }

  // ---- Files (V0.2) ----
  function moveOfferCursor(d) { offerCursor = clamp(offerCursor + d, 0, Math.max(0, root.bridge.fileRecvPending.length - 1)) }
  function selectedOffer() { return root.bridge.fileRecvPending.length ? root.bridge.fileRecvPending[offerCursor] : null }
  function acceptSelectedOffer() { var o = selectedOffer(); if (o && o.state === "offered") root.bridge.fileRecvRespond(o.id, true, "") }
  function rejectSelectedOffer() { var o = selectedOffer(); if (o && o.state === "offered") root.bridge.fileRecvRespond(o.id, false, "") }
  function toggleRecv() {
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true) root.bridge.fileRecvStop()
    else root.bridge.fileRecvStart(recvDir, "")
  }
  function useDeviceForSend() { var d = selectedDevice(); if (d) sendTarget = d.target }
  function doSendFile() {
    var t = sendTarget.trim()
    var p = sendPath.trim()
    if (!t) { root.bridge.lastError = "Enter a target (paste a token or pick a device)"; return }
    if (!p) { root.bridge.lastError = "Enter a file path"; return }
    root.bridge.fileSend(t, p, "")
  }
  function sendPct() {
    if (root.bridge.sendTotal <= 0) return 0
    return Math.max(0, Math.min(1, root.bridge.sendSent / root.bridge.sendTotal))
  }

  function identityChips() {
    var out = []
    out.push({ key: "new", name: "Ephemeral", selected: root.listenerKey === "new" })
    for (var i = 0; i < root.bridge.identities.length; i++) {
      var idn = root.bridge.identities[i]
      if (idn.persistent && idn.name !== "new" && idn.kind !== "client") {
        out.push({ key: idn.name, name: idn.name, selected: root.listenerKey === idn.name })
      }
    }
    return out
  }

  function heroMeta() {
    if (!root.bridge.available) return "TAILCAT NOT INSTALLED"
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true) {
      var st = root.bridge.listener || {}
      if (st.running === true) return "RUNNING · " + (st.keyInUse || "ephemeral")
      return "READY"
    }
    return "READY"
  }

  function heroDetail() {
    if (!root.bridge.available) return "Install `tailcat` (e.g. paru -S tailcat) and restart"
    var st = root.bridge.listener || {}
    if (st.running === true && st.addr) return shortTarget(st.addr)
    return "No listener running"
  }

  function resultLine() {
    var r = connectResult
    if (!r) return ""
    if (r.ok) {
      var line = "OK"
      if (r.direct) line += " · direct"
      else line += " · DERP" + (r.regionCode ? "(" + r.regionCode + ")" : "")
      if (r.latency) line += " · " + fmtLatency(r.latency)
      return line
    }
    return r.message || "Failed"
  }

  function cycleAddKind() {
    var kinds = ["port-forward", "no-auth-ssh", "files", "exit-node"]
    var i = kinds.indexOf(addServiceKind)
    addServiceKind = kinds[(i + 1) % kinds.length]
  }

  function manageGuide() {
    switch (root.manageSection) {
    case 0: return "Saved devices — j/k select · Enter connect · c copy · p ping · n rename · d remove"
    case 1: return "Identities — j/k select · Enter use for listener · c create · d delete. Persistent = stable address, ephemeral = new each session"
    case 2: return "Shared services — what the listener serves. j/k · Space toggle · a add · d remove"
    case 3: return "Diagnostics — r refresh · Details shows the (redacted) server log"
    }
    return ""
  }

  function shortcutLine() {
    return "s listener · r receive · j/k pick · a accept · d reject · t/f focus · Enter send · m manage · ? help · Esc close"
  }

  // ---- Keyboard ----
  Keys.onPressed: function(event) {
    var key = event.key
    if (key === Qt.Key_Escape) { root.closeRequested(); event.accepted = true; return }
    if (key === Qt.Key_M) { sectionIndex = sectionIndex === 0 ? 1 : 0; event.accepted = true; return }
    if (key === Qt.Key_Question || (key === Qt.Key_Slash && (event.modifiers & Qt.ControlModifier))) { showHelp = !showHelp; event.accepted = true; return }
    if (root.sectionIndex === 0) {
      // Home
      if (key === Qt.Key_S) { startOrStop(); event.accepted = true }
      else if (key === Qt.Key_R) { toggleRecv(); event.accepted = true }
      else if (key === Qt.Key_J || key === Qt.Key_Down) { moveOfferCursor(1); event.accepted = true }
      else if (key === Qt.Key_K || key === Qt.Key_Up) { moveOfferCursor(-1); event.accepted = true }
      else if (key === Qt.Key_A) { acceptSelectedOffer(); event.accepted = true }
      else if (key === Qt.Key_D) { rejectSelectedOffer(); event.accepted = true }
      else if (key === Qt.Key_T) { homeTargetField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_F) { homePathField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_Return || key === Qt.Key_Enter) { doSendFile(); event.accepted = true }
    } else {
      // Manage
      if (key === Qt.Key_1) { manageSection = 0; event.accepted = true }
      else if (key === Qt.Key_2) { manageSection = 1; event.accepted = true }
      else if (key === Qt.Key_3) { manageSection = 2; event.accepted = true }
      else if (key === Qt.Key_4) { manageSection = 3; event.accepted = true }
      else if (key === Qt.Key_Left) { manageSection = clamp(manageSection - 1, 0, manageSections.length - 1); event.accepted = true }
      else if (key === Qt.Key_Right) { manageSection = clamp(manageSection + 1, 0, manageSections.length - 1); event.accepted = true }
      else {
        switch (manageSection) {
        case 0: // Devices
          if (key === Qt.Key_J || key === Qt.Key_Down) { moveDeviceCursor(1); event.accepted = true }
          else if (key === Qt.Key_K || key === Qt.Key_Up) { moveDeviceCursor(-1); event.accepted = true }
          else if (key === Qt.Key_C) { copyDevice(); event.accepted = true }
          else if (key === Qt.Key_P) { pingSelectedDevice(); event.accepted = true }
          else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) { connectSelectedDevice(); event.accepted = true }
          else if (key === Qt.Key_N) { startRename(); event.accepted = true }
          else if (key === Qt.Key_X) { removeSelectedDevice(); event.accepted = true }
          break
        case 1: // Identities
          if (key === Qt.Key_J || key === Qt.Key_Down) { moveIdentityCursor(1); event.accepted = true }
          else if (key === Qt.Key_K || key === Qt.Key_Up) { moveIdentityCursor(-1); event.accepted = true }
          else if (key === Qt.Key_C) { newIdentityField.forceActiveFocus(); event.accepted = true }
          else if (key === Qt.Key_X) { deleteSelectedIdentity(); event.accepted = true }
          else if (key === Qt.Key_Return || key === Qt.Key_Enter) { useSelectedIdentity(); event.accepted = true }
          break
        case 2: // Services
          if (key === Qt.Key_J || key === Qt.Key_Down) { moveServiceCursor(1); event.accepted = true }
          else if (key === Qt.Key_K || key === Qt.Key_Up) { moveServiceCursor(-1); event.accepted = true }
          else if (key === Qt.Key_A) { addServiceField.forceActiveFocus(); event.accepted = true }
          else if (key === Qt.Key_Space) { toggleSelectedService(); event.accepted = true }
          else if (key === Qt.Key_X) { removeSelectedService(); event.accepted = true }
          break
        case 3: // Diagnostics
          if (key === Qt.Key_R) { root.bridge.refreshDiagnostics(); event.accepted = true }
          break
        }
      }
    }
  }

// ---- Render ----
  //
  // Outer chrome (fixed): hero + nav + error + help. The content area is a
  // plain Item sized to the remaining height; each page is a Flickable so
  // tall content scrolls instead of overflowing. Layout rules honored
  // strictly: only ColumnLayout children use Layout.*; Rows use implicit
  // widths; plain Columns size children with width: parent.width.
  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(5)

    PanelHero {
      id: hero
      Layout.fillWidth: true
      title: "Tailcat"
      meta: heroMeta()
      detail: heroDetail()
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
        Row {
          spacing: Style.space(3)
          Button {
            text: "Copy"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            foreground: root.foreground
            onClicked: if (root.bridge.listener && root.bridge.listener.addr) root.copyText(root.bridge.listener.addr)
          }
          Button {
            text: "Help"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            foreground: root.foreground
            onClicked: root.showHelp = !root.showHelp
          }
        }
      }
    }

    // Top nav: Home ⇄ Manage.
    Row {
      Layout.fillWidth: true
      spacing: Style.space(3)
      Repeater {
        model: root.sections
        Button {
          text: modelData
          selected: index === root.sectionIndex
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          foreground: root.foreground
          accent: root.accent
          onClicked: root.sectionIndex = index
        }
      }
      Button {
        text: "?"
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.spacing.sm
        foreground: root.foreground
        onClicked: root.showHelp = !root.showHelp
      }
    }

    // Error line (only takes space when present).
    Text {
      Layout.fillWidth: true
      visible: root.bridge && root.bridge.lastError !== ""
      text: root.bridge ? root.bridge.lastError : ""
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Expandable help block ("?" or Ctrl+/).
    Column {
      Layout.fillWidth: true
      visible: root.showHelp
      spacing: Style.space(3)
      Text { width: parent.width; text: "RECEIVE A FILE  1. Start receiving (r)  2. Copy the address  3. The sender dials it  4. Accept/Reject here"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "SEND A FILE  1. Device (or paste a token)  2. File path  3. Send (Enter)  4. Progress → done"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "SHORTCUTS  s listener · r receive · j/k pick · a accept · d reject · t/f focus · Enter send · m manage · ? help · Esc close"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
    }

    // ---- content area: exactly the remaining height ----
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true

      // ============ HOME ============
      Flickable {
        visible: root.sectionIndex === 0
        anchors.fill: parent
        contentHeight: homeCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: homeCol
          width: parent.width
          spacing: Style.space(6)

          // ---- Listener ----
          PanelSectionHeader { text: "LISTENER"; foreground: root.foreground }
          Row {
            spacing: Style.space(6)
            Text {
              width: 120
              text: root.listenerState.running === true ? "● Running" : "○ Stopped"
              color: root.listenerState.running === true ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Button { text: root.listenerState.running === true ? "Stop" : "Start"; onClicked: root.startOrStop() }
            Button { text: "Restart"; enabled: root.listenerState.running === true; onClicked: root.restartServer() }
            Button { text: "Ping"; enabled: root.listenerState.running === true; onClicked: root.pingSelf(true) }
          }
          Text {
            width: parent.width
            visible: root.listenerState.running === true
            text: "Addr " + root.shortTarget(root.listenerState.addr) + "  ·  key " + (root.listenerState.keyInUse || "ephemeral") + (root.listenerState.broad === true ? " · serving ALL ports!" : "") + (root.listenerState.region ? " · " + root.listenerState.region : "")
            color: root.listenerState.broad === true ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Row {
            visible: root.listenerState.running === true
            spacing: Style.space(6)
            Button { text: "Copy addr"; onClicked: if (root.bridge.listener && root.bridge.listener.addr) root.copyText(root.bridge.listener.addr) }
            Text {
              text: "分享此地址，对方用 'Connect' 或 'SEND FILE' 连入"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Receive ----
          PanelSectionHeader { text: "RECEIVE FILE"; foreground: root.foreground }
          Row {
            spacing: Style.space(6)
            Button {
              text: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "Stop receiving" : "Start receiving"
              onClicked: root.toggleRecv()
            }
            TextField {
              id: homeRecvDirField
              width: parent.width - 170
              placeholderText: "Recv dir (default ~/Downloads)"
              foreground: root.foreground
              accent: root.accent
              text: root.recvDir
              onTextChanged: root.recvDir = text
            }
          }
          Row {
            visible: root.bridge.fileRecvState && root.bridge.fileRecvState.addr !== ""
            spacing: Style.space(6)
            Text {
              width: parent.width - 90
              text: "Share: " + root.shortTarget(root.bridge.fileRecvState.addr)
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
            Button { text: "Copy"; onClicked: root.copyText(root.bridge.fileRecvState.addr) }
          }
          Text {
            width: parent.width
            visible: root.bridge.fileRecvPending.length === 0
            text: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "Waiting for incoming…" : "No incoming — start receiving to accept files from others"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          // Pending offers (bounded; whole page scrolls if long).
          Repeater {
            model: root.bridge.fileRecvPending.length > 4 ? root.bridge.fileRecvPending.slice(0, 4) : root.bridge.fileRecvPending
            Rectangle {
              width: parent.width
              height: offerBox.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: index === root.offerCursor ? Util.alpha(root.foreground, 0.10) : "transparent"
              Column {
                id: offerBox
                anchors.fill: parent
                anchors.margins: Style.space(4)
                spacing: Style.space(3)
                Row {
                  spacing: Style.space(6)
                  Text {
                    width: 200
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    text: root.fmtBytes(modelData.size) + (modelData.state === "transferring" ? "  ·  " + root.fmtBytes(modelData.sent) : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Row {
                  visible: modelData.state === "offered"
                  spacing: Style.space(6)
                  Text {
                    text: "from " + (modelData.sender || "?")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Button { text: "Accept"; onClicked: root.bridge.fileRecvRespond(modelData.id, true, "") }
                  Button { text: "Reject"; onClicked: root.bridge.fileRecvRespond(modelData.id, false, "") }
                }
                Rectangle {
                  visible: modelData.state === "transferring" && modelData.size > 0
                  width: parent.width
                  height: 4
                  radius: 2
                  color: Util.alpha(root.foreground, 0.15)
                  Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, modelData.sent / modelData.size))
                    height: parent.height
                    radius: 2
                    color: root.accent
                  }
                }
              }
            }
          }
          Text {
            width: parent.width
            visible: root.bridge.fileRecvPending.length > 4
            text: "… and " + (root.bridge.fileRecvPending.length - 4) + " more (scroll)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: parent.width
            visible: root.bridge.fileRecvDone.length > 0
            text: "Done: " + root.bridge.fileRecvDone.map(function(d) { return d.name + (d.ok ? " ✓" : " ✗") }).join("  ·  ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ---- Send ----
          PanelSectionHeader { text: "SEND FILE"; foreground: root.foreground }
          Row {
            spacing: Style.space(4)
            Repeater {
              model: root.homeDeviceChips()
              Button {
                text: modelData.name
                selected: root.sendTarget === modelData.target
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.sm
                foreground: root.foreground
                accent: root.accent
                onClicked: root.sendTarget = modelData.target
              }
            }
          }
          Row {
            spacing: Style.space(4)
            TextField {
              id: homeTargetField
              width: parent.width - 100
              placeholderText: "Target tc… (or pick a device above)"
              foreground: root.foreground
              accent: root.accent
              text: root.sendTarget
              onTextChanged: root.sendTarget = text
              Keys.onEscapePressed: root.grabNavFocus()
            }
            Button { text: "Use device"; onClicked: root.useDeviceForSend() }
          }
          Row {
            spacing: Style.space(4)
            TextField {
              id: homePathField
              width: parent.width - 150
              placeholderText: "File path"
              foreground: root.foreground
              accent: root.accent
              text: root.sendPath
              onTextChanged: root.sendPath = text
              onAccepted: root.doSendFile()
              Keys.onEscapePressed: root.grabNavFocus()
            }
            Button { text: "Send"; enabled: !root.bridge.sendActive; onClicked: root.doSendFile() }
            Button { text: "Cancel"; visible: root.bridge.sendActive; onClicked: root.bridge.cancelSend() }
          }
          Rectangle {
            visible: root.bridge.sendActive
            width: parent.width
            height: 5
            radius: 2.5
            color: Util.alpha(root.foreground, 0.15)
            Rectangle {
              width: parent.width * root.sendPct()
              height: parent.height
              radius: 2.5
              color: root.accent
            }
          }
          Text {
            width: parent.width
            visible: root.bridge.sendActive || root.bridge.sendResult !== "" || root.connectResult !== null
            text: root.bridge.sendActive ? (root.bridge.sendFile + "  ·  " + root.fmtBytes(root.bridge.sendSent) + " / " + root.fmtBytes(root.bridge.sendTotal)) : (root.bridge.sendResult !== "" ? root.bridge.sendResult : root.resultLine())
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: root.shortcutLine()
            color: Qt.darker(root.foreground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // ============ MANAGE ============
      Flickable {
        visible: root.sectionIndex === 1
        anchors.fill: parent
        contentHeight: manageCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: manageCol
          width: parent.width
          spacing: Style.space(6)

          // Sub-nav.
          Row {
            spacing: Style.space(3)
            Repeater {
              model: root.manageSections
              Button {
                text: modelData
                selected: index === root.manageSection
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.sm
                foreground: root.foreground
                accent: root.accent
                onClicked: root.manageSection = index
              }
            }
          }
          // Guide line for the current page.
          Text {
            width: parent.width
            text: root.manageGuide()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          PanelSeparator { width: parent.width; foreground: root.foreground }

          // --- Devices ---
          Column {
            visible: root.manageSection === 0
            width: parent.width
            spacing: Style.space(5)
            Repeater {
              model: root.bridge.devices
              Rectangle {
                width: parent.width
                height: devRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: index === root.deviceCursor ? Util.alpha(root.foreground, 0.10) : "transparent"
                Row {
                  id: devRow
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  spacing: Style.space(6)
                  Text {
                    width: parent.width * 0.42
                    text: modelData.name
                    color: index === root.deviceCursor ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width * 0.4
                    text: root.shortTarget(modelData.target)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                  Text {
                    width: parent.width * 0.14
                    text: modelData.kind === "dns" ? "dns" : "token"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.deviceCursor = index
                  onDoubleClicked: root.connectDevice(modelData.id)
                }
              }
            }
            Row {
              visible: root.bridge.devices.length > 0
              spacing: Style.space(6)
              Button { text: "Copy"; onClicked: root.copyDevice() }
              Button { text: "Ping"; onClicked: root.pingSelectedDevice() }
              Button { text: "Connect"; onClicked: root.connectSelectedDevice() }
              Button { text: "Rename"; onClicked: root.startRename() }
              Button { text: "Remove"; onClicked: root.removeSelectedDevice() }
            }
            Row {
              visible: root.renaming
              spacing: Style.space(6)
              TextField {
                id: renameField
                width: parent.width - 90
                placeholderText: "New name"
                foreground: root.foreground
                accent: root.accent
                text: root.renameText
                onTextChanged: root.renameText = text
                onAccepted: root.commitRename()
                Keys.onEscapePressed: root.renaming = false
              }
              Button { text: "Save"; onClicked: root.commitRename() }
            }
            Text {
              visible: root.bridge.devices.length === 0
              width: parent.width
              text: "No saved devices yet. On Home paste a token and Send/Connect, or add one below."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(6)
              TextField {
                id: saveDeviceField
                width: parent.width - 190
                placeholderText: "Paste tc… or DNS name"
                foreground: root.foreground
                accent: root.accent
                text: root.connectTarget
                onTextChanged: root.connectTarget = text
              }
              TextField {
                width: 90
                placeholderText: "Name"
                foreground: root.foreground
                accent: root.accent
                text: root.newDeviceName
                onTextChanged: root.newDeviceName = text
                onAccepted: root.saveCurrentAsDevice()
              }
              Button { text: "Save"; onClicked: root.saveCurrentAsDevice() }
            }
          }

          // --- Identities ---
          Column {
            visible: root.manageSection === 1
            width: parent.width
            spacing: Style.space(5)
            Repeater {
              model: root.bridge.identities
              Rectangle {
                width: parent.width
                height: idRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: index === root.identityCursor ? Util.alpha(root.foreground, 0.10) : "transparent"
                Row {
                  id: idRow
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  spacing: Style.space(6)
                  Text {
                    width: parent.width * 0.4
                    text: modelData.name + (modelData.isDefault ? " ★" : "")
                    color: index === root.identityCursor ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width * 0.35
                    text: modelData.persistent ? (modelData.kind === "client" ? "client" : "saved") : "ephemeral"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.identityCursor = index
                  onDoubleClicked: if (modelData.persistent && modelData.name !== "new") { root.listenerKey = modelData.name; root.sectionIndex = 0 }
                }
              }
            }
            Row {
              spacing: Style.space(6)
              TextField {
                id: newIdentityField
                width: parent.width - 150
                placeholderText: "Identity name"
                foreground: root.foreground
                accent: root.accent
                text: root.newIdentityName
                onTextChanged: root.newIdentityName = text
                onAccepted: root.createIdentity()
              }
              Button { text: "Create"; onClicked: root.createIdentity() }
              Button {
                visible: root.selectedIdentity() && root.selectedIdentity().persistent && root.selectedIdentity().name !== "new"
                text: "Delete"
                onClicked: root.deleteSelectedIdentity()
              }
            }
            Toggle {
              label: "Client identity (for --allow lists)"
              description: "No DERP region; prints a public nodekey"
              checked: root.newIdentityClient
              onClicked: root.newIdentityClient = !root.newIdentityClient
            }
          }

          // --- Services ---
          Column {
            visible: root.manageSection === 2
            width: parent.width
            spacing: Style.space(5)
            Repeater {
              model: root.services
              Rectangle {
                width: parent.width
                height: svcRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: index === root.serviceCursor ? Util.alpha(root.foreground, 0.10) : "transparent"
                Row {
                  id: svcRow
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  spacing: Style.space(6)
                  Text {
                    width: parent.width * 0.45
                    text: modelData.name || (modelData.kind === "port-forward" ? ("Port " + modelData.port) : modelData.kind)
                    color: modelData.enabled ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width * 0.25
                    text: modelData.kind === "port-forward" ? String(modelData.port) : modelData.kind
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  ToggleSwitch {
                    width: parent.width * 0.2
                    checked: modelData.enabled
                    onToggled: { root.services[index].enabled = checked; root.services = root.services.slice() }
                  }
                }
              }
            }
            Row {
              spacing: Style.space(6)
              TextField {
                id: addServiceField
                width: parent.width - 260
                placeholderText: "Name (optional)"
                foreground: root.foreground
                accent: root.accent
                text: root.addServiceName
                onTextChanged: root.addServiceName = text
                onAccepted: root.addService()
              }
              Button {
                text: root.addServiceKind === "port-forward" ? "TCP port" : root.addServiceKind
                onClicked: root.cycleAddKind()
              }
              TextField {
                visible: root.addServiceKind === "port-forward"
                width: 60
                placeholderText: "port"
                foreground: root.foreground
                accent: root.accent
                text: root.addServicePort
                validator: IntValidator { bottom: 1; top: 65535 }
                onTextChanged: root.addServicePort = text
              }
              Button { text: "Add"; onClicked: root.addService() }
            }
            Text {
              visible: root.services.length === 0
              width: parent.width
              text: "No services: the listener serves ALL localhost ports. Add explicit ports/services to restrict it."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // --- Diagnostics ---
          Column {
            visible: root.manageSection === 3
            width: parent.width
            spacing: Style.space(5)
            Text { width: parent.width; text: "Tailcat: " + (root.bridge.available ? (root.bridge.version + (root.bridge.minOK ? "" : "  (older than supported)")) : "not installed"); color: root.bridge.available ? root.foreground : root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap }
            Text { width: parent.width; visible: root.bridge.versionError !== ""; text: root.bridge.versionError; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            Text { width: parent.width; text: "Listener: " + (root.bridge.listener && root.bridge.listener.running === true ? "running" : "stopped") + " ·  Receiver: " + (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "running" : "stopped"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Row {
              spacing: Style.space(6)
              Button { text: "Refresh"; onClicked: root.bridge.refreshDiagnostics() }
              Button { text: root.showDetails ? "Hide details" : "Details"; onClicked: root.showDetails = !root.showDetails }
            }
            Column {
              visible: root.showDetails
              width: parent.width
              spacing: Style.space(2)
              Repeater {
                model: root.bridge.diagLog
                Text {
                  width: parent.width
                  text: modelData
                  color: root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }
    }
  }
  function homeDeviceChips() {
    var out = []
    var max = Math.min(4, root.bridge.devices.length)
    for (var i = 0; i < max; i++) {
      var d = root.bridge.devices[i]
      out.push({ name: d.name, target: d.target })
    }
    return out
  }

  // Confirm dialogs
  ConfirmDialog {
    id: confirmRemoveDevice
    property var targetDevice: null
    opened: targetDevice !== null
    message: targetDevice ? "Remove “" + targetDevice.name + "” from saved devices?" : ""
    confirmText: "Remove"
    onConfirmed: { if (targetDevice) root.bridge.removeDevice(targetDevice.id); targetDevice = null }
    onCanceled: { targetDevice = null }
  }

  ConfirmDialog {
    id: confirmDeleteIdentity
    property string targetName: ""
    opened: targetName !== ""
    message: "Delete identity “" + targetName + "”? This cannot be undone."
    confirmText: "Delete"
    onConfirmed: { if (targetName) root.bridge.deleteIdentity(targetName); targetName = "" }
    onCanceled: { targetName = "" }
  }
}