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
}
