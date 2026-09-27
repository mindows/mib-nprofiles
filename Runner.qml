import QtQuick
import Quickshell.Io

// Runs commands one at a time and hands each callback its exit code, stdout
// and stderr. Commands are argv lists, never shell strings. A job that never
// reports back (the binary failed to start, say) is given up on after the
// timeout, so the queue can't wedge.
Item {
  id: runner

  property int timeoutMs: 45000
  readonly property bool busy: current !== null

  property var queue: []
  property var current: null
  property string _out: ""
  property string _err: ""
  property int _code: -1
  property int _pending: 0

  function run(argv, callback) {
    queue.push({ argv: argv, callback: callback || null })
    next()
  }

  function next() {
    if (current !== null || queue.length === 0) return
    current = queue.shift()
    _out = ""
    _err = ""
    _code = -1
    _pending = 3
    proc.command = current.argv
    proc.running = true
    watchdog.restart()
  }

  function _settle() {
    if (current === null) return
    _pending--
    if (_pending > 0) return
    _finish()
  }

  function _finish() {
    watchdog.stop()
    var job = current
    current = null
    try {
      if (job.callback) job.callback(_code, _out, _err)
    } catch (e) {
      console.warn("mib-nprofiles: callback failed for " + job.argv[0] + ": " + e)
    }
    Qt.callLater(next)
  }

  Process {
    id: proc
    // nmcli translates states such as "connected"; parsing needs them fixed.
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { onStreamFinished: { runner._out = text; runner._settle() } }
    stderr: StdioCollector { onStreamFinished: { runner._err = text; runner._settle() } }
    onExited: function(exitCode) { runner._code = exitCode; runner._settle() }
  }

  Timer {
    id: watchdog
    interval: runner.timeoutMs
    onTriggered: {
      if (runner.current === null) return
      if (proc.running) proc.running = false
      if (runner._err === "") runner._err = "timed out"
      runner._finish()
    }
  }
}
