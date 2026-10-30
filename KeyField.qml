import QtQuick

// A text field without an editable Qt text control. It draws plain Text and
// takes keys one by one. The clipboard is read only on Ctrl+V or Shift+Insert,
// through fixed `wl-paste` calls under `timeout`, at most 4096 bytes; Ctrl+C
// and Ctrl+X write the selection with `wl-copy`, the text on its stdin.
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

  // A click that brings focus selects everything (time boxes: typing replaces).
  property bool selectOnFocus: false
  // Keypad keys that arrive as navigation type their digit (time boxes: the
  // panel may be told NumLock is off while it is on).
  property bool keypadDigits: false
  property int cursorPosition: text.length
  // At a soft wrap the same position ends one line and starts the next; true
  // shows the caret at the end of the line before (End, a click past a line).
  property bool caretUpstream: false
  // The x Up and Down aim for, kept across a run of them; -1 when unset.
  property real preferredX: -1
  property bool verticalMove: false
  property bool ownEdit: false
  // The other end of the selection, or -1. The selection runs between it and
  // the cursor.
  property int selectionAnchor: -1
  readonly property int selectionStart: hasSelection ? Math.min(selectionAnchor, cursorPosition) : cursorPosition
  readonly property int selectionEnd: hasSelection ? Math.max(selectionAnchor, cursorPosition) : cursorPosition
  readonly property bool hasSelection: selectionAnchor >= 0 && selectionAnchor !== cursorPosition && selectionAnchor <= text.length
  readonly property bool allSelected: hasSelection && selectionStart === 0 && selectionEnd === text.length
  readonly property string selectedText: hasSelection ? text.slice(selectionStart, selectionEnd) : ""
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

  // Every edit the field makes goes through here; any other change of `text`
  // (a binding, a form reload) drops the selection.
  function setText(t) { ownEdit = true; text = t; ownEdit = false }

  function selectAll() { cursorPosition = text.length; selectionAnchor = text.length > 0 ? 0 : -1 }
  function deselect() { selectionAnchor = -1 }

  // Moves the caret; `extend` grows the selection from where it was.
  function moveCursor(pos, extend) {
    pos = Math.max(0, Math.min(text.length, pos))
    if (extend) { if (selectionAnchor < 0) selectionAnchor = cursorPosition }
    else selectionAnchor = -1
    cursorPosition = pos
  }

  function isSpace(c) { return c === " " || c === "\n" }
  // The start of the word before `pos` and the end of the word after it.
  function wordBefore(pos) {
    while (pos > 0 && isSpace(text.charAt(pos - 1))) pos--
    while (pos > 0 && !isSpace(text.charAt(pos - 1))) pos--
    return pos
  }
  function wordAfter(pos) {
    while (pos < text.length && isSpace(text.charAt(pos))) pos++
    while (pos < text.length && !isSpace(text.charAt(pos))) pos++
    return pos
  }
  // The word under `pos`, selected (a double click).
  function selectWord(pos) {
    var a = pos, b = pos
    while (a > 0 && !isSpace(text.charAt(a - 1))) a--
    while (b < text.length && !isSpace(text.charAt(b))) b++
    selectionAnchor = a
    cursorPosition = b
  }

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

  // An anchor at the caret (left by a click) selects nothing; edits drop it so
  // the text they add is not selected.
  function removeSelection() {
    if (!hasSelection) { selectionAnchor = -1; return false }
    var a = selectionStart
    setText(text.slice(0, a) + text.slice(selectionEnd))
    selectionAnchor = -1
    cursorPosition = a
    return true
  }

  // Types `s` at the caret, over the selection if there is one.
  function insert(s) {
    s = clean(s)
    if (s.length === 0) return false
    var removed = removeSelection()
    var room = maximumLength - text.length
    if (room <= 0) return removed
    s = s.slice(0, room)
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    setText(text.slice(0, at) + s + text.slice(at))
    cursorPosition = at + s.length
    return true
  }

  function removeBefore(word) {
    if (removeSelection()) return true
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    if (at === 0) return false
    var from = word ? wordBefore(at) : at - 1
    setText(text.slice(0, from) + text.slice(at))
    cursorPosition = from
    return true
  }

  function removeAfter() {
    if (removeSelection()) return true
    var at = Math.max(0, Math.min(cursorPosition, text.length))
    if (at >= text.length) return false
    setText(text.slice(0, at) + text.slice(at + 1))
    return true
  }

  // ---------------------------------------------------------------- copy

  // The selection to the clipboard: `wl-copy` reads it from stdin, so no
  // text is ever on a command line. `done(ok)` hears whether it got there.
  function copy(done) {
    if (!hasSelection) return false
    var p
    try {
      p = Qt.createQmlObject('import Quickshell.Io; Process { property string payload: ""; onStarted: { write(payload); payload = ""; stdinEnabled = false } }', field, "KeyFieldCopy")
    } catch (e) {
      console.warn("KeyField: no clipboard writer: " + e)
      return false
    }
    p.command = ["timeout", "-k", "1", "3", "wl-copy", "--type", "text/plain;charset=utf-8"]
    p.payload = selectedText
    p.stdinEnabled = true
    p.exited.connect(function(code) {
      p.destroy()
      if (code !== 0) console.warn("KeyField: copy failed, exit " + code)
      if (done) done(code === 0)
    })
    p.running = true
    return true
  }

  // Cut: the selection goes once the clipboard has it, and only if the text
  // has not changed meanwhile; a failed copy keeps it.
  function cut() {
    var before = text, from = selectionStart, to = selectionEnd
    return copy(function(ok) {
      if (!ok || field.text !== before) return
      field.selectionAnchor = from
      field.cursorPosition = to
      if (field.removeSelection()) field.textEdited()
    })
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

  // The text types asked for, best first. Never the generic "text": it takes
  // text/html when that is offered first.
  readonly property var pasteTypes: ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"]

  // Asks the clipboard which types it offers, then reads the best text one.
  function paste() {
    if (pasteProcess) return
    readClipboard(["--list-types"], function(offered) {
      var types = offered.split("\n")
      for (var i = 0; i < field.pasteTypes.length; i++) {
        if (types.indexOf(field.pasteTypes[i]) >= 0) {
          field.readClipboard(["--no-newline", "--type", field.pasteTypes[i]], function(got) {
            if (got.length && field.insert(got)) field.textEdited()
          })
          return
        }
      }
    })
  }

  // One `wl-paste` call, its output capped at pasteLimit bytes; `done` gets it.
  function readClipboard(args, done) {
    var p
    try {
      // An empty split marker hands over each chunk as it arrives, so a
      // clipboard with no newline is never buffered whole before the cap.
      p = Qt.createQmlObject('import Quickshell.Io; Process { stdout: SplitParser { splitMarker: "" } }', field, "KeyFieldPaste")
    } catch (e) {
      console.warn("KeyField: no clipboard reader: " + e)
      return
    }
    pasteProcess = p
    pasteBuffer = ""
    pasteBytes = 0
    pasteFull = false
    p.command = ["timeout", "-k", "1", "2", "wl-paste"].concat(args)
    p.stdout.read.connect(function(chunk) {
      if (field.pasteFull) return
      var r = field.utf8Cut(String(chunk), field.pasteLimit - field.pasteBytes)
      field.pasteBuffer += r.text
      field.pasteBytes += r.bytes
      // Past the cap: stop reading, keep what fits.
      if (r.cut) {
        field.pasteFull = true
        p.running = false
      }
    })
    p.exited.connect(function() {
      var got = field.pasteBuffer
      field.pasteBuffer = ""
      field.pasteProcess = null
      p.destroy()
      done(got)
    })
    p.running = true
  }

  // ---------------------------------------------------------------- keys

  // Dead key codes to their combining mark and their spacing form.
  readonly property var deadMarks: ({
    16781904: ["\u0300", "`"], 16781905: ["\u0301", "´"], 16781906: ["\u0302", "^"], 16781907: ["\u0303", "~"],
    16781908: ["\u0304", "¯"], 16781909: ["\u0306", "˘"], 16781910: ["\u0307", "˙"], 16781911: ["\u0308", "¨"],
    16781912: ["\u030a", "˚"], 16781913: ["\u030b", "˝"], 16781914: ["\u030c", "ˇ"], 16781915: ["\u0327", "¸"] })
  property int pendingDead: 0

  // The keypad keys as NumLock off reports them, to the character they type
  // with it on (`keypadDigits`). The panel may be told NumLock is off while it
  // is on, until it is pressed twice.
  readonly property var keypadChars: ({
    [Qt.Key_Insert]: "0", [Qt.Key_End]: "1", [Qt.Key_Down]: "2", [Qt.Key_PageDown]: "3", [Qt.Key_Left]: "4",
    [Qt.Key_Clear]: "5", [Qt.Key_Right]: "6", [Qt.Key_Home]: "7", [Qt.Key_Up]: "8", [Qt.Key_PageUp]: "9", [Qt.Key_Delete]: "." })

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
    if (!hasSelection) selectionAnchor = -1
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
    if (keypadDigits && (event.modifiers & Qt.KeypadModifier) && !ctrl && !shift && keypadChars[key] !== undefined) {
      if (insert(withDead(keypadChars[key]))) field.textEdited()
      event.accepted = true
      return
    }
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
    var lineEnds = field.lines[field.caretLine] || { start: 0, end: text.length }
    if ((ctrl && key === Qt.Key_V) || (shift && key === Qt.Key_Insert)) { paste(); return }
    if ((ctrl && key === Qt.Key_C) || (ctrl && key === Qt.Key_Insert)) { copy(); return }
    if ((ctrl && key === Qt.Key_X) || (shift && key === Qt.Key_Delete)) { cut(); return }
    if (ctrl && key === Qt.Key_A) { selectAll(); return }
    else if (key === Qt.Key_Backspace) changed = removeBefore(ctrl)
    else if (key === Qt.Key_Delete) changed = removeAfter()
    else if (key === Qt.Key_Left) {
      if (hasSelection && !shift && !ctrl) moveCursor(selectionStart, false)
      else moveCursor(ctrl ? wordBefore(cursorPosition) : cursorPosition - 1, shift)
    } else if (key === Qt.Key_Right) {
      if (hasSelection && !shift && !ctrl) moveCursor(selectionEnd, false)
      else moveCursor(ctrl ? wordAfter(cursorPosition) : cursorPosition + 1, shift)
    }
    else if (key === Qt.Key_Home) moveCursor(ctrl || !multiline ? 0 : lineEnds.start, shift)
    else if (key === Qt.Key_End) {
      if (ctrl || !multiline) moveCursor(text.length, shift)
      else { var endLine = field.caretLine, endAt = lineEnd(endLine); moveCursor(endAt, shift); caretUpstream = atSoftEnd(endLine, endAt) }
    }
    else if (multiline && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      var aimX = preferredX >= 0 ? preferredX : field.caretX
      var target = field.caretLine + (key === Qt.Key_Up ? -1 : 1)
      verticalMove = true
      if (target < 0) moveCursor(0, shift)
      else if (target >= field.lines.length) moveCursor(text.length, shift)
      else { var to = positionOnLine(target, aimX); moveCursor(to, shift); caretUpstream = atSoftEnd(target, to) }
      verticalMove = false
      preferredX = aimX
    }
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
      selectionAnchor = -1
      editingFinished()
    }
  }
  onTextChanged: {
    if (cursorPosition > text.length) cursorPosition = text.length
    if (!ownEdit || selectionAnchor > text.length) selectionAnchor = -1
  }
  onCursorPositionChanged: {
    caretUpstream = false
    if (!verticalMove) preferredX = -1
  }

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
    if (caretUpstream && i > 0 && lines[i].start === c && lines[i - 1].soft && lines[i - 1].end === c) i--
    return i
  }
  readonly property real caretX: {
    field.font
    var l = lines[caretLine]
    return l ? fm.advanceWidth(text.slice(l.start, Math.min(cursorPosition, text.length))) : 0
  }

  // Where line `i` ends for the caret: before the space a wrap left on it
  // (after that space is the next line's start).
  function lineEnd(i) {
    var l = lines[i]
    return l.soft && l.end > l.start && text.charAt(l.end - 1) === " " ? l.end - 1 : l.end
  }

  // The position on line `i` nearest to `lx` (the line's own x).
  function positionOnLine(i, lx) {
    var l = lines[i]
    var last = lineEnd(i)
    // The character under lx: the first whose right edge is past it. The
    // caret goes before it, or after it when lx is past its middle.
    var a = l.start, b = last
    while (a < b) { var m = (a + b) >> 1; if (fm.advanceWidth(text.slice(l.start, m + 1)) < lx) a = m + 1; else b = m }
    if (a < last && lx > (fm.advanceWidth(text.slice(l.start, a)) + fm.advanceWidth(text.slice(l.start, a + 1))) / 2) a++
    return Math.max(0, Math.min(text.length, a))
  }

  // Whether `pos` on line `i` is the end of a wrapped line that is also the
  // next line's start (a word cut by the wrap): the caret shows on line i.
  function atSoftEnd(i, pos) {
    var l = lines[i]
    return !!l && l.soft && pos === l.end
  }

  // The text position under (x, y), in the field's coordinates, and whether
  // the caret shows at the end of its line: { pos, upstream }.
  function hitAt(x, y) {
    if (lines.length === 0) return { pos: 0, upstream: false }
    var i = Math.max(0, Math.min(lines.length - 1, Math.floor((y - viewport.y - label.y) / lineStep)))
    var pos = positionOnLine(i, x - viewport.x - label.x)
    return { pos: pos, upstream: atSoftEnd(i, pos) }
  }
  function positionAt(x, y) { return hitAt(x, y).pos }

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

    // The selection: a tint under the selected part of each line; a selected
    // line break shows as a space's width.
    Repeater {
      model: field.hasSelection ? field.lines : []
      delegate: Rectangle {
        required property var modelData
        required property int index
        readonly property int from: Math.max(field.selectionStart, modelData.start)
        readonly property int to: Math.min(field.selectionEnd, modelData.end)
        readonly property bool breakSelected: !modelData.soft && modelData.end < field.text.length && field.selectionEnd > modelData.end && field.selectionStart <= modelData.end
        visible: to > from || breakSelected
        x: label.x + fm.advanceWidth(field.text.slice(modelData.start, Math.min(from, modelData.end)))
        y: label.y + index * field.lineStep
        width: (to > from ? fm.advanceWidth(field.text.slice(from, to)) : 0) + (breakSelected ? fm.advanceWidth(" ") : 0)
        height: field.lineStep
        color: Qt.rgba(field.accent.r, field.accent.g, field.accent.b, 0.3)
        radius: 2
      }
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
      visible: field.activeFocus
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

  // Press places the caret, a drag selects, Shift+click extends, a double
  // click selects the word. A drag starts past the system drag distance, so
  // a click that wobbles a pixel selects nothing.
  MouseArea {
    property point pressedAt
    property bool dragging: false
    anchors.fill: parent
    cursorShape: Qt.IBeamCursor
    preventStealing: true
    onPressed: function(mouse) {
      var focused = field.activeFocus
      field.forceActiveFocus()
      field.pendingDead = 0
      pressedAt = Qt.point(mouse.x, mouse.y)
      dragging = false
      if (!focused && field.selectOnFocus && !(mouse.modifiers & Qt.ShiftModifier)) { field.selectAll(); return }
      var hit = field.hitAt(mouse.x, mouse.y)
      field.moveCursor(hit.pos, (mouse.modifiers & Qt.ShiftModifier) !== 0)
      field.caretUpstream = hit.upstream
      if (!field.hasSelection) field.selectionAnchor = field.cursorPosition
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      if (!dragging && Math.abs(mouse.x - pressedAt.x) < Qt.styleHints.startDragDistance
          && Math.abs(mouse.y - pressedAt.y) < Qt.styleHints.startDragDistance) return
      dragging = true
      var hit = field.hitAt(mouse.x, mouse.y)
      field.cursorPosition = hit.pos
      field.caretUpstream = hit.upstream
    }
    onReleased: if (!field.hasSelection) field.selectionAnchor = -1
    onDoubleClicked: function(mouse) { field.selectWord(field.positionAt(mouse.x, mouse.y)) }
  }
}
