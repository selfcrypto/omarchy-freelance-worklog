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
// The field lays its text out itself (`wrapLines`: word wrap measured with
// FontMetrics, a word wider than the box broken anywhere), so it knows where
// every character is: the caret is a bar drawn over the text at its measured
// place, a click finds the character under it, and the view scrolls to keep
// the caret in the box. A plain Text has no positionAt to ask. Keys the field
// does not use (Tab, Escape, Ctrl+Enter, Up/Down on one line) go out through
// `unhandledKey(event)` first, then to the parent items if still not accepted.
//
// Without an input method, dead keys (´ ` ^ ¨ ~ on a Spanish keyboard) come
// as key presses of their own; the field joins them to the next letter
// (´ then a: á).
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

  readonly property real lineHeight: Math.ceil(fm.height)
  readonly property real caretWidth: 2
  // Where the caret is inside the visible box: its right edge (x) and the
  // bottom of its line (y); tests check both stay in view.
  readonly property real caretViewX: label.x + caretX + caretWidth
  readonly property real caretViewY: label.y + (caretLine + 1) * lineStep
  // How far the text is scrolled up inside the box (0: its first line shows).
  readonly property real scrolledY: -label.y
  // The width of the shown text; the caret never adds to it.
  readonly property real contentWidth: label.implicitWidth

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

  // Dead key codes to their combining mark and their spacing form.
  readonly property var deadMarks: ({
    16781904: ["\u0300", "`"], 16781905: ["\u0301", "´"], 16781906: ["\u0302", "^"], 16781907: ["\u0303", "~"],
    16781908: ["\u0304", "¯"], 16781909: ["\u0306", "˘"], 16781910: ["\u0307", "˙"], 16781911: ["\u0308", "¨"],
    16781912: ["\u030a", "˚"], 16781913: ["\u030b", "˝"], 16781914: ["\u030c", "ˇ"], 16781915: ["\u0327", "¸"] })
  property int pendingDead: 0

  // Typed text with a pending dead key joined to it: the accented letter, the
  // accent itself before a space, or both when they do not combine.
  function withDead(t) {
    var d = deadMarks[pendingDead]
    pendingDead = 0
    if (!d) return t
    if (t === " ") return d[1]
    var joined = (t + d[0]).normalize("NFC")
    return joined.length === t.length ? joined : d[1] + t
  }

  Keys.onPressed: function(event) {
    if (deadMarks[event.key] !== undefined) {
      // A second dead key types the first one's accent.
      var before = pendingDead ? deadMarks[pendingDead][1] : ""
      pendingDead = event.key
      if (before && insert(before)) field.textEdited()
      event.accepted = true
      return
    }
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
    // Anything but a letter drops a pending dead key; modifiers (Shift for a
    // capital, AltGr) keep it.
    var modifierKey = key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt || key === Qt.Key_AltGr
      || key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_CapsLock
    if (pendingDead && !modifierKey && !(event.text.length > 0 && event.text.charCodeAt(0) >= 32)) pendingDead = 0
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
      changed = insert(withDead(event.text))
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

  // ---------------------------------------------------------------- layout

  FontMetrics { id: fm; font: field.font }

  // The lines the text is shown in, as { start, end, soft } ranges of `text`
  // (end exclusive; `soft`: the line was wrapped, not ended by a newline).
  // Spaces at a wrap stay on the line they end.
  function wrapLines(s, maxW) {
    var out = []
    var at = 0
    while (true) {
      var nl = s.indexOf("\n", at)
      var stop = nl < 0 ? s.length : nl
      var start = at
      do {
        var end = stop
        if (fm.advanceWidth(s.slice(start, stop)) > maxW) {
          // The longest run from `start` that fits, at least one character.
          var lo = start + 1, hi = stop, fit = start + 1
          while (lo <= hi) { var mid = (lo + hi) >> 1; if (fm.advanceWidth(s.slice(start, mid)) <= maxW) { fit = mid; lo = mid + 1 } else hi = mid - 1 }
          // Back to the last space in it; a word wider than the box is cut.
          end = fit
          if (s.charAt(fit) !== " ") {
            var space = s.lastIndexOf(" ", fit - 1)
            if (space > start) end = space + 1
          }
          while (end < stop && s.charAt(end) === " ") end++
        }
        out.push({ start: start, end: end, soft: end < stop })
        start = end
      } while (start < stop)
      if (nl < 0) break
      at = nl + 1
    }
    return out
  }

  readonly property var lines: {
    field.font
    return multiline ? wrapLines(text, Math.max(fm.maximumCharacterWidth, viewport.width - caretWidth))
      : [{ start: 0, end: text.length, soft: false }]
  }
  // The distance between lines as the label draws them.
  readonly property real lineStep: lines.length > 0 && label.implicitHeight > 0 ? label.implicitHeight / lines.length : lineHeight

  // The caret's line (at a wrap, the start of the next line) and its x on it.
  readonly property int caretLine: {
    var c = Math.min(cursorPosition, text.length)
    var i = 0
    while (i + 1 < lines.length && lines[i + 1].start <= c) i++
    return i
  }
  readonly property real caretX: {
    field.font
    var l = lines[caretLine]
    return l ? fm.advanceWidth(text.slice(l.start, Math.min(cursorPosition, text.length))) : 0
  }

  // The text position under (x, y), in the field's coordinates.
  function positionAt(x, y) {
    if (lines.length === 0) return 0
    var i = Math.max(0, Math.min(lines.length - 1, Math.floor((y - viewport.y - label.y) / lineStep)))
    var l = lines[i]
    var lx = x - viewport.x - label.x
    // A wrapped line's last place is before its trailing space: after it is
    // the next line's start.
    var last = l.soft && l.end > l.start && text.charAt(l.end - 1) === " " ? l.end - 1 : l.end
    // The character under the click: the first whose right edge is past it.
    // The caret goes before it, or after it when the click is past its middle.
    var a = l.start, b = last
    while (a < b) { var m = (a + b) >> 1; if (fm.advanceWidth(text.slice(l.start, m + 1)) < lx) a = m + 1; else b = m }
    if (a < last && lx > (fm.advanceWidth(text.slice(l.start, a)) + fm.advanceWidth(text.slice(l.start, a + 1))) / 2) a++
    return Math.max(0, Math.min(text.length, a))
  }

  // ---------------------------------------------------------------- look

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
      y: label.y
      width: Math.min(viewport.width, label.implicitWidth)
      height: field.multiline ? label.height : parent.height
      color: Qt.rgba(field.accent.r, field.accent.g, field.accent.b, 0.3)
      radius: 2
    }

    Text {
      id: label
      width: implicitWidth
      // One line: long text scrolls so the caret stays in view.
      x: field.multiline ? 0
        : (implicitWidth + field.caretWidth > viewport.width
          ? (field.activeFocus ? Math.min(0, Math.max(viewport.width - implicitWidth - field.caretWidth, viewport.width - field.caretX - field.caretWidth)) : 0)
          : (field.horizontalAlignment === Text.AlignHCenter ? (viewport.width - implicitWidth) / 2
            : (field.horizontalAlignment === Text.AlignRight ? viewport.width - implicitWidth - field.caretWidth : 0)))
      // Many lines: the caret's line stays in view (the end while unfocused).
      y: field.multiline
        ? (field.activeFocus ? Math.min(0, Math.max(viewport.height - height, viewport.height - (field.caretLine + 1) * field.lineStep))
          : Math.min(0, viewport.height - height))
        : (viewport.height - height) / 2
      // The laid-out lines; a wrap becomes a line break here.
      text: {
        var out = []
        for (var i = 0; i < field.lines.length; i++) out.push(field.text.slice(field.lines[i].start, field.lines[i].end))
        return out.join("\n")
      }
      textFormat: Text.PlainText
      wrapMode: Text.NoWrap
      color: field.foreground
      font: field.font
    }

    // The caret: a bar over the text, so the text never moves for it.
    Rectangle {
      visible: field.activeFocus && !field.allSelected
      x: label.x + field.caretX
      y: label.y + field.caretLine * field.lineStep + (field.lineStep - height) / 2
      width: field.caretWidth
      height: Math.min(field.lineStep, field.lineHeight)
      color: field.foreground
    }

    Text {
      visible: field.text === "" && !field.activeFocus
      anchors.verticalCenter: field.multiline ? undefined : parent.verticalCenter
      y: 0
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
    onClicked: function(mouse) {
      field.forceActiveFocus()
      field.allSelected = false
      field.pendingDead = 0
      field.cursorPosition = field.positionAt(mouse.x, mouse.y)
    }
    onDoubleClicked: { field.forceActiveFocus(); field.selectAll() }
  }
}
