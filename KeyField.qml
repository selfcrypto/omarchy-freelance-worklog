import QtQuick

// A text field without an editable Qt text control. It draws plain Text and
// takes keys one by one; the clipboard is read only on Ctrl+V or Shift+Insert,
// through a fixed `wl-paste` call under `timeout`, at most 4096 bytes.
//
// Why: on Qt 6.12 an editable Qt text control (TextInput, TextEdit,
// TextField) reads every clipboard change by itself, through an uncapped
// Wayland receive loop; another clipboard owner could stall the shell. The
// marketplace review blocks such controls (Power Saving 1.4.4, OmaCal 1.1.0).
//
// The caret is a character drawn into the text while the field has focus
// (no layout queries on a Text). Keys the field does not use (Tab, Escape,
// Ctrl+Enter, Up/Down on one line) go out through `unhandledKey(event)`
// first, then to the parent items if still not accepted.
Item {
  id: field

  property string text: ""
  property string placeholderText: ""
  property int maximumLength: 32767
  property bool multiline: false
  property bool uppercase: false
  // Characters a keystroke may insert (a RegExp tested per character), or null.
  property var allowed: null
  property int horizontalAlignment: Text.AlignLeft
  property color foreground: "#cdd6f4"
  property color accent: "#89b4fa"
  property color urgent: "#f38ba8"
  property bool invalid: false
  property real radius: 6
  property real padding: 8
  property font font
  // Multi-line: the box grows with the text from minHeight up to maxHeight,
  // then shows the end of the text.
  property real minHeight: 0
  property real maxHeight: 0

  property int cursorPosition: text.length
  property bool allSelected: false
  readonly property bool editing: activeFocus

  signal textEdited()
  signal editingFinished()
  signal accepted()
  signal unhandledKey(var event)

  readonly property string caret: "▏"
  readonly property real lineHeight: Math.ceil(metrics.height)

  activeFocusOnTab: true
  implicitWidth: 160
  implicitHeight: multiline
    ? Math.max(minHeight, Math.min(maxHeight > 0 ? maxHeight : 100000, label.implicitHeight + padding * 2))
    : lineHeight + padding * 1.5

  function selectAll() { allSelected = text.length > 0; cursorPosition = text.length }

  function clean(s) {
    s = String(s).replace(/\r\n?/g, "\n")
    s = multiline ? s.replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, "") : s.replace(/[\u0000-\u001f\u007f]+/g, " ")
    if (uppercase) s = s.toUpperCase()
    if (allowed) {
      var out = ""
      for (var i = 0; i < s.length; i++) if (allowed.test(s[i])) out += s[i]
      s = out
    }
    return s
  }

  function insert(s) {
    s = clean(s)
    if (allSelected) { text = ""; cursorPosition = 0; allSelected = false }
    var room = maximumLength - text.length
    if (room <= 0 || s.length === 0) return false
    s = s.slice(0, room)
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    text = text.slice(0, at) + s + text.slice(at)
    cursorPosition = at + s.length
    return true
  }

  function removeBefore(word) {
    if (allSelected) { text = ""; cursorPosition = 0; allSelected = false; return true }
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    if (at === 0) return false
    var from = at - 1
    if (word) {
      while (from > 0 && text[from] === " ") from--
      while (from > 0 && text[from - 1] !== " " && text[from - 1] !== "\n") from--
    }
    text = text.slice(0, from) + text.slice(at)
    cursorPosition = from
    return true
  }

  function removeAfter() {
    if (allSelected) { text = ""; cursorPosition = 0; allSelected = false; return true }
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    if (at >= text.length) return false
    text = text.slice(0, at) + text.slice(at + 1)
    return true
  }

  // ---------------------------------------------------------------- paste

  readonly property int pasteLimit: 4096
  property var pasteProcess: null
  property string pasteBuffer: ""

  function paste() {
    if (pasteProcess) return
    try {
      pasteProcess = Qt.createQmlObject('import Quickshell.Io; Process { stdout: SplitParser {} }', field, "KeyFieldPaste")
    } catch (e) {
      pasteProcess = null
      return
    }
    pasteBuffer = ""
    pasteProcess.command = ["timeout", "-k", "1", "2", "wl-paste", "--no-newline", "--type", "text/plain"]
    pasteProcess.stdout.read.connect(function(line) {
      if (field.pasteBuffer.length > field.pasteLimit) return
      field.pasteBuffer += (field.pasteBuffer.length ? "\n" : "") + line
      // Past the cap: stop reading, keep what fits.
      if (field.pasteBuffer.length > field.pasteLimit && field.pasteProcess) field.pasteProcess.running = false
    })
    pasteProcess.exited.connect(function() {
      var got = field.pasteBuffer.slice(0, field.pasteLimit)
      field.pasteBuffer = ""
      var p = field.pasteProcess
      field.pasteProcess = null
      if (p) p.destroy()
      if (got.length && field.insert(got)) field.textEdited()
    })
    pasteProcess.running = true
  }

  // ---------------------------------------------------------------- keys

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var key = event.key
    var enter = key === Qt.Key_Return || key === Qt.Key_Enter
    var passOn = key === Qt.Key_Tab || key === Qt.Key_Backtab || key === Qt.Key_Escape
      || (enter && ctrl) || key === Qt.Key_PageUp || key === Qt.Key_PageDown
      || (!multiline && (key === Qt.Key_Up || key === Qt.Key_Down))
    if (passOn) {
      field.unhandledKey(event)
      return
    }
    var changed = false
    event.accepted = true
    if ((ctrl && key === Qt.Key_V) || (shift && key === Qt.Key_Insert)) { paste(); return }
    if (ctrl && key === Qt.Key_A) { selectAll(); return }
    if (key === Qt.Key_Backspace) changed = removeBefore(ctrl)
    else if (key === Qt.Key_Delete) changed = removeAfter()
    else if (key === Qt.Key_Left) { allSelected = false; cursorPosition = Math.max(0, cursorPosition - 1) }
    else if (key === Qt.Key_Right) { allSelected = false; cursorPosition = Math.min(text.length, cursorPosition + 1) }
    else if (key === Qt.Key_Home || (multiline && key === Qt.Key_Up)) { allSelected = false; cursorPosition = 0 }
    else if (key === Qt.Key_End || (multiline && key === Qt.Key_Down)) { allSelected = false; cursorPosition = text.length }
    else if (enter) {
      if (multiline) changed = insert("\n")
      else { field.accepted(); field.editingFinished() }
    } else if (event.text.length > 0 && !ctrl && (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) === 0
               && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      changed = insert(event.text)
    } else {
      event.accepted = false
      field.unhandledKey(event)
      return
    }
    if (changed) field.textEdited()
  }

  onActiveFocusChanged: {
    if (!activeFocus) {
      allSelected = false
      editingFinished()
    }
  }
  onTextChanged: if (cursorPosition > text.length) cursorPosition = text.length

  // ---------------------------------------------------------------- look

  TextMetrics {
    id: metrics
    font: field.font
    text: "Hg"
  }

  Rectangle {
    id: frame
    anchors.fill: parent
    radius: field.radius
    color: "transparent"
    border.width: field.activeFocus ? 2 : 1
    border.color: field.invalid ? field.urgent : field.activeFocus ? field.accent
      : Qt.rgba(field.foreground.r, field.foreground.g, field.foreground.b, hover.hovered ? 0.5 : 0.28)
  }

  HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

  Item {
    id: viewport
    anchors.fill: parent
    anchors.leftMargin: field.padding
    anchors.rightMargin: field.padding
    anchors.topMargin: field.multiline ? field.padding : 0
    anchors.bottomMargin: field.multiline ? field.padding : 0
    clip: true

    // Everything selected (Ctrl+A): the text sits on the selection tint.
    Rectangle {
      visible: field.allSelected
      x: label.x
      y: label.y + (field.multiline ? 0 : 0)
      width: Math.min(viewport.width, label.implicitWidth)
      height: field.multiline ? label.height : parent.height
      color: Qt.rgba(field.accent.r, field.accent.g, field.accent.b, 0.3)
      radius: 2
    }

    Text {
      id: label
      readonly property string shown: field.activeFocus && !field.allSelected
        ? field.text.slice(0, field.cursorPosition) + field.caret + field.text.slice(field.cursorPosition)
        : field.text
      width: field.multiline ? viewport.width : implicitWidth
      // One line: long text scrolls left so the caret stays in view.
      x: field.multiline ? 0
        : (implicitWidth > viewport.width ? (field.activeFocus ? viewport.width - implicitWidth : 0)
          : (field.horizontalAlignment === Text.AlignHCenter ? (viewport.width - implicitWidth) / 2
            : (field.horizontalAlignment === Text.AlignRight ? viewport.width - implicitWidth : 0)))
      // Many lines: the end stays in view.
      y: field.multiline ? Math.min(0, viewport.height - height) : (viewport.height - height) / 2
      text: shown
      textFormat: Text.PlainText
      wrapMode: field.multiline ? Text.Wrap : Text.NoWrap
      color: field.foreground
      font: field.font
    }

    Text {
      visible: field.text === "" && !field.activeFocus
      anchors.verticalCenter: field.multiline ? undefined : parent.verticalCenter
      y: field.multiline ? 0 : undefined
      width: parent.width
      horizontalAlignment: field.horizontalAlignment
      text: field.placeholderText
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.rgba(field.foreground.r, field.foreground.g, field.foreground.b, 0.4)
      font: field.font
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.IBeamCursor
    onClicked: {
      field.forceActiveFocus()
      field.allSelected = false
      field.cursorPosition = field.text.length
    }
    onDoubleClicked: { field.forceActiveFocus(); field.selectAll() }
  }
}
