import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Tailcat Manager — the popup content, organized into primary tabs:
//
//   Status — the listener: start/stop/restart/ping, running services, address,
//            identity key. The "control room" for what this machine serves.
//   SSH    — connect the system ssh client through a tailcat server (opens a
//            terminal window).
//   Files  — receive files (accept/reject + progress), send files, and share a
//            folder over SFTP (scp/sftp) as a listener service.
//   Proxy  — run a SOCKS5 proxy that dials tailcat servers, and toggle
//            exit-node routing on the listener.
//   Manage — saved devices, identities, listener services, diagnostics.
//
// Keyboard: Esc close · ? help · ←/→ switch tab · 1-5 jump to tab · m Manage ·
// per-tab keys: Status s/r/p/c · SSH o/c/t · Files r/s/j/k/a/d/t/f/b/Enter ·
// Proxy s/e · Manage j/k/Enter/c/p/n/x/a/Space (see guide lines + help block).
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

  // Primary tabs.
  property var sections: ["Status", "SSH", "Files", "Proxy", "Manage"]
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

  // Services model (what Start serves). Configured spec is loaded from the
  // backend on open (syncConfigured) and re-saved on every start/restart.
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

  // SSH tab
  property string sshTarget: ""
  property string sshPort: "22"
  property string sshUser: ""
  property string sshCmd: ""
  property string sshResult: ""

  // Proxy tab
  property string socksPort: ""
  property string socksTarget: ""
  property bool socksFixed: false

  // Operations
  property string busyOp: ""
  property var pendingPing: null
  property bool configuredSynced: false

  // Convenience view of the listener status (root-scope for QML children).
  readonly property var listenerState: root.bridge ? (root.bridge.listener || {}) : ({})

  // Height of the currently visible page, so the popup can hug its content.
  readonly property real pageImplicitHeight: {
    var body = 0
    var extra = (root.showHelp ? helpBlock.implicitHeight : 0)
             + (root.bridge && root.bridge.lastError !== "" ? errLine.implicitHeight : 0)
    var col = statusCol
    if (root.sectionIndex === 1) col = sshCol
    else if (root.sectionIndex === 2) col = filesCol
    else if (root.sectionIndex === 3) col = proxyCol
    else if (root.sectionIndex === 4) col = manageCol
    body = col ? col.implicitHeight : 0
    if (root.sectionIndex === 4) {
      body += manageNavRow ? manageNavRow.implicitHeight : 28
      body += Style.space(56) // guide line + separator + spacing
    }
    return body + hero.implicitHeight + topNav.implicitHeight + extra + Style.space(28)
  }
  implicitHeight: root.pageImplicitHeight

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refresh()
  }

  // Poll the file receiver while the Files tab is open.
  Timer {
    interval: 1000
    running: root.opened && root.sectionIndex === 2
    repeat: true
    onTriggered: if (root.bridge && !root.bridge.busy) root.bridge.refreshFileRecv()
  }

  // Poll the SOCKS proxy while the Proxy tab is open.
  Timer {
    interval: 2000
    running: root.opened && root.sectionIndex === 3
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

  // fmtBytes must live here too: the bridge's copy is not visible to root.*.
  function fmtBytes(n) {
    var v = Number(n || 0)
    if (v >= 1 << 30) return (v / (1 << 30)).toFixed(1) + " GB"
    if (v >= 1 << 20) return (v / (1 << 20)).toFixed(1) + " MB"
    if (v >= 1 << 10) return (v / (1 << 10)).toFixed(1) + " KB"
    return v + " B"
  }

  // Load the persisted serve spec (services + key + files dir/mode) so the
  // Services page and exit-node toggle reflect what the listener was started
  // with, instead of a QML-local empty list that silently serves all ports.
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
    for (var i = 0; i < svcs.length; i++) {
      if (svcs[i].kind === "files") {
        root.filesShare = true
        // The persisted dir/mode live on the spec, not the service entry;
        // attach them so a restart keeps the same folder.
        svcs[i].dir = root.filesDir
        svcs[i].mode = root.filesMode
        break
      }
    }
  }

  // ---- Listener actions (Status tab) ----
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
    // wl-copy -- <text>: pass text as argv (no shell, no stdin-EOF dependency).
    Quickshell.execDetached(["wl-copy", "--", String(t)])
  }

  // ---- Devices (Manage) ----
  function moveDeviceCursor(d) { deviceCursor = clamp(deviceCursor + d, 0, Math.max(0, root.bridge.devices.length - 1)) }
  function selectedDevice() { return root.bridge.devices.length ? root.bridge.devices[deviceCursor] : null }
  function copyDevice() { var d = selectedDevice(); if (d) copyText(d.target) }
  function pingSelectedDevice() { var d = selectedDevice(); if (d) pingDevice(d.id) }
  function connectSelectedDevice() { var d = selectedDevice(); if (d) connectDevice(d.id) }
  function removeSelectedDevice() { var d = selectedDevice(); if (d) confirmRemoveDevice.targetDevice = d }
  function startRename() { var d = selectedDevice(); if (d) { renameText = d.name; renaming = true; renameField.forceActiveFocus() } }
  function commitRename() { var d = selectedDevice(); if (d && renameText.trim()) root.bridge.renameDevice(d.id, renameText.trim()); renaming = false }

  // ---- Identities (Manage) ----
  function moveIdentityCursor(d) { identityCursor = clamp(identityCursor + d, 0, Math.max(0, root.bridge.identities.length - 1)) }
  function selectedIdentity() { return root.bridge.identities.length ? root.bridge.identities[identityCursor] : null }
  function useSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent) { listenerKey = i.name; sectionIndex = 0 } }
  function deleteSelectedIdentity() { var i = selectedIdentity(); if (i && i.persistent && i.name !== "new") confirmDeleteIdentity.targetName = i.name }

  // ---- Services (Manage) ----
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

  // ---- SSH tab ----
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

  // ---- Files tab: receive ----
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
    root.bridge.pick("file", function(p) { if (p) { root.sendPath = p; homePathField.forceActiveFocus() } })
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

  // ---- Files tab: SFTP folder share ----
  function filesServiceEntry() {
    for (var i = 0; i < root.services.length; i++)
      if (root.services[i].kind === "files") return root.services[i]
    return null
  }
  function setFilesShare(on) {
    root.filesShare = on
    var e = filesServiceEntry()
    if (on) {
      if (!e) {
        root.services = root.services.concat([{ name: "File share", kind: "files", port: 0, enabled: true, dir: root.filesDir, mode: root.filesMode }])
      } else {
        e.enabled = true
        root.services = root.services.slice()
      }
    } else if (e) {
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

  // ---- Proxy tab ----
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
  function toggleExitNode() {
    var on = root.exitNodeOn()
    var svcs = root.services.slice().filter(function(s) { return s.kind !== "exit-node" })
    if (!on) svcs = svcs.concat([{ name: "Exit node", kind: "exit-node", port: 0, enabled: true }])
    root.services = svcs
    if (root.bridge.listener && root.bridge.listener.running === true) {
      root.restartServer()
      root.bridge.lastError = on ? "Exit node removed — listener restarted" : "Exit node added — listener restarted"
    } else {
      root.bridge.lastError = on ? "Exit node removed from services" : "Exit node added to services — start the listener to apply"
    }
  }

  // ---- Connect (kept for Manage → device add) ----
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
    if (st.running === true) return "RUNNING · " + (st.keyInUse || "ephemeral")
    if (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true) return "RECEIVING"
    if (root.bridge.socksState && root.bridge.socksState.running === true) return "PROXY"
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
    switch (root.sectionIndex) {
    case 0: return "s start/stop · r restart · p ping · c copy · m manage · ? help"
    case 1: return "o open in terminal · c copy command · t target · m manage · ? help"
    case 2: return "r receive · s send · j/k pick · a accept · d reject · b browse · t/f focus · Enter send"
    case 3: return "s socks · e exit node · m manage · ? help"
    case 4: return "←/→ sub-page · j/k · Enter · c copy · a add · d remove · m manage"
    }
    return ""
  }

  // ---- Keyboard ----
  Keys.onPressed: function(event) {
    var key = event.key
    if (key === Qt.Key_Escape) { root.closeRequested(); event.accepted = true; return }
    if (key === Qt.Key_Question || (key === Qt.Key_Slash && (event.modifiers & Qt.ControlModifier))) { showHelp = !showHelp; event.accepted = true; return }
    if (key === Qt.Key_M) { root.sectionIndex = 4; event.accepted = true; return }
    // 1-5 jump to a tab.
    if (key >= Qt.Key_1 && key <= Qt.Key_5) { root.sectionIndex = key - Qt.Key_1; event.accepted = true; return }
    // ←/→ switch tab; inside Manage they switch sub-pages.
    if (key === Qt.Key_Left || key === Qt.Key_Right) {
      if (root.sectionIndex === 4) {
        root.manageSection = clamp(root.manageSection + (key === Qt.Key_Left ? -1 : 1), 0, root.manageSections.length - 1)
      } else {
        root.sectionIndex = clamp(root.sectionIndex + (key === Qt.Key_Left ? -1 : 1), 0, root.sections.length - 1)
      }
      event.accepted = true
      return
    }
    switch (root.sectionIndex) {
    case 0: // Status
      if (key === Qt.Key_S) { startOrStop(); event.accepted = true }
      else if (key === Qt.Key_R) { restartServer(); event.accepted = true }
      else if (key === Qt.Key_P) { pingSelf(true); event.accepted = true }
      else if (key === Qt.Key_C) { copyListenerAddr(); event.accepted = true }
      break
    case 1: // SSH
      if (key === Qt.Key_O) { openSSH(); event.accepted = true }
      else if (key === Qt.Key_C) { copySSHCommand(); event.accepted = true }
      else if (key === Qt.Key_T) { sshTargetField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_Return || key === Qt.Key_Enter) { openSSH(); event.accepted = true }
      break
    case 2: // Files
      if (key === Qt.Key_R) { toggleRecv(); event.accepted = true }
      else if (key === Qt.Key_J || key === Qt.Key_Down) { moveOfferCursor(1); event.accepted = true }
      else if (key === Qt.Key_K || key === Qt.Key_Up) { moveOfferCursor(-1); event.accepted = true }
      else if (key === Qt.Key_A) { acceptSelectedOffer(); event.accepted = true }
      else if (key === Qt.Key_D) { rejectSelectedOffer(); event.accepted = true }
      else if (key === Qt.Key_T) { homeTargetField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_F) { homePathField.forceActiveFocus(); event.accepted = true }
      else if (key === Qt.Key_B) { root.browseSendFile(); event.accepted = true }
      else if (key === Qt.Key_S || key === Qt.Key_Return || key === Qt.Key_Enter) { doSendFile(); event.accepted = true }
      break
    case 3: // Proxy
      if (key === Qt.Key_S) { toggleSocks(); event.accepted = true }
      else if (key === Qt.Key_E) { toggleExitNode(); event.accepted = true }
      break
    case 4: // Manage
      switch (root.manageSection) {
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
      break
    }
  }

// ---- Render ----
  //
  // Outer chrome (fixed): hero + nav + error + help. The content area is a
  // plain Item sized to the remaining height; each tab is a Flickable so tall
  // content scrolls instead of overflowing.
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

    // Top nav: the five tabs + help.
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
      Text { width: parent.width; text: "STATUS  Start/stop/restart the listener, ping it, copy its address. Keys: s/r/p/c. Running services are what this machine shares."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "SSH  Enter a target (tc… or DNS), optional port + user, then Open — a terminal runs `tailcat ssh`, connecting the system ssh client through tailcat. Keys: o/c/t."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "FILES  Receive: start receiving, copy the address, accept/reject incoming. Send: pick a device (or paste a token) + a file path. Share: serve a folder over SFTP. Keys: r/s/j/k/a/d/b/t/f/Enter."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "PROXY  SOCKS5: start a local proxy that dials tailcat servers, copy socks5h://… into apps. Exit node: route this machine's whole network to others (restarts the listener). Keys: s/e."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "NAV  1-5 switch tabs · ←/→ switch tab (Manage: sub-page) · m Manage · ? help · Esc close"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      Text { width: parent.width; text: "STUCK?  Ask an AI agent — share this panel or the Diagnostics tab, and it can walk you through setup, transfers, and troubleshooting."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
    }

    // ---- content area: exactly the remaining height ----
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true

      // ============ STATUS ============
      Flickable {
        visible: root.sectionIndex === 0
        anchors.fill: parent
        contentHeight: statusCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: statusCol
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "LISTENER"; foreground: root.foreground }
          // Left = controls, right = status badge.
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Button { text: root.listenerState.running === true ? "Stop" : "Start"; onClicked: root.startOrStop() }
            Button { text: "Restart"; enabled: root.listenerState.running === true; onClicked: root.restartServer() }
            Button { text: "Ping"; enabled: root.listenerState.running === true; onClicked: root.pingSelf(true) }
            Button { text: "Copy"; visible: root.listenerState.running === true; onClicked: root.copyListenerAddr() }
            Item { Layout.fillWidth: true; height: 1 }
            Text {
              Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
              text: root.listenerState.running === true ? "● Running" : "○ Stopped"
              color: root.listenerState.running === true ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
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

          // Listener identity: which key the next Start/Restart uses.
          Row {
            width: parent.width
            spacing: Style.space(4)
            Text {
              text: "Key:"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.identityChips()
              Button {
                text: modelData.name
                selected: modelData.selected
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.sm
                foreground: root.foreground
                accent: root.accent
                onClicked: root.listenerKey = modelData.key
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "RUNNING SERVICES"; foreground: root.foreground }
          Column {
            visible: root.listenerState.running === true
            width: parent.width
            spacing: Style.space(3)
            Text {
              width: parent.width
              visible: root.listenerState.broad === true
              text: "Broad: serving ALL localhost ports (no explicit services)."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.listenerState.services || []
              Text {
                width: parent.width
                text: (modelData.enabled ? "● " : "○ ") + (modelData.name || (modelData.kind === "port-forward" ? "Port " + modelData.port : modelData.kind))
                color: modelData.enabled ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
          Text {
            width: parent.width
            visible: root.listenerState.running !== true
            text: "Listener stopped — nothing is being served. Start it to share services; configure them under Manage → Services."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

      // ============ SSH ============
      Flickable {
        visible: root.sectionIndex === 1
        anchors.fill: parent
        contentHeight: sshCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: sshCol
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          Text {
            width: parent.width
            text: "Open the system ssh client through a tailcat server — a terminal window runs `tailcat ssh <target>`. The server must serve ssh (Manage → Services → no-auth-ssh, or its own SSH server)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Saved devices as wrapping chips — click to set the SSH target.
          Flow {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.deviceChips()
              Button {
                text: modelData.name
                selected: root.sshTarget === modelData.target
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.sm
                foreground: root.foreground
                accent: root.accent
                onClicked: root.sshTarget = modelData.target
              }
            }
          }

          TextField {
            id: sshTargetField
            width: parent.width
            placeholderText: "Target tc… or DNS name"
            foreground: root.foreground
            accent: root.accent
            text: root.sshTarget
            onTextChanged: root.sshTarget = text
            onAccepted: root.openSSH()
            Keys.onEscapePressed: root.grabNavFocus()
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            TextField {
              width: 70
              placeholderText: "Port"
              foreground: root.foreground
              accent: root.accent
              text: root.sshPort
              validator: IntValidator { bottom: 1; top: 65535 }
              onTextChanged: root.sshPort = text
            }
            TextField {
              Layout.fillWidth: true
              placeholderText: "User (optional, default current user)"
              foreground: root.foreground
              accent: root.accent
              text: root.sshUser
              onTextChanged: root.sshUser = text
              onAccepted: root.openSSH()
            }
          }
          TextField {
            width: parent.width
            placeholderText: "Remote command (optional, e.g. uptime)"
            foreground: root.foreground
            accent: root.accent
            text: root.sshCmd
            onTextChanged: root.sshCmd = text
            onAccepted: root.openSSH()
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Button { text: "Open in terminal"; onClicked: root.openSSH() }
            Button { text: "Copy command"; onClicked: root.copySSHCommand() }
            Item { Layout.fillWidth: true; height: 1 }
            Text {
              Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
              visible: root.bridge.terminalOK && root.sshTarget.trim() !== ""
              text: "opens in " + root.bridge.terminal
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          Text {
            width: parent.width
            visible: root.sshResult !== ""
            text: root.sshResult
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: !root.bridge.terminalOK
            text: "No terminal found. Install ghostty/alacritty/kitty/foot or set OMARCHY_TAILCAT_TERMINAL."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

      // ============ FILES ============
      Flickable {
        visible: root.sectionIndex === 2
        anchors.fill: parent
        contentHeight: filesCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: filesCol
          width: parent.width
          spacing: Style.space(4)

          // ---- Receive ----
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "RECEIVE FILE"; foreground: root.foreground }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Button {
              width: 132
              text: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "Stop receiving" : "Start receiving"
              onClicked: root.toggleRecv()
            }
            TextField {
              id: homeRecvDirField
              Layout.fillWidth: true
              placeholderText: "Recv dir (default ~/Downloads)"
              foreground: root.foreground
              accent: root.accent
              text: root.recvDir
              onTextChanged: root.recvDir = text
            }
            Button { text: "Browse…"; onClicked: root.browseRecvDir() }
            Text {
              Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
              visible: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true
              text: "● Receiving"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Row {
            visible: root.bridge.fileRecvState && !!root.bridge.fileRecvState.addr
            width: parent.width
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
            text: root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "Waiting for incoming… → " + (root.recvDir.trim() || "~/Downloads") : "No incoming — start receiving to accept files from others"
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
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "SEND FILE"; foreground: root.foreground }
          Flow {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.deviceChips()
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
          TextField {
            id: homeTargetField
            width: parent.width
            placeholderText: "Target tc… (or pick a device above)"
            foreground: root.foreground
            accent: root.accent
            text: root.sendTarget
            onTextChanged: root.sendTarget = text
            Keys.onEscapePressed: root.grabNavFocus()
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            TextField {
              id: homePathField
              Layout.fillWidth: true
              placeholderText: "File path"
              foreground: root.foreground
              accent: root.accent
              text: root.sendPath
              onTextChanged: root.sendPath = text
              onAccepted: root.doSendFile()
              Keys.onEscapePressed: root.grabNavFocus()
            }
            Button { text: "Browse…"; onClicked: root.browseSendFile() }
            Button { text: "Send"; enabled: !root.bridge.sendActive; onClicked: root.doSendFile() }
            Button { text: "Cancel"; visible: root.bridge.sendActive; onClicked: root.bridge.cancelSend() }
            Text {
              Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
              visible: root.bridge.sendActive || root.bridge.sendResult !== "" || root.connectResult !== null
              text: root.bridge.sendActive ? (root.bridge.sendFile + "  " + root.fmtBytes(root.bridge.sendSent) + "/" + root.fmtBytes(root.bridge.sendTotal)) : (root.bridge.sendResult !== "" ? root.bridge.sendResult : root.resultLine())
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
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

          // ---- SFTP folder share ----
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "SHARE FOLDER (SFTP)"; foreground: root.foreground }
          RowLayout {
            width: parent.width
            spacing: Style.space(4)
            Toggle {
              label: "Serve a folder to scp/sftp clients"
              checked: root.filesShare
              onClicked: root.setFilesShare(!root.filesShare)
            }
            TextField {
              Layout.fillWidth: true
              visible: root.filesShare
              placeholderText: "Folder to share (default ~/Downloads, read-only)"
              foreground: root.foreground
              accent: root.accent
              text: root.filesDir
              onTextChanged: { root.filesDir = text; root.updateFilesEntry() }
            }
            Button {
              visible: root.filesShare
              text: "Browse…"
              onClicked: root.browseFilesDir()
            }
          }
          Row {
            visible: root.filesShare
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
          Text {
            visible: root.filesShare
            width: parent.width
            text: root.listenerState.running === true ? "Applies on restart — press Restart on the Status tab to serve " + (root.filesDir.trim() || "~/Downloads") + " over SFTP." : "Saved to services — start the listener (Status tab) to serve it over SFTP."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

      // ============ PROXY ============
      Flickable {
        visible: root.sectionIndex === 3
        anchors.fill: parent
        contentHeight: proxyCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: proxyCol
          width: parent.width
          spacing: Style.space(4)

          // ---- SOCKS5 ----
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "SOCKS5 PROXY"; foreground: root.foreground }
          Text {
            width: parent.width
            text: "Run a local SOCKS5 proxy that dials tailcat servers. Copy the socks5h://… address into apps (browsers, curl, git) to route traffic over tailcat. An address-blob hostname in a URL is dialed directly; a fixed target below routes everything through one server."
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
              label: "Fixed target"
              checked: root.socksFixed
              onClicked: { root.socksFixed = !root.socksFixed; if (!root.socksFixed) root.socksTarget = "" }
            }
            TextField {
              visible: root.socksFixed
              Layout.fillWidth: true
              placeholderText: "Server tc… to route everything through"
              foreground: root.foreground
              accent: root.accent
              text: root.socksTarget
              onTextChanged: root.socksTarget = text
            }
          }
          Text {
            width: parent.width
            visible: !root.bridge.available
            text: "tailcat is not installed — the SOCKS5 proxy needs it."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }
          PanelSectionHeader { text: "EXIT NODE"; foreground: root.foreground }
          Text {
            width: parent.width
            text: "Run an exit node: this machine relays connections to arbitrary IP:port on its own network, so remote clients can route through it (e.g. `tailcat socks <this-token>` then reach 192.168.x.x). Toggling restarts the listener."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Button { text: root.exitNodeOn() ? "Disable exit node" : "Enable exit node"; onClicked: root.toggleExitNode() }
            Item { Layout.fillWidth: true; height: 1 }
            Text {
              Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
              text: root.exitNodeOn() ? "● Exit node on" : (root.listenerState.running === true ? "○ Off (listener running)" : "○ Off (listener stopped)")
              color: root.exitNodeOn() ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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

      // ============ MANAGE ============
      Flickable {
        visible: root.sectionIndex === 4
        anchors.fill: parent
        contentHeight: manageCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: manageCol
          width: parent.width
          spacing: Style.space(4)

          Row {
            id: manageNavRow
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
          Text {
            width: parent.width
            text: root.manageGuide()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.32 }

          // --- Devices ---
          Column {
            id: devPage
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
            PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
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
                Keys.onEscapePressed: root.renaming = false
              }
              Button { text: "Save"; onClicked: root.commitRename() }
            }
            Text {
              visible: root.bridge.devices.length === 0
              width: parent.width
              text: "No saved devices yet. Add one below (a tc… token or DNS name), or use SSH/Files tabs to connect on the fly."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
            Row {
              width: parent.width
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
            id: idPage
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
              label: "Client identity (for --allow lists)"
              description: "No DERP region; prints a public nodekey"
              checked: root.newIdentityClient
              onClicked: root.newIdentityClient = !root.newIdentityClient
            }
          }

          // --- Services ---
          Column {
            id: svcPage
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
            PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.18 }
            Row {
              id: addServiceRow
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: addServiceField
                width: addServiceRow.width - 260
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
            id: diagPage
            visible: root.manageSection === 3
            width: parent.width
            spacing: Style.space(5)
            Text { width: parent.width; text: "Tailcat: " + (root.bridge.available ? (root.bridge.version + (root.bridge.minOK ? "" : "  (older than supported)")) : "not installed"); color: root.bridge.available ? root.foreground : root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap }
            Text { width: parent.width; visible: root.bridge.versionError !== ""; text: root.bridge.versionError; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            Text { width: parent.width; text: "Listener: " + (root.bridge.listener && root.bridge.listener.running === true ? "running" : "stopped") + " ·  Receiver: " + (root.bridge.fileRecvState && root.bridge.fileRecvState.running === true ? "running" : "stopped") + " ·  SOCKS5: " + (root.bridge.socksState && root.bridge.socksState.running === true ? "running" : "stopped"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
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
