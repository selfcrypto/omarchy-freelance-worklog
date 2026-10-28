import QtQuick
import Quickshell
import "Model.js" as Model

// Render check for the session form and the chart (run.sh): each case at a
// narrow and a wide width, in a dark and a light palette, with long text.
// Fails when a visible item spills past the card's edges outside a clipped
// area, and saves every case as a PNG to look at.
ShellRoot {
  id: root
  property string outDir: Quickshell.env("RENDER_OUT")
  property var palettes: [
    { name: "dark", bg: "#1e1e2e", fg: "#cdd6f4", accent: "#89b4fa", urgent: "#f38ba8" },
    { name: "light", bg: "#eff1f5", fg: "#4c4f69", accent: "#1e66f5", urgent: "#d20f39" }]
  property var widths: [280, 400]
  property var companies: [
    { id: "c_0001", name: "Acme Studio with a name far too long to fit on one chip", tag: "AS", archived: false },
    { id: "c_0002", name: "Beta Labs", tag: "BL", archived: false }]
  property var segments: [
    { start: "2026-10-27T07:00:00Z", end: "2026-10-27T09:30:00Z", endReason: "lock" },
    { start: "2026-10-27T22:00:00Z", end: "2026-10-28T01:15:00Z", endReason: "idle" },
    { start: "2026-10-28T15:00:00Z", end: "2026-10-31T09:00:00Z", endReason: "suspend" }]
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

  function runCase() {
    var total = root.palettes.length * root.widths.length
    if (index >= total) {
      console.log("RENDER done cases=" + total + " failures=" + failures.length)
      for (var f = 0; f < failures.length; f++) console.log("RENDER FAIL " + failures[f])
      Qt.quit()
      return
    }
    var pal = root.palettes[Math.floor(index / root.widths.length)]
    var w = root.widths[index % root.widths.length]
    card.width = w
    card.color = pal.bg
    editor.foreground = pal.fg
    editor.accent = pal.accent
    editor.urgent = pal.urgent
    chart.foreground = pal.fg
    chart.accent = pal.accent
    editor.load(Model.rowsFromSegments(root.segments), root.summary, ["support", "a-very-long-tag-name"], "c_0001")
    settle.restart()
  }

  Timer {
    id: settle
    interval: 300
    onTriggered: {
      var pal = root.palettes[Math.floor(root.index / root.widths.length)]
      var w = root.widths[root.index % root.widths.length]
      var name = pal.name + "-" + w
      var bad = root.spills(card, [])
      for (var i = 0; i < bad.length; i++) root.failures.push(name + ": " + bad[i])
      console.log("RENDER case " + name + " spills=" + bad.length)
      card.grabToImage(function(r) {
        if (root.outDir !== "") r.saveToFile(root.outDir + "/" + name + ".png")
        root.index++
        root.runCase()
      })
    }
  }

  Component.onCompleted: Qt.callLater(runCase)
}
