import QtQuick
import Quickshell.Io

// Runs the helper one call at a time, in the order asked, each call in a
// process of its own. A call settles exactly once: with the helper's output
// when it exits, or with a failure when it cannot start, does not answer
// within `deadlineMs`, or prints more than `outputLimit` characters (the
// process is stopped), or when it exits killed or with a code other than 0
// (answered) and 1 (refused, the answer says why). A process that ends after
// its call settled is ignored, and a stopped process is waited for (up to
// `drainMs`) before the next call starts; the helper's lock keeps two from
// ever writing at once.
//
// The queue is bounded: at most `maxQueued` calls wait. Reads ("view") and
// heartbeats waiting already take the newer request's place, and a draft
// replaces a draft at the end of the queue, so repeated refreshes never pile
// up. A call over the bound is refused (`run` returns false) and never
// dropped later: the caller says so on screen. Billing changes keep their
// order and each gets its own answer.
Item {
  id: runner

  // The process to start: the payload goes on its stdin.
  property var command: []
  property int maxQueued: 32
  // Past the command's own `timeout -k 3 15`, as a last resort.
  property int deadlineMs: 25000
  property int outputLimit: 8 * 1024 * 1024
  property int drainMs: 5000

  property var queue: []
  property var pending: null
  // A process stopped by the runner that has not exited yet.
  property var draining: null
  property int seq: 0
  readonly property bool busy: pending !== null || draining !== null || queue.length > 0

  // key: "view" and "heartbeat" merge with one waiting anywhere, "draft"
  // with one waiting last; anything else ("") is its own call. handle(text,
  // failure), when given, runs once per call (the newest merged one's) and
  // every done gets what it returns; without it, done(text, failure) gets the
  // output, or "" and a failure message.
  function run(payload, key, done, handle) {
    var dones = done ? [done] : []
    var job = null
    if (key === "view" || key === "heartbeat") {
      for (var i = 0; i < queue.length; i++) if (queue[i].key === key) job = queue[i]
    } else if (key === "draft" && queue.length && queue[queue.length - 1].key === "draft") {
      job = queue[queue.length - 1]
    }
    if (job) {
      job.payload = payload
      job.dones = job.dones.concat(dones)
      if (handle) job.handle = handle
      return true
    }
    if (queue.length >= maxQueued) return false
    queue = queue.concat([{ payload: payload, key: key || "", dones: dones, handle: handle || null, runId: 0, proc: null }])
    pump()
    return true
  }

  function pump() {
    if (pending || draining || queue.length === 0) return
    var job = queue[0]
    queue = queue.slice(1)
    job.runId = ++seq
    pending = job
    watchdog.restart()
    var p = procComponent.createObject(runner, { runId: job.runId, payload: job.payload, command: command })
    if (!p) {
      settle(job.runId, "", "helper failed to start")
      return
    }
    job.proc = p
    p.running = true
  }

  // The one way a call ends; a runId that is not the pending call's is late.
  function settle(runId, text, failure) {
    if (!pending || pending.runId !== runId) return
    var job = pending
    pending = null
    watchdog.stop()
    var p = job.proc
    job.proc = null
    if (p) {
      p.finished = true
      if (p.running) {
        draining = p
        drainTimer.restart()
        p.running = false
      } else p.destroy()
    }
    try {
      var result = null
      if (job.handle) {
        try { result = job.handle(failure ? "" : text, failure) } catch (e) { console.warn("HelperRunner: " + e) }
      }
      for (var i = 0; i < job.dones.length; i++) {
        try {
          if (job.handle) job.dones[i](result)
          else job.dones[i](failure ? "" : text, failure)
        } catch (e2) { console.warn("HelperRunner: " + e2) }
      }
    } finally {
      pump()
    }
  }

  function drained(p) {
    if (draining !== p) return
    draining = null
    drainTimer.stop()
    p.destroy()
    pump()
  }

  // A stopped process that never reports its end is let go after drainMs.
  Timer {
    id: drainTimer
    interval: runner.drainMs
    onTriggered: if (runner.draining) runner.drained(runner.draining)
  }

  Timer {
    id: watchdog
    interval: runner.deadlineMs
    onTriggered: if (runner.pending) runner.settle(runner.pending.runId, "", "helper did not answer")
  }

  Component {
    id: procComponent
    Process {
      id: proc
      property int runId: 0
      property string payload: ""
      property bool launched: false
      property bool finished: false
      property string out: ""
      stdinEnabled: true
      // Closing stdin (stdinEnabled false) is the helper's end of input.
      onStarted: {
        launched = true
        write(payload)
        payload = ""
        stdinEnabled = false
      }
      // A process that never started has no exit and no output to wait for.
      onRunningChanged: {
        if (running) return
        if (!launched && !finished) runner.settle(runId, "", "helper failed to start")
        else if (finished) runner.drained(proc)
      }
      onExited: function(exitCode, exitStatus) {
        if (finished) return
        if (exitStatus !== 0) runner.settle(runId, "", "helper stopped")
        else if (exitCode === 124 || exitCode === 137) runner.settle(runId, "", "helper did not answer")
        else if (exitCode !== 0 && exitCode !== 1) runner.settle(runId, "", "helper stopped (exit " + exitCode + ")")
        else runner.settle(runId, out, "")
      }
      // Each chunk as it arrives, so the output is capped before it is kept.
      stdout: SplitParser {
        splitMarker: ""
        onRead: function(chunk) {
          if (proc.finished) return
          var s = String(chunk)
          if (proc.out.length + s.length > runner.outputLimit) runner.settle(proc.runId, "", "helper output too large")
          else proc.out += s
        }
      }
    }
  }
}
