import QtQuick
import Quickshell
import "."

// KeyField's copy and cut (bin/wl-copy records them; WLCOPY_FAIL makes it
// fail): the selection goes on stdin, and a cut keeps the text when the copy
// fails. Run by run.sh.
Scope {
  KeyField { id: field; text: "Auditoría del menú" }
  KeyField { id: cutField; text: "unsaved note" }
  Component.onCompleted: { field.selectionAnchor = 0; field.cursorPosition = 9; field.copy() }
  Timer { interval: 400; running: true; onTriggered: { cutField.selectAll(); cutField.cut() } }
  Timer { interval: 1200; running: true; onTriggered: { console.log("CUT kept=" + JSON.stringify(cutField.text)); Qt.quit() } }
}
