import QtQuick
import Quickshell
import "."

// KeyField's paste against a clipboard of 8 MB with no newline (bin/wl-paste):
// the buffer must stop at the cap. Run by run.sh.
Scope {
  property int peak: 0
  KeyField { id: field; onPasteBufferChanged: peak = Math.max(peak, pasteBuffer.length) }
  Component.onCompleted: field.paste()
  Timer { interval: 1400; running: true; onTriggered: { console.log("PASTE peak=" + peak + " final=" + field.text.length); Qt.quit() } }
}
