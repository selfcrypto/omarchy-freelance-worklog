import QtQuick
import Quickshell
import "Model.js" as Model

// Render check for the session form and the chart (run.sh): each case at a
// narrow and a wide width, in a dark and a light palette, with long text, for
// a confirmed session and a running one. Fails when a visible item spills past
// the card's edges outside a clipped area or a chart bar shows two tones, and
// saves every case as a PNG to look at. The live cases also drive the form:
// the running segment stays last and open, and no summary is needed.
ShellRoot {
  id: root
  property string outDir: Quickshell.env("RENDER_OUT")
  property var palettes: [
    { name: "dark", bg: "#1e1e2e", fg: "#cdd6f4", accent: "#89b4fa", urgent: "#f38ba8" },
    { name: "light", bg: "#eff1f5", fg: "#4c4f69", accent: "#1e66f5", urgent: "#d20f39" }]
  property var widths: [280, 400]
  property var modes: ["edit", "live"]
  property var companies: [
    { id: "c_0001", name: "Acme Studio with a name far too long to fit on one chip", tag: "AS", archived: false },
    { id: "c_0002", name: "Beta Labs", tag: "BL", archived: false }]
  property var segments: [
    { start: "2026-10-27T07:00:00Z", end: "2026-10-27T09:30:00Z", endReason: "lock" },
    { start: "2026-10-27T22:00:00Z", end: "2026-10-28T01:15:00Z", endReason: "idle" },
    { start: "2026-10-28T15:00:00Z", end: "2026-10-31T09:00:00Z", endReason: "suspend" }]
  property var liveSegments: [
    { start: "2026-11-02T07:00:00Z", end: "2026-11-02T07:30:00Z", endReason: "lock" },
    { start: "2026-11-02T08:00:17Z", end: "2026-11-02T08:00:37Z", endReason: "manual" },
    { start: "2026-11-02T09:00:00Z", end: null }]
  property int submits: 0
  property string summary: "Reviewed https://example.com/a/very/long/path/that/never/fits?with=query&more=1 and the checkout-flow-state-machine, then wrote the release notes for the client."
  property var failures: []
  property int index: 0

  FloatingWindow {
    id: win
    implicitWidth: 440
    implicitHeight: 1000
    color: "transparent"

    Rectangle {
      id: card
      width: root.widths[0]
      height: column.implicitHeight + 16
      color: root.palettes[0].bg

      Column {
        id: column
        x: 8; y: 8
        width: card.width - 16
        spacing: 12

        SessionEditor {
          id: editor
          width: parent.width
          mode: "edit"
          companies: root.companies
          suggestions: ["support", "meeting", "development", "design", "a-very-long-tag-name"]
          nowMs: Date.parse("2026-11-02T10:00:00Z")
          fontFamily: "JetBrainsMono Nerd Font"
          onSubmitted: root.submits++
        }

        WeekChart {
          id: chart
          width: parent.width
          height: 120
          target: 2
          targetLabel: "10h"
          markers: [3]
          series: {
            var out = []
            for (var i = 0; i < 31; i++)
              out.push({ label: String(i + 1), readout: "", hours: (i * 7) % 9 / 2, state: i < 27 ? "past" : (i === 27 ? "current" : "future") })
            return out
          }
          fontFamily: "JetBrainsMono Nerd Font"
        }
      }
    }
  }

  // Every visible item inside the card, outside clipped parents.
  function spills(item, out) {
    for (var i = 0; i < item.children.length; i++) {
      var c = item.children[i]
      if (!c.visible || c.opacity === 0 || c.width <= 0) continue
      var p = c.mapToItem(card, 0, 0)
      var label = c.text !== undefined ? "Text '" + String(c.text).slice(0, 40) + "'" : String(c).split("(")[0]
      if (p.x < -1 || p.x + c.width > card.width + 1)
        out.push(label + " x=" + Math.round(p.x) + " w=" + Math.round(c.width))
      // A text wider than its own box that neither elides nor wraps paints
      // outside it.
      else if (c.contentWidth !== undefined && c.elide === Text.ElideNone && c.wrapMode === Text.NoWrap && c.contentWidth > c.width + 1
               && c.objectName !== "axisLabel")
        out.push(label + " text " + Math.round(c.contentWidth) + " in " + Math.round(c.width))
      if (!c.clip) spills(c, out)
    }
    return out
  }

  function caseAt(i) {
    var n = root.widths.length
    var m = root.modes.length
    return { pal: root.palettes[Math.floor(i / (n * m))], w: root.widths[Math.floor(i / m) % n], mode: root.modes[i % m] }
  }

  function expect(ok, what) { if (!ok) root.failures.push("live form: " + what) }

  // What the form does with a live session; leaves it reloaded by the next case.
  function checkLive() {
    editor.mode = "live"
    editor.liveState = "running"
    editor.load(Model.rowsFromSegments(root.liveSegments), "", [], "c_0001")
    expect(editor.check.error === "", "untouched rows: " + editor.check.error)
    expect(editor.check.segments.length === 3, "a short segment was dropped")
    editor.addRow()
    expect(editor.check.error === "", "added row: " + editor.check.error)
    expect(editor.check.segments.length === 4 && editor.check.segments[3].end === null, "added row is not before the running one")
    editor.removeRow(3)
    expect(editor.check.segments.length === 4, "the running row was removed")
    editor.removeRow(0)
    expect(editor.check.segments.length === 3, "an earlier row was not removed")
    var before = root.submits
    editor.submit()
    expect(root.submits === before + 1, "running save asks for a summary")
    editor.liveState = "paused"
    editor.load(Model.rowsFromSegments(root.segments), "", [], "c_0001")
    editor.addRow()
    expect(editor.check.error === "", "paused added row: " + editor.check.error)
    editor.submit()
    expect(root.submits === before + 2, "paused save asks for a summary")
    editor.mode = "edit"
    editor.liveState = ""
    editor.load(Model.rowsFromSegments(root.segments), "", [], "c_0001")
    editor.submit()
    expect(root.submits === before + 2, "a confirmed session saved without a summary")
  }

  function runCase() {
    var total = root.palettes.length * root.widths.length * root.modes.length
    if (index >= total) {
      console.log("RENDER done cases=" + total + " failures=" + failures.length)
      for (var f = 0; f < failures.length; f++) console.log("RENDER FAIL " + failures[f])
      Qt.quit()
      return
    }
    var c = root.caseAt(index)
    var pal = c.pal
    card.width = c.w
    card.color = pal.bg
    editor.foreground = pal.fg
    editor.accent = pal.accent
    editor.urgent = pal.urgent
    chart.foreground = pal.fg
    chart.accent = pal.accent
    editor.mode = c.mode
    editor.liveState = c.mode === "live" ? "running" : ""
    editor.load(Model.rowsFromSegments(c.mode === "live" ? root.liveSegments : root.segments), root.summary, ["support", "a-very-long-tag-name"], "c_0001")
    settle.restart()
  }

  Timer {
    id: settle
    interval: 300
    onTriggered: {
      var c = root.caseAt(root.index)
      var name = c.pal.name + "-" + c.w + "-" + c.mode
      var bad = root.spills(card, [])
      for (var i = 0; i < bad.length; i++) root.failures.push(name + ": " + bad[i])
      console.log("RENDER case " + name + " spills=" + bad.length)
      // Two points inside the first tall bar, for run.sh: near the baseline
      // and above the corners' reach. A bar has one tone.
      var low = chart.mapToItem(card, chart.columnWidth * 1.5, chart.plotHeight - 3)
      console.log("RENDER bar " + name + " " + Math.round(low.x) + " " + Math.round(low.y) + " " + Math.round(low.y - 8))
      card.grabToImage(function(r) {
        if (root.outDir !== "") r.saveToFile(root.outDir + "/" + name + ".png")
        if (c.mode === "live") root.checkLive()
        root.index++
        root.runCase()
      })
    }
  }

  Component.onCompleted: Qt.callLater(runCase)
}
