import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — peer-to-peer device connection manager.
//
// The mental model is DEVICES + CAPABILITIES, never server/client:
//
//   This Device — this machine: is it reachable, its address, who may
//                 connect, receiving files.
//   Devices     — other machines: connect to them, SSH in, send files.
//   Services    — what this machine offers to others (SSH, folders, ports,
//                 exit node) — applies while "Allow connections" is on.
//   More        — identities, SOCKS proxy, diagnostics.
//
// Keyboard: Esc close · ? help · 1-4 switch tab · ←/→ switch tab (More: sub-page) ·
// m More · per-tab keys (see help + guide lines).
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

  property var sections: ["This Device", "Devices", "Services", "More"]
  property int sectionIndex: 0
  property var moreSections: ["Identities", "Proxy", "Diagnostics"]
  property int manageSection: 0

  // Expandable help ("?").
  property bool showHelp: false

  // Cursors for lists
  property int deviceCursor: 0
  property int identityCursor: 0
  property int offerCursor: 0

  // Listener identity selection ("new" = ephemeral, else saved key name)
  property string listenerKey: "new"

  // Connect state
  property string connectTarget: ""
  property var connectResult: null
  property string newDeviceName: ""
  property bool renaming: false
  property string renameText: ""

  // Services model (what "Allow connections" serves)
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

  // Files state
  property string recvDir: ""
  property string sendTarget: ""
  property string sendPath: ""
  // SFTP folder share (a "files" listener service)
  property string filesDir: ""
  property string filesMode: "ro"
  property bool filesShare: false

  // SSH
  property string sshTarget: ""
  property string sshPort: "22"
  property string sshUser: ""
  property string sshCmd: ""
  property string sshResult: ""

  // Proxy
  property string socksPort: ""
  property string socksTarget: ""
  property bool socksFixed: false

  // Allow list: which device public keys (nodekey:…) may connect.
  property var allowList: []
  property bool allowNone: false
  property string allowKeyInput: ""

  // Operations
  property string busyOp: ""
  property bool configuredSynced: false

  // Convenience view of the listener status (root-scope for QML children).
  readonly property var listenerState: root.bridge ? (root.bridge.listener || {}) : ({})

  // Height of the currently visible page, so the popup hugs its content.
  readonly property real pageImplicitHeight: {
    var body = 0
    var extra = (root.showHelp ? helpBlock.implicitHeight : 0)
             + (root.bridge && root.bridge.lastError !== "" ? errLine.implicitHeight : 0)
    var col = thisDeviceCol
    if (root.sectionIndex === 1) col = devicesCol
    else if (root.sectionIndex === 2) col = servicesCol
    else if (root.sectionIndex === 3) {
      col = moreCol
      body += manageNavRow ? manageNavRow.implicitHeight : 28
      body += Style.space(56) // guide line + separator + spacing
    }
    body += col ? col.implicitHeight : 0
    return body + hero.implicitHeight + topNav.implicitHeight + extra + Style.space(28)
  }
  implicitHeight: root.pageImplicitHeight

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refresh()
  }

  // Poll the file receiver while "This Device" is open.
  Timer {
    interval: 1000
    running: root.opened && root.sectionIndex === 0
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refreshFileRecv()
  }

  // Poll the SOCKS proxy while Proxy (More) is open.
  Timer {
    interval: 2000
    running: root.opened && root.sectionIndex === 3 && root.manageSection === 1
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refreshSocks()
  }

  // Sync the persisted serve spec into the local services list once per open.
  Connections {
    target: root.bridge
    function onStatusRefreshed() { root.syncConfigured() }
  }

  onOpenedChanged: {
    if (opened) Qt.callLater(function() {
      root.grabNavFocus()
      if (root.bridge) root.bridge.refresh()
    })
  }

  function grabNavFocus() { root.forceActiveFocus() }

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

  function fmtBytes(n) {
    var v = Number(n || 0)
    if (v >= 1 << 30) return (v / (1 << 30)).toFixed(1) + " GB"
    if (v >= 1 << 20) return (v / (1 << 20)).toFixed(1) + " MB"
    if (v >= 1 << 10) return (v / (1 << 10)).toFixed(1) + " KB"
    return v + " B"
  }

  function fmtAgo(t) {
    if (!t) return ""
    var ms = Date.parse(String(t))
    if (isNaN(ms)) return ""
    var d = (Date.now() - ms) / 1000
    if (d < 60) return "just now"
    if (d < 3600) return Math.round(d / 60) + "m ago"
    if (d < 86400) return Math.round(d / 3600) + "h ago"
    return Math.round(d / 86400) + "d ago"
  }

  // Load the persisted serve spec (services + key + files + allow list).
  function syncConfigured() {
    if (configuredSynced) return
    var cfg = root.bridge.configured
    if (!cfg) return
    configuredSynced = true
    var svcs = cfg.services || []
    if (svcs.length > 0) root.services = svcs
    if (cfg.key && cfg.key !== "") root.listenerKey = cfg.key
    if (cfg.filesDir) root.filesDir = cfg.filesDir
    if (cfg.filesMode) root.filesMode = cfg.filesMode
    if (cfg.allow) root.allowList = cfg.allow
    root.allowNone = !!cfg.allowNone
    for (var i = 0; i < svcs.length; i++) {
      if (svcs[i].kind === "files") {
        root.filesShare = true
        svcs[i].dir = root.filesDir
        svcs[i].mode = root.filesMode
        break
      }
    }
  }

  // ---- Listener actions (Allow connections) ----
  function startOrStop() {
    if (root.bridge.listener && root.bridge.listener.running === true) stopServer()
    else startServer()
  }
  function startServer() {
    busyOp = "start"
    root.bridge.startServer(services, listenerKey === "new" ? "new" : listenerKey, allowList, allowNone, function() { busyOp = "" })
  }
  function stopServer() {
    busyOp = "stop"
    root.bridge.stopServer(function() { busyOp = "" })
  }
  function restartServer() {
    busyOp = "restart"
    root.bridge.restartServer(services, listenerKey === "new" ? "new" : listenerKey, allowList, allowNone, function() { busyOp = "" })
  }
  function copyListenerAddr() {
    if (root.bridge.listener && root.bridge.listener.addr) root.copyText(root.bridge.listener.addr)
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

  function deviceChips() {
    var out = []
    for (var i = 0; i < root.bridge.devices.length; i++) {
      var d = root.bridge.devices[i]
      out.push({ name: d.name, target: d.target })
    }
    return out
  }

  function copyText(t) {
    if (!t) return
    Quickshell.execDetached(["wl-copy", "--", String(t)])
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
  // "Open SSH" for a device: fill the SSH form and jump to... just launch.
  function sshSelectedDevice() {
    var d = selectedDevice()
    if (!d) return
    if (!root.bridge.terminalOK) { root.bridge.lastError = "No terminal found — install ghostty/alacritty/kitty/foot"; return }
    busyOp = "ssh"
    root.bridge.sshOpen(d.target, "22", "", "", function(res) {
      busyOp = ""
      root.bridge.lastError = (res && res.ok) ? "" : ((res && res.message) || "Could not open SSH")
    })
  }
  // "Send file" for a device: fill the send form and jump to Files tab.
  function sendSelectedDevice() {
    var d = selectedDevice()
    if (!d) return
    root.sendTarget = d.target
    root.sectionIndex = 2
  }

  // ---- Identities ----
  function moveIdentityCursor(d) { identityCursor = clamp(identityCursor + d, 0, Math.max(0, root.bridge.identities.length - 1)) }
  function selectedIdentity() { return root.bridge.identities.length ? root.bridge.identities[identityCursor] : null }
  function useSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent) { listenerKey = i.name; sectionIndex = 0 } }
  function deleteSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent && i.name !== "new") confirmDeleteIdentity.targetName = i.name }

  // ---- Services (capability toggles) ----
  function hasService(kind) {
    for (var i = 0; i < root.services.length; i++)
      if (root.services[i].kind === kind && root.services[i].enabled !== false) return true
    return false
  }
  function toggleServiceKind(kind, name) {
    var svcs = root.services.slice()
    var removed = svcs.filter(function(s) { return s.kind !== kind })
    if (removed.length === svcs.length) {
      // wasn't there → add
      svcs = svcs.concat([{ name: name, kind: kind, port: 0, enabled: true }])
    } else {
      svcs = removed
    }
    root.services = svcs
    root.bridge.lastError = "Services apply on restart — Restart the listener to apply."
  }
  function addPortForward() {
    var port = parseInt(addServicePort, 10)
    if (!(port >= 1 && port <= 65535)) { root.bridge.lastError = "Port must be 1–65535"; return }
    if (root.services.some(function(s) { return s.kind === "port-forward" && s.port === port })) {
      root.bridge.lastError = "Port " + port + " is already added"
      return
    }
    root.services = root.services.concat([{ name: "Port " + port, kind: "port-forward", port: port, enabled: true }])
    root.bridge.lastError = ""
  }
  function removeServiceAt(i) {
    root.services = root.services.filter(function(_, idx) { return idx !== i })
  }
  function removePortForward(port) {
    root.services = root.services.filter(function(s) { return !(s.kind === "port-forward" && s.port === port) })
  }

  // ---- SSH ----
  function openSSH() {
    var t = sshTarget.trim()
    if (!t) { root.bridge.lastError = "Enter a target (tc… token or DNS name)"; return }
    if (!root.bridge.terminalOK) { root.bridge.lastError = "No terminal found — set OMARCHY_TAILCAT_TERMINAL or install ghostty/alacritty/kitty/foot"; return }
    busyOp = "ssh"
    root.bridge.sshOpen(t, sshPort, sshUser, sshCmd, function(res) {
      busyOp = ""
      if (res && res.ok) {
        root.bridge.lastError = ""
        sshResult = "SSH opened in " + (res.terminal || "terminal")
      } else {
        sshResult = ""
        root.bridge.lastError = (res && res.message) || "Could not open SSH"
      }
    })
  }
  function sshCommandString() {
    var parts = ["tailcat", "ssh"]
    var p = sshPort.trim()
    if (p !== "" && p !== "22") parts.push("-p", p)
    var dest = sshTarget.trim()
    var u = sshUser.trim()
    if (u !== "") dest = u + "@" + dest
    parts.push(dest)
    var c = sshCmd.trim()
    if (c !== "") parts = parts.concat(c.split(/\s+/))
    return parts.join(" ")
  }
  function copySSHCommand() {
    if (sshTarget.trim()) copyText(sshCommandString())
  }

  // ---- Files: receive ----
  function moveOfferCursor(d) { offerCursor = clamp(offerCursor + d, 0, Math.max(0, root.bridge.fileRecvPending.length - 1)) }
  function selectedOffer() { return root.bridge.fileRecvPending.length ? root.bridge.fileRecvPending[offerCursor] : null }
  function acceptSelectedOffer() { var o = selectedOffer(); if (o && o.state === "offered") root.bridge.fileRecvRespond(o.id, true, "") }
  function rejectSelectedOffer() { var o = selectedOffer(); if (o && o.state === "offered") root.bridge.fileRecvRespond(o.id, false, "") }
  function toggleRecv() {
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true) root.bridge.fileRecvStop()
    else root.bridge.fileRecvStart(recvDir, "")
  }
  function doSendFile() {
    var t = sendTarget.trim()
    var p = sendPath.trim()
    if (!t) { root.bridge.lastError = "Enter a target (paste a token or pick a device)"; return }
    if (!p) { root.bridge.lastError = "Enter a file path"; return }
    root.bridge.fileSend(t, p, "")
  }
  function browseSendFile() {
    root.bridge.pick("file", function(p) { if (p) { root.sendPath = p } })
  }
  function browseRecvDir() {
    root.bridge.pick("dir", function(p) { if (p) root.recvDir = p })
  }
  function browseFilesDir() {
    root.bridge.pick("dir", function(p) { if (p) { root.filesDir = p; root.updateFilesEntry() } })
  }
  function sendPct() {
    if (root.bridge.sendTotal <= 0) return 0
    return Math.max(0, Math.min(1, root.bridge.sendSent / root.bridge.sendTotal))
  }

  // ---- Files: SFTP folder share ----
  function filesServiceEntry() {
    for (var i = 0; i < root.services.length; i++)
      if (root.services[i].kind === "files") return root.services[i]
    return null
  }
  function setFilesShare(on) {
    root.filesShare = on
    if (on) {
      if (!filesServiceEntry()) {
        root.services = root.services.concat([{ name: "File share", kind: "files", port: 0, enabled: true, dir: root.filesDir, mode: root.filesMode }])
      } else {
        var e = filesServiceEntry()
        e.enabled = true
        root.services = root.services.slice()
      }
    } else if (filesServiceEntry()) {
      root.services = root.services.filter(function(x) { return x.kind !== "files" })
    }
  }
  function updateFilesEntry() {
    var e = filesServiceEntry()
    if (e) {
      e.dir = root.filesDir
      e.mode = root.filesMode
      root.services = root.services.slice()
    }
  }

  // ---- Proxy ----
  function toggleSocks() {
    if (root.bridge.socksState && root.bridge.socksState.running === true) root.bridge.socksStop()
    else {
      busyOp = "socks"
      root.bridge.socksStart(socksPort, socksFixed ? socksTarget : "", function() { busyOp = "" })
    }
  }
  function copySocksAddr() {
    if (root.bridge.socksState && root.bridge.socksState.addr) root.copyText(root.bridge.socksState.addr)
  }
  function exitNodeOn() {
    var svcs = root.bridge.listener && root.bridge.listener.services ? root.bridge.listener.services : []
    for (var i = 0; i < svcs.length; i++) if (svcs[i].kind === "exit-node") return true
    return false
  }

  // ---- Allow list ----
  function addAllowKey() {
    var k = String(allowKeyInput || "").trim()
    if (!k) { root.bridge.lastError = "Paste a device key (nodekey:…) to allow"; return }
    if (k.indexOf("nodekey:") !== 0) { root.bridge.lastError = "Device keys start with nodekey:"; return }
    if (allowList.indexOf(k) >= 0) { root.bridge.lastError = "That key is already allowed"; return }
    allowList = allowList.concat([k])
    allowKeyInput = ""
    root.bridge.lastError = ""
  }
  function removeAllowKey(i) { allowList = allowList.filter(function(_, idx) { return idx !== i }) }
  function clearAllowList() { allowList = []; allowNone = false }
  function usingFixedKey() { return root.listenerKey !== "new" && root.listenerKey !== "" }
  function allowUnsafe() { return !root.allowNone && root.allowList.length === 0 }

  // ---- One-click secure link (fixed address + only allowed devices) ----
  function setupSecureLink() {
    if (busyOp !== "") return
    busyOp = "securelink"
    root.bridge.lastError = ""
    ensureServerIdentity(function(ok) {
      if (!ok) { busyOp = ""; root.bridge.lastError = "Could not create the server identity"; return }
      ensureClientIdentity(function(nk) {
        if (!nk) { busyOp = ""; root.bridge.lastError = "Could not set up this machine's device key"; return }
        var list = root.allowList.slice()
        if (list.indexOf(nk) < 0) list = list.concat([nk])
        root.allowList = list
        root.allowNone = false
        root.listenerKey = "default"
        busyOp = ""
        root.bridge.lastError = "Secure link ready — fixed address, only allowed devices can connect. Copy it to the other machine."
        root.restartServer()
      })
    })
  }
  function ensureServerIdentity(cb) {
    for (var i = 0; i < root.bridge.identities.length; i++)
      if (root.bridge.identities[i].name === "default") { cb(true); return }
    root.bridge.createIdentity("default", "server", "", function() { cb(true) }, function() { cb(false) })
  }
  function ensureClientIdentity(cb) {
    for (var i = 0; i < root.bridge.identities.length; i++)
      if (root.bridge.identities[i].name === "client-default") { fetchClientPub(cb); return }
    root.bridge.createIdentity("client-default", "client", "", function() { fetchClientPub(cb) }, function() { cb("") })
  }
  function fetchClientPub(cb) {
    root.bridge.identityPub(function(d) { cb(d && d.publicKey || "") })
  }
  function secureLinkStatus() {
    if (root.allowNone) return "● Blocked: fixed address, no device can connect yet"
    if (root.usingFixedKey() && root.allowList.length > 0)
      return "● Fixed address · " + root.allowList.length + " allowed device" + (root.allowList.length > 1 ? "s" : "")
    if (root.usingFixedKey()) return "⚠ Fixed address · no devices allowed — anyone with the address can connect"
    return "○ Temporary address (changes each start) · open to anyone with it"
  }

  // ---- Connect (used by device add) ----
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
    var st = root.bridge.listener || {}
    if (st.running === true) return "ACCEPTING CONNECTIONS"
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true) return "RECEIVING FILES"
    if (root.bridge.socksState && root.bridge.socksState.running === true) return "PROXY ON"
    return "READY"
  }

  function heroDetail() {
    if (!root.bridge.available) return "Install `tailcat` (e.g. paru -S tailcat) and restart"
    var st = root.bridge.listener || {}
    if (st.running === true && st.addr) return shortTarget(st.addr)
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true && root.bridge.fileRecvState.addr) {
      return "Receiving: " + shortTarget(root.bridge.fileRecvState.addr)
    }
    if (root.bridge.socksState && root.bridge.socksState.running === true && root.bridge.socksState.addr) {
      return "Proxy: " + root.bridge.socksState.addr
    }
    return "Not accepting connections"
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

  function manageGuide() {
    switch (root.manageSection) {
    case 0: return "Identities — j/k select · Enter use · c create · d delete. Persistent = stable address, ephemeral = new each session"
    case 1: return "SOCKS5 proxy — run a local proxy that dials tailcat devices; copy the address into apps."
    case 2: return "Diagnostics — r refresh · Details shows the (redacted) server log"
    }
    return ""
  }

  function shortcutLine() {
    switch (root.sectionIndex) {
    case 0: return "s allow on/off · p ping · c copy · 1-4 tab · m more · ? help"
    case 1: return "j/k select · Enter connect · s ssh · f send file · c copy · p ping · n rename · d remove"
    case 2: return "a add port · r restart listener · 1-4 tab · m more · ? help"
    case 3: return "←/→ sub-page · j/k · Enter · c create · d delete · m more · ? help"
    }
    return ""
  }

  // ---- Keyboard ----
  Keys.onPressed: function(event) {
    var key = event.key
    if (key === Qt.Key_Escape) { root.closeRequested(); event.accepted = true; return }
    if (key === Qt.Key_Question || (key === Qt.Key_Slash && (event.modifiers & Qt.ControlModifier))) { showHelp = !showHelp; event.accepted = true; return }
    if (key === Qt.Key_M) { root.sectionIndex = 3; event.accepted = true; return }
    if (key >= Qt.Key_1 && key <= Qt.Key_4) { root.sectionIndex = key - Qt.Key_1; event.accepted = true; return }
    if (key === Qt.Key_Left || key === Qt.Key_Right) {
      if (root.sectionIndex === 3) {
        root.manageSection = clamp(root.manageSection + (key === Qt.Key_Left ? -1 : 1), 0, root.moreSections.length - 1)
      } else {
        root.sectionIndex = clamp(root.sectionIndex + (key === Qt.Key_Left ? -1 : 1), 0, root.sections.length - 1)
      }
      event.accepted = true
      return
    }
    switch (root.sectionIndex) {
    case 0: // This Device
      if (key === Qt.Key_S) { startOrStop(); event.accepted = true }
      else if (key === Qt.Key_P) { pingSelf(true); event.accepted = true }
      else if (key === Qt.Key_C) { copyListenerAddr(); event.accepted = true }
      else if (key === Qt.Key_R) { toggleRecv(); event.accepted = true }
      else if (key === Qt.Key_J || key === Qt.Key_Down) { moveOfferCursor(1); event.accepted = true }
      else if (key === Qt.Key_K || key === Qt.Key_Up) { moveOfferCursor(-1); event.accepted = true }
      else if (key === Qt.Key_A) { acceptSelectedOffer(); event.accepted = true }
      else if (key === Qt.Key_D) { rejectSelectedOffer(); event.accepted = true }
      break
    case 1: // Devices
      if (key === Qt.Key_J || key === Qt.Key_Down) { moveDeviceCursor(1); event.accepted = true }
      else if (key === Qt.Key_K || key === Qt.Key_Up) { moveDeviceCursor(-1); event.accepted = true }
      else if (key === Qt.Key_C) { copyDevice(); event.accepted = true }
      else if (key === Qt.Key_P) { pingSelectedDevice(); event.accepted = true }
      else if (key === Qt.Key_S) { sshSelectedDevice(); event.accepted = true }
      else if (key === Qt.Key_F) { sendSelectedDevice(); event.accepted = true }
      else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) { connectSelectedDevice(); event.accepted = true }
      else if (key === Qt.Key_N) { startRename(); event.accepted = true }
      else if (key === Qt.Key_X) { removeSelectedDevice(); event.accepted = true }
      break
    case 2: // Services
      if (key === Qt.Key_A) { addPortField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_R) { restartServer(); event.accepted = true }
      break
    case 3: // More
      switch (root.manageSection) {
      case 0: // Identities
        if (key === Qt.Key_J || key === Qt.Key_Down) { moveIdentityCursor(1); event.accepted = true }
        else if (key === Qt.Key_K || key === Qt.Key_Up) { moveIdentityCursor(-1); event.accepted = true }
        else if (key === Qt.Key_C) { newIdentityField.forceActiveFocus(); event.accepted = true }
        else if (key === Qt.Key_X) { deleteSelectedIdentity(); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter) { useSelectedIdentity(); event.accepted = true }
        break
      case 1: // Proxy
        if (key === Qt.Key_S) { toggleSocks(); event.accepted = true }
        break
      case 2: // Diagnostics
        if (key === Qt.Key_R) { root.bridge.refreshDiagnostics(); event.accepted = true }
        break
      }
      break
    }
  }

// ---- Render ----
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

    // Tab nav.
    Row {
      id: topNav
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
      id: errLine
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
      id: helpBlock
      Layout.fillWidth: true
      visible: root.showHelp
      spacing: Style.space(3)
      Text { width: parent.width; text: "THIS DEVICE  Turn on Allow connections to let other devices reach this machine, get its address, and choose who can connect (fixed address + allowed device keys). Also receive files here. Keys: s/p/c/r."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "DEVICES  Other machines you connect to: add one with the address from their This Device view, then Connect / SSH / send files. Keys: j/k · Enter · s · f."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "SERVICES  What this machine offers while Allow connections is on: SSH, shared folders (SFTP), ports, exit node. Changes apply on listener restart. Keys: a add port · r restart."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "NAV  1-4 switch tab · ←/→ switch tab (More: sub-page) · m More · ? help · Esc close"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "STUCK?  Ask an AI agent — share this panel or the Diagnostics tab, and it can walk you through setup, transfers, and troubleshooting."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
    }

    // ---- content area ----
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true

      // ============ THIS DEVICE ============
      Flickable {
        visible: root.sectionIndex === 0
        anchors.fill: parent
        contentHeight: thisDeviceCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: thisDeviceCol
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "THIS DEVICE"; foreground: root.foreground }
          // Status + address + copy.
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: root.listenerState.running === true ? "● Accepting connections" : "○ Not accepting"
              color: root.listenerState.running === true ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Item { Layout.fillWidth: true; height: 1 }
            Text {
              visible: root.listenerState.running === true
              text: root.shortTarget(root.listenerState.addr)
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
            Button {
              visible: root.listenerState.running === true
              text: "Copy"
              onClicked: root.copyListenerAddr()
            }
          }
          Toggle {
            label: "Allow connections from other devices"
            description: root.listenerState.running === true ? "This machine's address is shareable now" : "Turn on to share this machine's address"
            checked: root.listenerState.running === true
            onClicked: root.startOrStop()
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            Button { text: "Ping"; enabled: root.listenerState.running === true; onClicked: root.pingSelf(true) }
            Button { text: "Restart"; enabled: root.listenerState.running === true; onClicked: root.restartServer() }
          }

          // ---- Who can connect ----
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "WHO CAN CONNECT"; foreground: root.foreground }
          Text {
            width: parent.width
            text: root.secureLinkStatus()
            color: (root.allowNone || (root.usingFixedKey() && root.allowUnsafe())) ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: "⚡ Secure link — fixed address + only my devices"
              onClicked: root.setupSecureLink()
            }
            Button {
              text: "Copy address"
              enabled: root.listenerState.running === true
              onClicked: root.copyListenerAddr()
            }
          }
          Text {
            width: parent.width
            text: "One click: makes this machine's address permanent and allows only your own device (and any key you add below). To let another machine in, paste its device key below."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.allowList
            Rectangle {
              width: parent.width
              height: allowRow.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)
              Row {
                id: allowRow
                anchors.fill: parent
                anchors.margins: Style.space(3)
                spacing: Style.space(6)
                Text {
                  width: parent.width - 130
                  text: String(modelData).length > 28 ? String(modelData).substr(0, 10) + "…" + String(modelData).substr(-8) : modelData
                  color: root.foreground
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
                Button { text: "Copy"; onClicked: root.copyText(modelData) }
                Button { text: "Remove"; onClicked: root.removeAllowKey(index) }
              }
            }
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: allowKeyField
              Layout.fillWidth: true
              placeholderText: "Paste another device's key (nodekey:…) to allow it"
              foreground: root.foreground
              accent: root.accent
              text: root.allowKeyInput
              onTextChanged: root.allowKeyInput = text
              onAccepted: root.addAllowKey()
            }
            Button { text: "Allow device"; onClicked: root.addAllowKey() }
            Button { text: "Clear"; enabled: root.allowList.length > 0; onClicked: root.clearAllowList() }
          }
          Toggle {
            label: "Block everyone until I allow a device"
            description: "Safest while you add device keys"
            checked: root.allowNone
            onClicked: { root.allowNone = !root.allowNone; if (root.allowNone) root.allowList = [] }
          }

          // ---- Receive files ----
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "RECEIVE FILES"; foreground: root.foreground }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Toggle {
              label: "Receive files from other devices"
              description: "Shares a receive address; you accept each file"
              checked: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true
              onClicked: root.toggleRecv()
            }
            TextField {
              Layout.fillWidth: true
              placeholderText: "Recv dir (default ~/Downloads)"
              foreground: root.foreground
              accent: root.accent
              text: root.recvDir
              onTextChanged: root.recvDir = text
            }
            Button { text: "Browse…"; onClicked: root.browseRecvDir() }
          }
          Row {
            visible: root.bridge.fileRecvState && !!root.bridge.fileRecvState.addr
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width - 90
              text: "Receive address: " + root.shortTarget(root.bridge.fileRecvState.addr)
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
            text: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "Waiting for incoming… → " + (root.recvDir.trim() || "~/Downloads") : "Incoming files show up here when receiving is on"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
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
            visible: root.bridge.fileRecvDone.length > 0
            text: "Done: " + root.bridge.fileRecvDone.map(function(d) { return d.name + (d.ok ? " ✓" : " ✗") }).join("  ·  ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: root.connectResult !== null
            text: "Last: " + root.resultLine()
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

      // ============ DEVICES ============
      Flickable {
        visible: root.sectionIndex === 1
        anchors.fill: parent
        contentHeight: devicesCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: devicesCol
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          Text {
            width: parent.width
            text: "Other machines you connect to. Add one with the address from its This Device view (or paste a token)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
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
                  width: parent.width * 0.34
                  text: root.shortTarget(modelData.target)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
                Text {
                  width: parent.width * 0.22
                  text: modelData.lastConnectedAt ? ("seen " + root.fmtAgo(modelData.lastConnectedAt)) : "never"
                  color: modelData.lastConnectedAt ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.deviceCursor = index
                onDoubleClicked: root.connectDevice(modelData.id)
              }
            }
          }
          Text {
            visible: root.bridge.devices.length === 0
            width: parent.width
            text: "No devices yet. Paste a token below (from the other machine's This Device view) and save it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
          Row {
            visible: root.bridge.devices.length > 0
            spacing: Style.space(6)
            Button { text: "Connect"; onClicked: root.connectSelectedDevice() }
            Button { text: "SSH"; onClicked: root.sshSelectedDevice() }
            Button { text: "Send file"; onClicked: root.sendSelectedDevice() }
            Button { text: "Ping"; onClicked: root.pingSelectedDevice() }
            Button { text: "Copy"; onClicked: root.copyDevice() }
            Button { text: "Rename"; onClicked: root.startRename() }
            Button { text: "Remove"; onClicked: root.removeSelectedDevice() }
          }
          Row {
            visible: root.renaming
            width: parent.width
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
            }
            Button { text: "Save"; onClicked: root.commitRename() }
          }
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
          PanelSectionHeader { text: "ADD DEVICE"; foreground: root.foreground }
          Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: saveDeviceField
              Layout.fillWidth: true
              placeholderText: "Paste tc… or DNS name"
              foreground: root.foreground
              accent: root.accent
              text: root.connectTarget
              onTextChanged: root.connectTarget = text
              onAccepted: root.saveCurrentAsDevice()
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
          Text {
            width: parent.width
            visible: root.connectResult !== null
            text: "Last: " + root.resultLine()
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

      // ============ SERVICES ============
      Flickable {
        visible: root.sectionIndex === 2
        anchors.fill: parent
        contentHeight: servicesCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: servicesCol
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          Text {
            width: parent.width
            text: "What this machine offers to other devices — while Allow connections is on. Changes apply when you restart the listener."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // SSH
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            Toggle {
              label: "SSH access"
              description: "Let devices SSH in without a password (tunnel = identity)"
              checked: root.hasService("no-auth-ssh")
              onClicked: root.toggleServiceKind("no-auth-ssh", "SSH access")
            }
          }

          // Share folder over SFTP
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            Toggle {
              label: "Share a folder (SFTP)"
              description: "scp/sftp clients can access a directory"
              checked: root.hasService("files")
              onClicked: root.setFilesShare(!root.hasService("files"))
            }
          }
          RowLayout {
            visible: root.hasService("files")
            width: parent.width
            spacing: Style.space(4)
            TextField {
              Layout.fillWidth: true
              placeholderText: "Folder to share (default ~/Downloads, read-only)"
              foreground: root.foreground
              accent: root.accent
              text: root.filesDir
              onTextChanged: { root.filesDir = text; root.updateFilesEntry() }
            }
            Button { text: "Browse…"; onClicked: root.browseFilesDir() }
          }
          Row {
            visible: root.hasService("files")
            width: parent.width
            spacing: Style.space(4)
            Text { text: "Mode:"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Repeater {
              model: ["ro", "rw", "wo"]
              Button {
                text: modelData
                selected: root.filesMode === modelData
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.sm
                foreground: root.foreground
                accent: root.accent
                onClicked: { root.filesMode = modelData; root.updateFilesEntry() }
              }
            }
            Text {
              Layout.fillWidth: true
              text: "(ro read-only · rw read-write · wo drop box)"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Exit node
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            Toggle {
              label: "Exit node (route through this machine's network)"
              description: "Other devices can reach IPs on this machine's LAN"
              checked: root.hasService("exit-node")
              onClicked: root.toggleServiceKind("exit-node", "Exit node")
            }
          }

          // Port forwards
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "PORT FORWARDS"; foreground: root.foreground }
          Repeater {
            model: root.services.filter(function(s) { return s.kind === "port-forward" })
            Rectangle {
              width: parent.width
              height: portRow.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)
              Row {
                id: portRow
                anchors.fill: parent
                anchors.margins: Style.space(3)
                spacing: Style.space(6)
                Text {
                  Layout.fillWidth: true
                  text: "Port " + modelData.port
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Button { text: "Remove"; onClicked: root.removePortForward(modelData.port) }
              }
            }
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: addPortField
              width: 80
              placeholderText: "port"
              foreground: root.foreground
              accent: root.accent
              text: root.addServicePort
              validator: IntValidator { bottom: 1; top: 65535 }
              onTextChanged: root.addServicePort = text
              onAccepted: root.addPortForward()
            }
            Button { text: "Add port"; onClicked: root.addPortForward() }
            Item { Layout.fillWidth: true; height: 1 }
            Button { text: "Restart listener"; onClicked: root.restartServer() }
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

      // ============ MORE ============
      Flickable {
        visible: root.sectionIndex === 3
        anchors.fill: parent
        contentHeight: moreCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: moreCol
          width: parent.width
          spacing: Style.space(4)

          Row {
            id: manageNavRow
            spacing: Style.space(3)
            Repeater {
              model: root.moreSections
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
          Text {
            width: parent.width
            text: root.manageGuide()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }

          // --- Identities ---
          Column {
            visible: root.manageSection === 0
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
                    text: modelData.persistent ? (modelData.kind === "client" ? "device key" : "saved") : "ephemeral"
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
            PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
            Row {
              width: parent.width
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
              label: "Device key (for allowing this machine on others)"
              description: "Creates a client identity; its nodekey goes in the other machine's allow list"
              checked: root.newIdentityClient
              onClicked: root.newIdentityClient = !root.newIdentityClient
            }
          }

          // --- Proxy (SOCKS5) ---
          Column {
            visible: root.manageSection === 1
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "SOCKS5 PROXY"; foreground: root.foreground }
            Text {
              width: parent.width
              text: "Run a local SOCKS5 proxy that dials tailcat devices — use it to reach a device's network (e.g. a LAN) or route apps through another machine. Copy the socks5h://… address into apps."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              Button {
                text: root.bridge.socksState && root.bridge.socksState.running === true ? "Stop" : "Start"
                onClicked: root.toggleSocks()
              }
              Button {
                text: "Copy"
                visible: root.bridge.socksState && root.bridge.socksState.running === true
                onClicked: root.copySocksAddr()
              }
              Item { Layout.fillWidth: true; height: 1 }
              Text {
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                text: root.bridge.socksState && root.bridge.socksState.running === true ? "● Proxy on " + (root.bridge.socksState.addr || "") : "○ Off"
                color: root.bridge.socksState && root.bridge.socksState.running === true ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            RowLayout {
              width: parent.width
              spacing: Style.space(4)
              TextField {
                width: 80
                placeholderText: "Port (blank = auto)"
                foreground: root.foreground
                accent: root.accent
                text: root.socksPort
                validator: IntValidator { bottom: 0; top: 65535 }
                onTextChanged: root.socksPort = text
              }
              Toggle {
                label: "Route everything through one device"
                checked: root.socksFixed
                onClicked: { root.socksFixed = !root.socksFixed; if (!root.socksFixed) root.socksTarget = "" }
              }
              TextField {
                visible: root.socksFixed
                Layout.fillWidth: true
                placeholderText: "That device's tc… token"
                foreground: root.foreground
                accent: root.accent
                text: root.socksTarget
                onTextChanged: root.socksTarget = text
              }
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

          // --- Diagnostics ---
          Column {
            visible: root.manageSection === 2
            width: parent.width
            spacing: Style.space(5)
            Text { width: parent.width; text: "Tailcat: " + (root.bridge.available ? (root.bridge.version + (root.bridge.minOK ? "" : "  (older than supported)")) : "not installed"); color: root.bridge.available ? root.foreground : root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap }
            Text { width: parent.width; visible: root.bridge.versionError !== ""; text: root.bridge.versionError; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            Text { width: parent.width; text: "Connections: " + (root.bridge.listener && root.bridge.listener.running === true ? "accepting" : "not accepting") + " ·  Receiving: " + (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "on" : "off") + " ·  Proxy: " + (root.bridge.socksState && root.bridge.socksState.running === true ? "on" : "off"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
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
      }
    }
  }

  // Confirm dialogs
  ConfirmDialog {
    id: confirmRemoveDevice
    property var targetDevice: null
    opened: targetDevice !== null
    message: targetDevice ? "Remove “" + targetDevice.name + "” from devices?" : ""
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
