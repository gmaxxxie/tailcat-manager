import QtQuick
import Quickshell
import Quickshell.Io

// TailcatBridge — calls the `omarchy-tailcat` backend binary with structured
// argument arrays (never a shell) and parses its JSON output. All backend
// calls are serialized through a FIFO queue on a single Process, which is
// fine: calls are short and rare (status refresh every N seconds, explicit
// user actions). Mirrors the state.sh / Service.qml pattern used by other
// Omarchy plugins, but self-contained in this plugin.
Item {
  id: root

  readonly property string pluginDir: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dev.omarchy.tailcat"
  readonly property string backendCmd: Quickshell.env("OMARCHY_TAILCAT_BIN") || (pluginDir + "/bin/omarchy-tailcat")

  // ---- status model ----
  property bool available: false
  property string version: ""
  property bool minOK: false
  property string versionError: ""
  property var listener: ({})          // ListenerStatus JSON
  property var devices: []             // saved devices
  property var identities: []          // identities
  property var diagLog: []             // redacted log tail
  property string lastError: ""        // human message of last failure
  property string lastDetail: ""       // redacted detail (Details disclosure)
  property bool busy: false

  signal statusRefreshed()

  // ---- serialized backend queue ----
  property var queue: []
  property bool executing: false
  property var current: null

  Process {
    id: proc
    running: false
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function(exitCode) { root.finish(exitCode) }
  }

  // run(args, onSuccess, onError) — args is an array of strings.
  function run(args, onSuccess, onError) {
    queue.push({ args: args, onSuccess: onSuccess, onError: onError })
    if (!executing) next()
  }

  function next() {
    if (queue.length === 0) {
      executing = false
      busy = false
      return
    }
    executing = true
    busy = true
    current = queue.shift()
    // Clear any stale error so a fresh operation starts clean.
    root.lastError = ""
    proc.command = [root.backendCmd].concat(current.args)
    proc.running = true
  }

  function finish(exitCode) {
    var job = current
    current = null
    var outText = String(out.text || "")
    var errText = String(err.text || "")
    var data = null
    if (outText.trim() !== "") {
      try { data = JSON.parse(outText) } catch (e) { data = null }
    }
    if (exitCode === 0) {
      if (job && job.onSuccess) job.onSuccess(data, outText)
    } else {
      var message = "Command failed"
      var detail = errText.trim()
      if (data && data.error) {
        message = data.error.message || data.error.kind || "Command failed"
        detail = data.error.detail || detail
      } else if (errText.trim() !== "") {
        message = errText.trim()
      }
      root.lastError = message
      root.lastDetail = detail
      if (job && job.onError) job.onError(data, message, detail)
      else root.statusRefreshed() // refresh so UI reflects reality
    }
    next()
  }

  // ---- backend operations ----

  function refresh() {
    run(["status"], function(data) {
      if (!data) return
      var v = data.version || {}
      available = !!v.available
      version = String(v.version || "")
      minOK = !!v.minOK
      versionError = String(v.error || "")
      listener = data.listener || {}
      statusRefreshed()
    })
    run(["devices", "list"], function(data) { if (data) devices = data })
    run(["identities", "list"], function(data) { if (data) identities = data })
  }

  function refreshDiagnostics() {
    run(["diagnostics"], function(data) {
      if (!data) return
      if (data.version) {
        available = !!data.version.available
        version = String(data.version.version || "")
        minOK = !!data.version.minOK
        versionError = String(data.version.error || "")
      }
      if (data.listener) listener = data.listener
      if (data.logTail) diagLog = data.logTail
      statusRefreshed()
    })
  }

  function validate(target, onSuccess) {
    run(["validate", String(target || "")], function(data) {
      if (onSuccess) onSuccess(data || { valid: false })
    }, function(data, message) {
      if (onSuccess) onSuccess({ valid: false, message: message })
    })
  }

  function ping(target, untilDirect, onSuccess) {
    var args = ["ping", String(target || "")]
    if (untilDirect) args.push("--until-direct")
    args.push("--timeout=20s")
    run(args, function(data) {
      if (onSuccess) onSuccess(data || { ok: false })
    }, function(data, message, detail) {
      if (onSuccess) onSuccess({ ok: false, message: message, detail: detail })
    })
  }

  function startServer(services, key, onSuccess) {
    var args = ["serve", "start"]
    appendSpecArgs(args, services, key)
    run(args, function(data) { if (data) listener = data; if (onSuccess) onSuccess(data); refresh() })
  }

  function restartServer(services, key, onSuccess) {
    var args = ["serve", "restart"]
    appendSpecArgs(args, services, key)
    run(args, function(data) { if (data) listener = data; if (onSuccess) onSuccess(data); refresh() })
  }

  function stopServer(onSuccess) {
    run(["serve", "stop"], function(data) { if (data) listener = data; if (onSuccess) onSuccess(data); refresh() })
  }

  function appendSpecArgs(args, services, key) {
    if (key && key !== "") args.push("--key=" + key)
    var parts = []
    for (var i = 0; i < services.length; i++) {
      var s = services[i]
      if (!s || s.enabled !== true) continue
      if (s.kind === "port-forward") parts.push(String(s.port))
      else parts.push(String(s.kind))
    }
    for (var j = 0; j < parts.length; j++) args.push(parts[j])
  }

  function addDevice(name, target, onSuccess) {
    run(["devices", "add", String(name || ""), String(target || "")], function(data) {
      if (onSuccess) onSuccess(data)
      refresh()
    })
  }

  function removeDevice(id, onSuccess) {
    run(["devices", "remove", String(id || "")], function(data) { if (onSuccess) onSuccess(data); refresh() })
  }

  function renameDevice(id, name, onSuccess) {
    run(["devices", "rename", String(id || ""), String(name || "")], function(data) { if (onSuccess) onSuccess(data); refresh() })
  }

  function touchDevice(id, onSuccess) {
    run(["devices", "touch", String(id || "")], function(data) { if (onSuccess) onSuccess(data); refresh() })
  }

  function createIdentity(name, kind, region, onSuccess) {
    var args = ["identities", "create", String(name || "")]
    if (kind === "client") args.push("--client")
    if (region && region !== "") args.push("--region=" + region)
    run(args, function(data) { if (onSuccess) onSuccess(data); refresh() })
  }

  function deleteIdentity(name, onSuccess) {
    run(["identities", "delete", String(name || "")], function(data) { if (onSuccess) onSuccess(data); refresh() })
  }

  // ---- V0.2 file transfer ----

  property var fileRecvState: ({ running: false })
  property var fileRecvPending: []
  property var fileRecvDone: []

  property bool sendActive: false
  property int sendSent: 0
  property int sendTotal: 0
  property string sendFile: ""
  property string sendResult: ""

  function fileRecvStart(dir, key, onSuccess) {
    var args = ["file", "recv-start"]
    if (dir && dir !== "") args.push("--dir=" + dir)
    if (key && key !== "" && key !== "new") args.push("--key=" + key)
    run(args, function(data) {
      fileRecvState = data || {}
      if (onSuccess) onSuccess(data)
      refreshFileRecv()
    }, function() { refreshFileRecv() })
  }

  function fileRecvStop() {
    run(["file", "recv-stop"], function() {
      fileRecvState = { running: false }
      fileRecvPending = []
      fileRecvDone = []
    })
  }

  function refreshFileRecv() {
    run(["file", "recv-status"], function(data) {
      if (!data) return
      fileRecvState = data
      fileRecvPending = data.pending || []
      fileRecvDone = data.done || []
    })
  }

  function fileRecvRespond(id, accept, dest) {
    var args = ["file", "recv-respond", String(id || ""), accept ? "accept" : "reject"]
    if (accept && dest) args.push(String(dest))
    run(args, function() { refreshFileRecv() }, function() { refreshFileRecv() })
  }

  function fileSend(target, path, name) {
    if (sendActive) return
    sendActive = true
    sendSent = 0
    sendTotal = 0
    sendFile = name || path
    sendResult = ""
    sendBuf = sendOut.text || ""
    var args = ["file", "send", String(target || ""), String(path || "")]
    if (name && name !== "") args.push("--name=" + name)
    sendProc.command = [root.backendCmd].concat(args)
    sendProc.running = true
  }

  function cancelSend() {
    if (sendProc) sendProc.running = false
    sendActive = false
    sendResult = "Cancelled"
  }

  property string sendBuf: ""
  function parseSendOutput() {
    var t = sendOut.text || ""
    if (t.length < sendBuf.length) sendBuf = ""
    var newText = t.substring(sendBuf.length)
    sendBuf = t
    var lines = String(newText).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "") continue
      var obj = null
      try { obj = JSON.parse(line) } catch (e) { continue }
      if (obj.type === "progress") {
        sendSent = Number(obj.sent || 0)
        sendTotal = Number(obj.total || 0)
      } else if (obj.type === "done") {
        sendResult = "Sent · " + (obj.sha256 ? obj.sha256.substr(0, 8) : "") + " · " + fmtBytes(obj.bytes)
      } else if (obj.type === "error") {
        lastError = obj.message || "Send failed"
        lastDetail = obj.detail || ""
        sendResult = lastError
      }
    }
  }

  function sendFinished(exitCode) {
    sendActive = false
    if (exitCode !== 0 && sendResult === "" && lastError !== "") sendResult = lastError
    refresh()
  }

  function fmtBytes(n) {
    var v = Number(n || 0)
    if (v >= 1 << 30) return (v / (1 << 30)).toFixed(1) + " GB"
    if (v >= 1 << 20) return (v / (1 << 20)).toFixed(1) + " MB"
    if (v >= 1 << 10) return (v / (1 << 10)).toFixed(1) + " KB"
    return v + " B"
  }

  Process {
    id: sendProc
    running: false
    stdout: StdioCollector {
      id: sendOut
      waitForEnd: false
      onDataChanged: root.parseSendOutput()
    }
    stderr: StdioCollector { waitForEnd: false }
    onExited: function(code) { root.sendFinished(code) }
  }

  // ---- native file/folder picker (XDG Desktop Portal) ----
  // Runs ui/bin/tc-filepicker (file|dir) which opens the portal file chooser
  // and prints the chosen local path (or nothing if cancelled).
  readonly property string pickerScript: Quickshell.env("OMARCHY_TAILCAT_PICKER") || (pluginDir + "/bin/tc-filepicker")
  property var pickCallback: null

  Process {
    id: pickerProc
    running: false
    stdout: StdioCollector { id: pickerOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) { root.pickFinished(code) }
  }

  // pick(kind, onDone) — kind "file" or "dir"; onDone(path) with the chosen
  // local path, or "" when the user cancelled.
  function pick(kind, onDone) {
    pickCallback = onDone
    pickerProc.command = [root.pickerScript, kind || "file"]
    pickerProc.running = true
  }

  function pickFinished(code) {
    var cb = pickCallback
    pickCallback = null
    var path = String(pickerOut.text || "").split("\n")[0].trim()
    if (cb) cb(path)
    else if (code !== 0) root.lastError = "File picker failed"
  }
}
