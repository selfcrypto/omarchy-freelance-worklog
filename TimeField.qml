import QtQuick
import "Model.js" as Model

// An HH:MM field for the session editor, on KeyField (no editable Qt text
// control). The text is not bound to `minutes`: a binding would rewrite the
// field on every keystroke (typing "1" over "11:00" shows "01:00"). The text
// follows `minutes` only while the field is not being edited, is all selected
// on focus (Tab or click) so typing replaces it, and is formatted when editing
// ends.
KeyField {
  id: field

  property int minutes: -1
  // The text before the last edit, to tell a deletion from typing.
  property string lastText: ""
  // The minutes when the box got focus, kept if the edit ends in no time.
  property int focusMinutes: -1
  // Minutes after midnight as typed (-1 while incomplete or invalid).
  signal minutesEdited(int minutes)

  function format(m) {
    return m < 0 ? "" : (m < 600 ? "0" : "") + Math.floor(m / 60) + ":" + (m % 60 < 10 ? "0" : "") + m % 60
  }

  maximumLength: 5
  selectOnFocus: true
  keypadDigits: true
  horizontalAlignment: Text.AlignHCenter
  allowed: /[0-9:.h]/

  Component.onCompleted: text = format(minutes)
  onMinutesChanged: if (!activeFocus) text = format(minutes)
  onActiveFocusChanged: if (activeFocus) { lastText = text; focusMinutes = minutes; selectAll() }
  // Typing or deleting at the end places and drops the ":" (Model.autoColon).
  // A deletion leaves the start of the text before it; a paste over a
  // selection does not.
  onTextEdited: {
    if (cursorPosition === text.length && !hasSelection) {
      var t = Model.autoColon(text, text.length < lastText.length && lastText.indexOf(text) === 0)
      if (t !== text) { text = t; cursorPosition = t.length }
    }
    lastText = text
    minutesEdited(Model.parseClock(text))
  }
  onTextChanged: if (!activeFocus) lastText = text
  // Text that is no time when editing ends goes back to the time the box had
  // when it got focus, and the row with it.
  onEditingFinished: {
    var m = Model.parseClock(text)
    if (m < 0 && focusMinutes >= 0) { m = focusMinutes; minutesEdited(m) }
    text = format(m >= 0 ? m : minutes)
    cursorPosition = text.length
    lastText = text
  }
}
