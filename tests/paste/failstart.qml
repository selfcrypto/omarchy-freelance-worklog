import QtQuick
import Quickshell
import "."

// With no `timeout` on PATH the clipboard processes cannot start (Quickshell
// then sends no exit): a paste must settle and free the field for the next
// one, and a cut must settle as failed and keep its text. Run by run.sh.
Scope {
  KeyField { id: field; text: "keep" }
  KeyField { id: cutField; text: "unsaved note" }
  property var events: []
  Component.onCompleted: {
    field.paste()
    cutField.selectAll()
    cutField.cut()
  }
  Timer {
    interval: 400; running: true
    onTriggered: {
      events.push(field.pasteProcess === null ? "freed" : "stuck")
      field.paste()
    }
  }
  Timer {
    interval: 900; running: true
    onTriggered: {
      events.push(field.pasteProcess === null ? "freed" : "stuck")
      console.log("FAILSTART " + JSON.stringify({ events: events, text: field.text, cut: cutField.text }))
      Qt.quit()
    }
  }
}
