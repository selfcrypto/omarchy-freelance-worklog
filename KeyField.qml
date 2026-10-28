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
// (no layout queries on a Text). The view follows it: the text before the
// caret is measured, and the field scrolls so the caret's end (one line) or
// its line (many lines) stays inside the box. Keys the field does not use (Tab, Escape,
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
  // Where the caret ends inside the visible box (x on one line, the bottom of
  // its line on many); tests check both stay in view.
  readonly property real caretViewX: label.x + caretMetrics.advanceWidth
  readonly property real caretViewY: label.y + caretBottom
  // How far the text is scrolled up inside the box (0: its first line shows).
  readonly property real scrolledY: -label.y

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

  readonly property int pasteLimit: 4096   // bytes of UTF-8
  property var pasteProcess: null
  property string pasteBuffer: ""
  property int pasteBytes: 0
  property bool pasteFull: false

  // The longest start of `s` within `budget` bytes of UTF-8, cut at a whole
  // character: { text, bytes, cut }.
  function utf8Cut(s, budget) {
    var bytes = 0
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      var n = c < 0x80 ? 1 : (c < 0x800 ? 2 : (c >= 0xd800 && c < 0xdc00 ? 4 : 3))
      if (bytes + n > budget) return { text: s.slice(0, i), bytes: bytes, cut: true }
      bytes += n
      if (n === 4) i++
    }
    return { text: s, bytes: bytes, cut: false }
  }

  function paste() {
    if (pasteProcess) return
    try {
      // An empty split marker hands over each chunk as it arrives, so a
      // clipboard with no newline is never buffered whole before the cap.
      pasteProcess = Qt.createQmlObject('import Quickshell.Io; Process { stdout: SplitParser { splitMarker: "" } }', field, "KeyFieldPaste")
    } catch (e) {
      pasteProcess = null
      return
    }
    pasteBuffer = ""
    pasteBytes = 0
    pasteFull = false
    pasteProcess.command = ["timeout", "-k", "1", "2", "wl-paste", "--no-newline", "--type", "text/plain"]
    pasteProcess.stdout.read.connect(function(chunk) {
      if (field.pasteFull) return
      var r = field.utf8Cut(String(chunk), field.pasteLimit - field.pasteBytes)
      field.pasteBuffer += r.text
      field.pasteBytes += r.bytes
      // Past the cap: stop reading, keep what fits.
      if (r.cut) {
        field.pasteFull = true
        if (field.pasteProcess) field.pasteProcess.running = false
      }
    })
    pasteProcess.exited.connect(function() {
      var got = field.pasteBuffer
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

  // The shown text up to and including the caret.
  readonly property string beforeCaret: label.shown.slice(0, field.activeFocus && !field.allSelected ? field.cursorPosition + caret.length : field.cursorPosition)
  // Many lines: the rest of the caret's word. Laid out up to the end of that
  // word, the text wraps exactly as the shown text does; the caret's line ends
  // no lower than that, and at most one line below the text up to the caret
  // (its piece of the word may not fit on that line). The lower of the two
  // bounds is kept in view, so a word broken over several lines (a URL)
  // leaves the caret at most one line above the bottom edge.
  readonly property string wordTail: multiline ? (label.shown.slice(beforeCaret.length).match(/^\S*/) || [""])[0] : ""
  readonly property real caretBottom: Math.min(caretWordProbe.height,
    caretProbe.height + (caretProbe.lineCount > 0 ? caretProbe.height / caretProbe.lineCount : lineHeight))

  TextMetrics {
    id: caretMetrics
    font: field.font
    text: field.multiline ? "" : field.beforeCaret
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
      // One line: long text scrolls so the caret stays in view.
      x: field.multiline ? 0
        : (implicitWidth > viewport.width ? (field.activeFocus ? Math.min(0, Math.max(viewport.width - implicitWidth, viewport.width - caretMetrics.advanceWidth)) : 0)
          : (field.horizontalAlignment === Text.AlignHCenter ? (viewport.width - implicitWidth) / 2
            : (field.horizontalAlignment === Text.AlignRight ? viewport.width - implicitWidth : 0)))
      // Many lines: the caret's line stays in view (the end while unfocused).
      y: field.multiline
        ? (field.activeFocus ? Math.min(0, Math.max(viewport.height - height, viewport.height - field.caretBottom)) : Math.min(0, viewport.height - height))
        : (viewport.height - height) / 2
      text: shown
      textFormat: Text.PlainText
      wrapMode: field.multiline ? Text.Wrap : Text.NoWrap
      color: field.foreground
      font: field.font
    }

    // Many lines: the text up to the caret, and up to the end of its word,
    // wrapped as the shown text is (see `caretBottom`).
    Text {
      id: caretProbe
      visible: false
      width: viewport.width
      text: field.multiline ? field.beforeCaret : ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      font: field.font
    }
    Text {
      id: caretWordProbe
      visible: false
      width: viewport.width
      text: field.multiline ? field.beforeCaret + field.wordTail : ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
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
