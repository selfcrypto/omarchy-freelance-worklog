import QtQuick
import Quickshell
import "."

// HelperRunner against fake helpers (sh one-liners). Each case logs one line
// "CASE name ok|FAIL detail"; run.sh wants every case ok. Cases run one after
// another, each starting when the previous one is done.
Scope {
  id: t
  property var log: []
  property int step: 0
  function check(name, ok, detail) { console.log("CASE " + name + " " + (ok ? "ok" : "FAIL " + JSON.stringify(detail))); next() }
  function next() { step++; Qt.callLater(function() { t.cases[t.step] ? t.cases[t.step]() : Qt.quit() }) }

  HelperRunner { id: r; deadlineMs: 600; outputLimit: 200000; maxQueued: 3 }

  readonly property var echo: ["sh", "-c", "cat"]
  readonly property var slow: ["sh", "-c", "sleep 0.3; cat"]

  property var cases: [
    // A command that cannot start settles once with a failure, and the next
    // call runs normally.
    function() {
      var got = []
      r.command = ["/nonexistent/worklog-helper"]
      r.run("a", "", function(text, failure) {
        got.push(failure)
        r.command = t.echo
        r.run("after", "", function(text2, failure2) {
          got.push(text2 + "|" + failure2)
          Qt.callLater(function() { t.check("failed-launch", JSON.stringify(got) === JSON.stringify(["helper failed to start", "after|"]) && !r.busy, got) })
        })
      })
    },
    // A helper that does not answer within the deadline settles once; the
    // next call waits until the stopped one has exited, and its later output
    // is ignored.
    function() {
      var got = []
      r.command = ["sh", "-c", "trap 'sleep 0.4; exit 1' TERM; sleep 1.5 & wait; echo late"]
      r.run("x", "", function(text, failure) {
        got.push(failure)
        got.push(r.draining !== null ? "draining" : "not draining")
        r.command = t.echo
        r.run("next", "", function(text2) { got.push(text2 + (r.draining === null ? "" : " while draining")) })
      })
      later.go(2200, function() { t.check("deadline", JSON.stringify(got) === JSON.stringify(["helper did not answer", "draining", "next"]), got) })
    },
    // Three wait at most: a fourth billing change is refused, never dropped
    // later; the accepted ones answer in order.
    function() {
      var got = []
      var accepted = []
      r.command = t.slow
      for (var i = 1; i <= 5; i++) {
        (function(n) { accepted.push(r.run("m" + n, "", function(text) { got.push(text) })) })(i)
      }
      later.go(2500, function() {
        t.check("bounded-queue", JSON.stringify(accepted) === JSON.stringify([true, true, true, true, false])
          && JSON.stringify(got) === JSON.stringify(["m1", "m2", "m3", "m4"]), { accepted: accepted, got: got })
      })
    },
    // Reads and heartbeats waiting merge: one run each, every caller answered
    // with the newest request's output; drafts merge only at the end.
    function() {
      var got = []
      r.command = t.slow
      r.run("busy", "", null)
      for (var i = 1; i <= 4; i++) {
        (function(n) { r.run("view" + n, "view", function(text) { got.push(text) }) })(i)
      }
      r.run("hb1", "heartbeat", null)
      r.run("hb2", "heartbeat", function(text) { got.push(text) })
      r.run("d1", "draft", function(text) { got.push(text) })
      var full = r.queue.length
      later.go(2000, function() {
        t.check("coalesce", full === 3 && JSON.stringify(got) === JSON.stringify(["view4", "view4", "view4", "view4", "hb2", "d1"]), { full: full, got: got })
      })
    },
    // A helper killed by its own timeout (124), by a signal, or ending with an
    // unknown code fails the call; exit 1 is a refusal with an answer.
    function() {
      var got = []
      var cmds = [["sh", "-c", "exit 124"], ["sh", "-c", "kill -9 $$"], ["sh", "-c", "exit 3"], ["sh", "-c", "echo refused; exit 1"]]
      var step = function(k) {
        if (k === cmds.length) {
          t.check("exit-codes", JSON.stringify(got) === JSON.stringify(["|helper did not answer", "|helper stopped", "|helper stopped (exit 3)", "refused\n|"]), got)
          return
        }
        r.command = cmds[k]
        r.run("x", "", function(text, failure) { got.push(text + "|" + failure); step(k + 1) })
      }
      step(0)
    },
    // Merged calls are handled once (the newest handler) and every caller
    // gets what it returned.
    function() {
      var handled = 0
      var got = []
      r.command = t.slow
      r.run("busy", "", null)
      for (var i = 1; i <= 3; i++) {
        (function(n) {
          r.run("view" + n, "view", function(result) { got.push(result) }, function(text) { handled++; return "h" + n + ":" + text })
        })(i)
      }
      later.go(1500, function() { t.check("handled-once", handled === 1 && JSON.stringify(got) === JSON.stringify(["h3:view3", "h3:view3", "h3:view3"]), { handled: handled, got: got }) })
    },
    // Output past the limit stops the helper and fails the call; output under
    // it arrives whole.
    function() {
      var got = []
      r.command = ["sh", "-c", "head -c 5000000 /dev/zero | tr '\\0' x"]
      r.run("big", "", function(text, failure) {
        got.push(failure)
        r.command = ["sh", "-c", "head -c 150000 /dev/zero | tr '\\0' y"]
        r.run("fits", "", function(text2, failure2) {
          got.push(text2.length + "|" + failure2)
          t.check("output-cap", JSON.stringify(got) === JSON.stringify(["helper output too large", "150000|"]), got)
        })
      })
    }
  ]

  QtObject {
    id: later
    function go(ms, f) { var tm = Qt.createQmlObject('import QtQuick; Timer { }', t); tm.interval = ms; tm.triggered.connect(function() { f(); tm.destroy() }); tm.start() }
  }

  Component.onCompleted: cases[0]()
  Timer { interval: 15000; running: true; onTriggered: { console.log("CASE timeout FAIL"); Qt.quit() } }
}
