import QtQuick
import Quickshell
import "."

// A paste the clipboard owner answers late (bin/wl-paste with WLPASTE_DELAY
// 0.5, so about 0.5 s for the types and 0.5 s for the text). It lands only
// when the field is as it was; a form reloaded for another company, an edit
// typed meanwhile or a closed form drops it. Run by run.sh.
Scope {
  KeyField { id: kept; text: "A " }
  KeyField { id: reloadEarly; text: "company A" }
  KeyField { id: reloadLate; text: "company A" }
  KeyField { id: typed; text: "summary" }
  KeyField { id: hidden; text: "company A" }
  property bool hiddenStopped: false
  Component.onCompleted: { kept.paste(); reloadEarly.paste(); reloadLate.paste(); typed.paste(); hidden.paste() }
  // While the types are asked for, and while the text is read.
  Timer { interval: 200; running: true; onTriggered: reloadEarly.text = "company B" }
  Timer { interval: 750; running: true; onTriggered: { reloadLate.text = "company B"; typed.insert("!"); hidden.visible = false } }
  // Hiding the field stops the read; no wl-paste is left running.
  Timer { interval: 950; running: true; onTriggered: hiddenStopped = hidden.pasteProcess === null }
  Timer {
    interval: 1800; running: true
    onTriggered: {
      console.log("STALE " + JSON.stringify({ kept: kept.text, reloadEarly: reloadEarly.text, reloadLate: reloadLate.text,
        typed: typed.text, hidden: hidden.text, hiddenStopped: hiddenStopped }))
      Qt.quit()
    }
  }
}
