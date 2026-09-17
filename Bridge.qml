import Quickshell
import Quickshell.Io
import QtQuick

// One place that knows how to call bin/cloudflarechy and hand back parsed JSON.
//
// Calls are serialised through a single Process and a queue: Quickshell's
// Process is a declarative object, not a spawn-per-call API, so overlapping
// callers would otherwise clobber each other's command and stdout. The panel
// leans on that — a refresh fires four subcommands in a row.
Item {
  id: root

  property string script: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/cloudflarechy/bin/cloudflarechy"

  property bool busy: false
  property var _queue: []
  property var _current: null

  // `fresh` skips the script's read cache, which is what a hand-driven refresh
  // wants and what a background poll does not.
  function call(args, callback, fresh) {
    root._queue.push({ args: (fresh ? ["--fresh"] : []).concat(args), callback: callback })
    root._pump()
  }

  function _pump() {
    if (root._current || root._queue.length === 0) return
    root._current = root._queue.shift()
    root.busy = true
    proc.collected = ""
    proc.command = [root.script].concat(root._current.args)
    proc.running = true
  }

  function _finish(payload) {
    var job = root._current
    root._current = null
    root.busy = root._queue.length > 0
    if (job && job.callback) job.callback(payload)
    root._pump()
  }

  Process {
    id: proc
    property string collected: ""

    stdout: SplitParser {
      // jq pretty-prints one object across many lines, so accumulate and parse
      // at exit rather than per line.
      onRead: function(line) { proc.collected += String(line || "") }
    }

    onExited: function(code) {
      var payload = null
      if (proc.collected) {
        try { payload = JSON.parse(proc.collected) } catch (e) { payload = null }
      }
      if (payload === null) payload = { error: "cloudflarechy exited " + code }
      root._finish(payload)
    }
  }
}
