import QtQuick
import "Model.js" as Model

// An HH:MM field for the session editor, on KeyField (no editable Qt text
// control). The text is not bound to `minutes`: a binding would rewrite the
// field on every keystroke (typing "1" over "11:00" shows "01:00"). The text
// follows `minutes` only while the field is not being edited, is all selected
// on focus so typing replaces it, and is formatted when editing ends.
KeyField {
  id: field

  property int minutes: -1
  // Minutes after midnight as typed (-1 while incomplete or invalid).
  signal minutesEdited(int minutes)

  function format(m) {
    return m < 0 ? "" : (m < 600 ? "0" : "") + Math.floor(m / 60) + ":" + (m % 60 < 10 ? "0" : "") + m % 60
  }

  maximumLength: 5
  horizontalAlignment: Text.AlignHCenter
  allowed: /[0-9:.h]/

  Component.onCompleted: text = format(minutes)
  onMinutesChanged: if (!activeFocus) text = format(minutes)
  onActiveFocusChanged: if (activeFocus) selectAll()
  onTextEdited: minutesEdited(Model.parseClock(text))
  onEditingFinished: {
    var m = Model.parseClock(text)
    text = format(m >= 0 ? m : minutes)
  }
}
