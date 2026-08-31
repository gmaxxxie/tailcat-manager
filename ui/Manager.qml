import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — the popup content. Self-contained and reusable: takes a
// TailcatBridge (owned by Panel.qml so the bar widget and popup share state),
// an optional `bar` for theming, and an `opened` flag that grabs keyboard
// focus. Handles its own keyboard navigation so it can also be tested
// standalone.
Item {
  id: root

  required property var bridge
  property QtObject bar: null
  property bool opened: false  signal closeRequested()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Sections
  property var sections: ["Dashboard", "Connect", "Devices", "Identities", "Services", "Diagnostics"]
  property int sectionIndex: 0

  // Cursors for lists
  property int deviceCursor: 0
  property int identityCursor: 0
  property int serviceCursor: 0

  // Listener identity selection ("new" = ephemeral, else saved key name)
  property string listenerKey: "new"
  property int chipCursor: 0

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

  // Operations
  property string busyOp: ""   // what's running (for button feedback)
  property var pendingPing: null

  // Convenience view of the listener status (root-scope for QML children).
  readonly property var listenerState: bridge ? (bridge.listener || {}) : ({})

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
    if (!bridge.listener || !bridge.listener.addr) return
    busyOp = "ping"
    bridge.ping(bridge.listener.addr, untilDirect, function(res) {
      busyOp = ""
      bridge.lastError = res.ok ? "" : (res.message || "Ping failed")
      connectResult = res
    })
  }

  function pingDevice(id) {
    var d = deviceById(id)
    if (!d) return
    busyOp = "ping"
    bridge.ping(d.target, false, function(res) {
      busyOp = ""
      if (res.ok) bridge.touchDevice(id)
      bridge.lastError = res.ok ? "" : (res.message || "Ping failed")
      connectResult = res
    })
  }

  function connectDevice(id) {
    var d = deviceById(id)
    if (!d) return
    busyOp = "connect"
    bridge.ping(d.target, true, function(res) {
      busyOp = ""
      if (res.ok) bridge.touchDevice(id)
      bridge.lastError = res.ok ? "" : (res.message || "Connect failed")
      connectResult = res
    })
  }

  function deviceById(id) {
    for (var i = 0; i < bridge.devices.length; i++)
      if (bridge.devices[i].id === id) return bridge.devices[i]
    return null
  }

  function copyText(t) {
    if (!t) return
    // Prefer wl-copy (Wayland); fall back to the shell clipboard if exposed.
    var proc = Qt.createQmlObject(
      'import Quickshell; import Quickshell.Io; Item { Process { id: p; running: false; command: ["wl-copy"]; stdin: StdioWriter { } ; onExited: function(c) { p.destroy(); } } function run(t) { p.stdin.write(t); p.running = true; } }',
      root, "clipcopy")
    if (proc) proc.run(String(t))
  }

  Keys.onPressed: function(event) {
      var key = event.key
      if (key === Qt.Key_Escape) { root.closeRequested(); event.accepted = true; return }
      if (key === Qt.Key_Left) { sectionIndex = clamp(sectionIndex - 1, 0, sections.length - 1); event.accepted = true; return }
      if (key === Qt.Key_Right) { sectionIndex = clamp(sectionIndex + 1, 0, sections.length - 1); event.accepted = true; return }
      if (key === Qt.Key_R && !(event.modifiers & Qt.ControlModifier)) { bridge.refresh(); event.accepted = true; return }
      switch (sectionIndex) {
      case 0: // Dashboard
        if (key === Qt.Key_S) { startOrStop(); event.accepted = true }
        else if (key === Qt.Key_P) { pingSelf(false); event.accepted = true }
        break
      case 1: // Connect
        if (key === Qt.Key_C) { connectTargetField.forceActiveFocus(); event.accepted = true }
        break
      case 2: // Devices
        if (key === Qt.Key_J || key === Qt.Key_Down) { moveDeviceCursor(1); event.accepted = true }
        else if (key === Qt.Key_K || key === Qt.Key_Up) { moveDeviceCursor(-1); event.accepted = true }
        else if (key === Qt.Key_C) { copyDevice(); event.accepted = true }
        else if (key === Qt.Key_P) { pingSelectedDevice(); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) { connectSelectedDevice(); event.accepted = true }
        else if (key === Qt.Key_D) { removeSelectedDevice(); event.accepted = true }
        else if (key === Qt.Key_N) { startRename(); event.accepted = true }
        break
      case 3: // Identities
        if (key === Qt.Key_J || key === Qt.Key_Down) { moveIdentityCursor(1); event.accepted = true }
        else if (key === Qt.Key_K || key === Qt.Key_Up) { moveIdentityCursor(-1); event.accepted = true }
        else if (key === Qt.Key_C) { newIdentityField.forceActiveFocus(); event.accepted = true }
        else if (key === Qt.Key_D) { deleteSelectedIdentity(); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter) { useSelectedIdentity(); event.accepted = true }
        break
      case 4: // Services
        if (key === Qt.Key_J || key === Qt.Key_Down) { moveServiceCursor(1); event.accepted = true }
        else if (key === Qt.Key_K || key === Qt.Key_Up) { moveServiceCursor(-1); event.accepted = true }
        else if (key === Qt.Key_A) { addServiceField.forceActiveFocus(); event.accepted = true }
        else if (key === Qt.Key_Space) { toggleSelectedService(); event.accepted = true }
        else if (key === Qt.Key_D) { removeSelectedService(); event.accepted = true }
        break
      }
    }

  // ---- Devices ----
  function moveDeviceCursor(d) { deviceCursor = clamp(deviceCursor + d, 0, Math.max(0, bridge.devices.length - 1)) }
  function selectedDevice() { return bridge.devices.length ? bridge.devices[deviceCursor] : null }
  function copyDevice() { var d = selectedDevice(); if (d) copyText(d.target) }
  function pingSelectedDevice() { var d = selectedDevice(); if (d) pingDevice(d.id) }
  function connectSelectedDevice() { var d = selectedDevice(); if (d) connectDevice(d.id) }
  function removeSelectedDevice() { var d = selectedDevice(); if (d) confirmRemoveDevice.targetDevice = d }
  function startRename() { var d = selectedDevice(); if (d) { renameText = d.name; renaming = true; renameField.forceActiveFocus() } }
  function commitRename() { var d = selectedDevice(); if (d && renameText.trim()) bridge.renameDevice(d.id, renameText.trim()); renaming = false }

  // ---- Identities ----
  function moveIdentityCursor(d) { identityCursor = clamp(identityCursor + d, 0, Math.max(0, bridge.identities.length - 1)) }
  function selectedIdentity() { return bridge.identities.length ? bridge.identities[identityCursor] : null }
  function useSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent) { listenerKey = i.name; sectionIndex = 0 } }
  function deleteSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent && i.name !== "new") confirmDeleteIdentity.targetName = i.name }

  // ---- Services ----
  function moveServiceCursor(d) { serviceCursor = clamp(serviceCursor + d, 0, Math.max(0, services.length - 1)) }
  function selectedService() { return services.length ? services[serviceCursor] : null }
  function toggleSelectedService() {
    var s = selectedService()
    if (!s) return
    s.enabled = !s.enabled
    services = services.slice() // notify
    bridge.lastError = ""
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
      if (!(port >= 1 && port <= 65535)) { bridge.lastError = "Port must be 1–65535"; return }
      if (services.some(function(s) { return s.kind === "port-forward" && s.port === port })) {
        bridge.lastError = "Port " + port + " is already added"
        return
      }
      services = services.concat([{ name: name || ("Port " + port), kind: "port-forward", port: port, enabled: true }])
    } else {
      var kind = addServiceKind
      if (services.some(function(s) { return s.kind === kind })) {
        bridge.lastError = kind + " is already added"
        return
      }
      var labels = { "no-auth-ssh": "SSH (built-in)", "files": "File share", "exit-node": "Exit node" }
      services = services.concat([{ name: name || labels[kind] || kind, kind: kind, port: 0, enabled: true }])
    }
    bridge.lastError = ""
    addServiceName = ""
  }

  // ---- Listener actions ----
  function startOrStop() {
    if (bridge.listener && bridge.listener.running === true) stopServer()
    else startServer()
  }
  function startServer() {
    busyOp = "start"
    bridge.startServer(services, listenerKey === "new" ? "new" : listenerKey, function() { busyOp = "" })
  }
  function stopServer() {
    busyOp = "stop"
    bridge.stopServer(function() { busyOp = "" })
  }
  function restartServer() {
    busyOp = "restart"
    bridge.restartServer(services, listenerKey === "new" ? "new" : listenerKey, function() { busyOp = "" })
  }

  // ---- Connect ----
  function runConnect() {
    var t = connectTarget.trim()
    if (!t) { bridge.lastError = "Paste a tailcat token or DNS name first"; return }
    busyOp = "connect"
    bridge.ping(t, true, function(res) {
      busyOp = ""
      connectResult = res
      bridge.lastError = res.ok ? "" : (res.message || "Connect failed")
    })
  }
  function runValidate() {
    var t = connectTarget.trim()
    if (!t) return
    busyOp = "validate"
    bridge.validate(t, function(res) {
      busyOp = ""
      connectResult = res
      bridge.lastError = res.valid ? "" : (res.message || "Invalid target")
    })
  }
  function saveCurrentAsDevice() {
    var t = connectTarget.trim()
    if (!t) { bridge.lastError = "Enter a target first"; return }
    var name = newDeviceName.trim() || shortTarget(t)
    bridge.addDevice(name, t, function(d) {
      if (d && d.error) bridge.lastError = d.error.message
    })
    newDeviceName = ""
  }

  // ---- Identities create/delete ----
  function createIdentity() {
    var name = newIdentityName.trim()
    if (!name) { bridge.lastError = "Enter an identity name"; return }
    bridge.createIdentity(name, newIdentityClient ? "client" : "server", "", function(d) {
      if (d && d.error) bridge.lastError = d.error.message
    })
    newIdentityName = ""
  }

  // ---- Render ----
  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    PanelHero {
      id: hero
      width: parent.width
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
          spacing: Style.space(4)
          Button {
            text: "Copy addr"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            foreground: root.foreground
            onClicked: if (bridge.listener && bridge.listener.addr) root.copyText(bridge.listener.addr)
          }
        }
      }
    }

    // Section tabs
    Row {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: root.sections
        Button {
          text: modelData
          selected: index === root.sectionIndex
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          foreground: root.foreground
          accent: root.accent
          onClicked: root.sectionIndex = index
        }
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    // Error line
    Text {
      width: parent.width
      visible: bridge.lastError !== ""
      text: bridge.lastError
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Item {
      width: parent.width
      height: contentHeight()
      clip: true

      function contentHeight() { return Math.max(1, root.height - hero.height - 90) }

      // ---------------- Dashboard ----------------
      Column {
        visible: root.sectionIndex === 0
        width: parent.width
        spacing: Style.space(6)

        Row {
          spacing: Style.space(6)
          Button { text: root.listenerState.running === true ? "Stop" : "Start"; onClicked: root.startOrStop() }
          Button { text: "Restart"; enabled: root.listenerState.running === true; onClicked: root.restartServer() }
          Button { text: "Ping self"; onClicked: root.pingSelf(true) }
        }

        PanelSectionHeader { text: "STATUS"; foreground: root.foreground }
        Text { text: root.listenerState.running === true ? "● Running" : "○ Stopped"; color: root.listenerState.running === true ? root.accent : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body }
        Text { text: "Key: " + (root.listenerState.keyInUse || "—") + (root.listenerState.broad === true ? "   ·   serving ALL local ports" : ""); color: root.listenerState.broad === true ? root.urgent : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        Text { visible: (root.listenerState.region || "") !== ""; text: "Region: " + root.listenerState.region; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }

        PanelSectionHeader { text: "LISTENER IDENTITY"; foreground: root.foreground }
        Row {
          spacing: Style.space(4)
          Repeater {
            model: root.identityChips()
            Button {
              text: modelData.name
              selected: modelData.selected
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              foreground: root.foreground
              accent: root.accent
              onClicked: root.listenerKey = modelData.key
            }
          }
        }
        Text { text: "Broad: with no services, all localhost ports are reachable through this address."; visible: (root.bridge.listener && root.bridge.listener.broad === true) || root.services.length === 0; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }

        PanelSectionHeader { text: "LAST RESULT"; foreground: root.foreground }
        Text {
          visible: root.connectResult !== null
          text: root.resultLine()
          color: root.connectResult && root.connectResult.ok ? root.accent : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---------------- Connect ----------------
      Column {
        visible: root.sectionIndex === 1
        width: parent.width
        spacing: Style.space(6)
        Text { text: "Connect to a Tailcat device. Paste a token (tc…) or a DNS name."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        TextField {
          id: connectTargetField
          width: parent.width
          placeholderText: "tcXXXXXXXXXX… or device.example.com"
          foreground: root.foreground
          accent: root.accent
          text: root.connectTarget
          onTextChanged: root.connectTarget = text
          onAccepted: root.runConnect()
          Keys.onEscapePressed: root.grabNavFocus()
        }
        Row {
          spacing: Style.space(6)
          Button { text: "Test"; onClicked: root.runValidate() }
          Button { text: "Connect"; onClicked: root.runConnect() }
        }
        Text { visible: root.connectResult !== null; text: root.resultLine(); color: root.connectResult && root.connectResult.ok ? root.accent : root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        PanelSeparator { width: parent.width; foreground: root.foreground }
        Text { text: "Save as device"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Row {
          spacing: Style.space(6)
          TextField {
            id: saveDeviceField
            width: parent.parent.width - 90
            placeholderText: "Device name (optional)"
            foreground: root.foreground
            accent: root.accent
            text: root.newDeviceName
            onTextChanged: root.newDeviceName = text
            onAccepted: root.saveCurrentAsDevice()
          }
          Button { text: "Save"; onClicked: root.saveCurrentAsDevice() }
        }
      }

      // ---------------- Devices ----------------
      Column {
        visible: root.sectionIndex === 2
        width: parent.width
        spacing: Style.space(6)
        Text { text: "Saved devices — j/k to move, Enter connect, c copy, p ping, n rename, d remove"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        Flickable {
          width: parent.width
          height: Math.min(220, root.height - 140)
          contentHeight: devCol.implicitHeight
          clip: true
          Column {
            id: devCol
            width: parent.width
            spacing: Style.space(4)
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
                    width: parent.width * 0.35
                    text: root.shortTarget(modelData.target)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                  Text {
                    width: parent.width * 0.2
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
            width: parent.parent.width - 90
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
        Text { visible: root.bridge.devices.length === 0; text: "No saved devices yet — add one in the Connect tab."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      }

      // ---------------- Identities ----------------
      Column {
        visible: root.sectionIndex === 3
        width: parent.width
        spacing: Style.space(6)
        Text { text: "Identities — j/k move, Enter use for listener, c create, d delete. Persistent identities keep a stable address."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        Flickable {
          width: parent.width
          height: Math.min(160, root.height - 220)
          contentHeight: idCol.implicitHeight
          clip: true
          Column {
            id: idCol
            width: parent.width
            spacing: Style.space(4)
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
          }
        }
        PanelSectionHeader { text: "CREATE"; foreground: root.foreground }
        Row {
          spacing: Style.space(6)
          TextField {
            id: newIdentityField
            width: parent.parent.width - 110
            placeholderText: "Identity name"
            foreground: root.foreground
            accent: root.accent
            text: root.newIdentityName
            onTextChanged: root.newIdentityName = text
            onAccepted: root.createIdentity()
          }
          Button { text: "Create"; onClicked: root.createIdentity() }
        }
        Row {
          spacing: Style.space(6)
          Toggle {
            label: "Client identity"
            description: "For --allow lists (no region)"
            checked: root.newIdentityClient
            onClicked: root.newIdentityClient = !root.newIdentityClient
          }
        }
        Button {
          visible: root.selectedIdentity() && root.selectedIdentity().persistent && root.selectedIdentity().name !== "new"
          text: "Delete “" + (root.selectedIdentity() ? root.selectedIdentity().name : "") + "”"
          onClicked: root.deleteSelectedIdentity()
        }
      }

      // ---------------- Services ----------------
      Column {
        visible: root.sectionIndex === 4
        width: parent.width
        spacing: Style.space(6)
        Text { text: "Shared services — what the listener serves. j/k move, Space toggle, a add, d remove."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        Flickable {
          width: parent.width
          height: Math.min(160, root.height - 250)
          contentHeight: svcCol.implicitHeight
          clip: true
          Column {
            id: svcCol
            width: parent.width
            spacing: Style.space(4)
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
          }
        }
        PanelSectionHeader { text: "ADD SERVICE"; foreground: root.foreground }
        Row {
          spacing: Style.space(6)
          TextField {
            id: addServiceField
            width: parent.parent.width - 130
            placeholderText: "Name (optional)"
            foreground: root.foreground
            accent: root.accent
            text: root.addServiceName
            onTextChanged: root.addServiceName = text
            onAccepted: root.addService()
          }
          Button { text: "Add"; onClicked: root.addService() }
        }
        Row {
          spacing: Style.space(6)
          Button {
            text: root.addServiceKind === "port-forward" ? "TCP port" : root.addServiceKind
            onClicked: root.cycleAddKind()
          }
          TextField {
            visible: root.addServiceKind === "port-forward"
            width: 80
            placeholderText: "port"
            foreground: root.foreground
            accent: root.accent
            text: root.addServicePort
            validator: IntValidator { bottom: 1; top: 65535 }
            onTextChanged: root.addServicePort = text
          }
          Button { text: "Remove sel"; onClicked: root.removeSelectedService() }
        }
        Text { text: "No services: the listener serves ALL localhost ports (broad). Add explicit services to restrict it."; visible: root.services.length === 0; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      }

      // ---------------- Diagnostics ----------------
      Column {
        visible: root.sectionIndex === 5
        width: parent.width
        spacing: Style.space(6)
        Text { text: "Diagnostics — r refreshes"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Text { text: "Tailcat: " + (root.bridge.available ? (root.bridge.version + (root.bridge.minOK ? "" : "  (older than supported)")) : "not installed"); color: root.bridge.available ? root.foreground : root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap }
        Text { visible: root.bridge.versionError !== ""; text: root.bridge.versionError; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        Text { text: "Backend: cli adapter"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Text { text: "Listener: " + (root.bridge.listener && root.bridge.listener.running === true ? "running" : "stopped"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
        Row {
          spacing: Style.space(6)
          Button { text: "Refresh"; onClicked: root.bridge.refreshDiagnostics() }
          Button { text: root.showDetails ? "Hide details" : "Details"; onClicked: root.showDetails = !root.showDetails }
        }
        Flickable {
          visible: root.showDetails
          width: parent.width
          height: 150
          contentHeight: logCol.implicitHeight
          clip: true
          Column {
            id: logCol
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

  function identityChips() {
    var out = []
    out.push({ key: "new", name: "Ephemeral", selected: root.listenerKey === "new" })
    for (var i = 0; i < bridge.identities.length; i++) {
      var idn = bridge.identities[i]
      if (idn.persistent && idn.name !== "new" && idn.kind !== "client") {
        out.push({ key: idn.name, name: idn.name, selected: root.listenerKey === idn.name })
      }
    }
    return out
  }

  function heroMeta() {
    if (!bridge.available) return "TAILCAT NOT INSTALLED"
    var st = bridge.listener || {}
    if (st.running === true) return "RUNNING · " + (st.keyInUse || "ephemeral")
    return "READY"
  }

  function heroDetail() {
    if (!bridge.available) return "Install `tailcat` (e.g. paru -S tailcat) and restart"
    var st = bridge.listener || {}
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
