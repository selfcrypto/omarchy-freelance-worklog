import QtQuick
import QtTest
import "../.."

// KeyField: typing without an editable Qt text control. Run:
// QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/qml/tst_keyfield.qml
Item {
  width: 440
  height: 320

  property var passed: []

  KeyField {
    id: line
    width: 200
    maximumLength: 8
    onUnhandledKey: function(event) { passed.push(event.key); event.accepted = true }
  }
  KeyField { id: tag; y: 40; width: 100; uppercase: true; maximumLength: 4 }
  KeyField { id: digits; y: 80; width: 100; allowed: /[0-9]/ }
  KeyField { id: area; y: 120; width: 200; multiline: true }
  KeyField { id: longLine; y: 200; width: 80 }
  KeyField { id: longArea; y: 240; width: 120; multiline: true; maxHeight: 60 }
  KeyField { id: longWord; y: 240; x: 150; width: 120; multiline: true; maxHeight: 60 }
  KeyField { id: clickLine; y: 0; x: 220; width: 200 }
  KeyField { id: accents; y: 160; x: 220; width: 200 }
  KeyField { id: clickArea; y: 40; x: 220; width: 200; multiline: true; minHeight: 80 }
  TextMetrics { id: tm; font: clickLine.font }

  SignalSpy { id: accepted; target: line; signalName: "accepted" }
  SignalSpy { id: edited; target: line; signalName: "textEdited" }

  TestCase {
    name: "KeyField"
    when: windowShown

    function init() { line.text = ""; area.text = ""; passed = []; edited.clear(); accepted.clear() }

    function test_typing_and_editing() {
      line.forceActiveFocus()
      keyClick(Qt.Key_A)
      keyClick(Qt.Key_B)
      keyClick(Qt.Key_C)
      compare(line.text, "abc")
      compare(edited.count, 3)
      keyClick(Qt.Key_Left)
      keyClick(Qt.Key_Backspace)
      compare(line.text, "ac")
      keyClick(Qt.Key_Home)
      keyClick(Qt.Key_Delete)
      compare(line.text, "c")
      keyClick(Qt.Key_End)
      keyClick(Qt.Key_Space)
      keyClick(Qt.Key_D)
      compare(line.text, "c d")
    }

    function test_maximum_length() {
      line.forceActiveFocus()
      for (var i = 0; i < 12; i++) keyClick(Qt.Key_X)
      compare(line.text, "xxxxxxxx")
    }

    function test_select_all_then_type_replaces() {
      line.text = "old"
      line.forceActiveFocus()
      keyClick(Qt.Key_A, Qt.ControlModifier)
      keyClick(Qt.Key_N)
      compare(line.text, "n")
    }

    function test_keys_it_does_not_use_go_out() {
      line.forceActiveFocus()
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Escape)
      keyClick(Qt.Key_Return, Qt.ControlModifier)
      // A lone modifier press goes out too; it inserts nothing.
      compare(passed.filter(function(k) { return k !== Qt.Key_Control }), [Qt.Key_Tab, Qt.Key_Escape, Qt.Key_Return])
      compare(line.text, "")
      keyClick(Qt.Key_Return)
      compare(accepted.count, 1)
    }

    function test_uppercase_and_allowed() {
      tag.forceActiveFocus()
      keyClick(Qt.Key_V)
      keyClick(Qt.Key_A)
      compare(tag.text, "VA")
      digits.forceActiveFocus()
      keyClick(Qt.Key_1)
      keyClick(Qt.Key_X)
      keyClick(Qt.Key_2)
      compare(digits.text, "12")
    }

    function test_multiline_enter_is_a_new_line() {
      area.forceActiveFocus()
      keyClick(Qt.Key_A)
      keyClick(Qt.Key_Return)
      keyClick(Qt.Key_B)
      compare(area.text, "a\nb")
    }

    function test_control_characters_never_go_in() {
      line.forceActiveFocus()
      compare(line.insert("a\tb\u0007c"), true)
      compare(line.text, "a b c")
    }

    // Home on a long line: the view goes back to the start with the caret.
    function test_long_line_keeps_the_caret_in_view() {
      longLine.text = "a long company name that never fits in the box"
      longLine.cursorPosition = longLine.text.length
      longLine.forceActiveFocus()
      wait(0)
      verify(longLine.caretViewX > 0 && longLine.caretViewX <= longLine.width, "end: " + longLine.caretViewX)
      keyClick(Qt.Key_Home)
      wait(0)
      verify(longLine.caretViewX > 0 && longLine.caretViewX <= longLine.width, "home: " + longLine.caretViewX)
      keyClick(Qt.Key_X)
      wait(0)
      compare(longLine.text.charAt(0), "x")
      verify(longLine.caretViewX > 0 && longLine.caretViewX <= longLine.width, "typed: " + longLine.caretViewX)
    }

    // Dead keys (´ ` ^ ¨ ~) join the next letter, as a Spanish keyboard types.
    function test_dead_keys_compose() {
      accents.forceActiveFocus()
      keyClick(Qt.Key_Dead_Acute); keyClick(Qt.Key_A)
      // A capital: Shift goes down between the dead key and the letter.
      keyPress(Qt.Key_Dead_Acute); keyRelease(Qt.Key_Dead_Acute)
      keyPress(Qt.Key_Shift); keyClick("E", Qt.ShiftModifier); keyRelease(Qt.Key_Shift)
      keyClick(Qt.Key_Dead_Diaeresis); keyClick(Qt.Key_U)
      keyClick(Qt.Key_Dead_Acute); keyClick(Qt.Key_Space)
      keyClick(Qt.Key_Dead_Acute); keyClick(Qt.Key_X)
      keyClick(Qt.Key_Dead_Grave); keyClick(Qt.Key_Dead_Grave); keyClick(Qt.Key_O)
      compare(accents.text, "\u00e1\u00c9\u00fc\u00b4\u00b4x`\u00f2")
    }

    // A click puts the caret where it lands, on one line and on many.
    function test_click_places_the_caret() {
      clickLine.text = "hello world"
      tm.text = "hello"
      mouseClick(clickLine, clickLine.padding + tm.advanceWidth + 1, clickLine.height / 2)
      compare(clickLine.cursorPosition, 5)
      mouseClick(clickLine, 2, clickLine.height / 2)
      compare(clickLine.cursorPosition, 0)
      mouseClick(clickLine, clickLine.width - 2, clickLine.height / 2)
      compare(clickLine.cursorPosition, 11)
      // Focused now, with the caret at the end: clicks still land on the
      // characters under them.
      tm.text = "he"
      mouseClick(clickLine, clickLine.padding + tm.advanceWidth + 1, clickLine.height / 2)
      compare(clickLine.cursorPosition, 2)
      tm.text = "hello w"
      mouseClick(clickLine, clickLine.padding + tm.advanceWidth + 1, clickLine.height / 2)
      compare(clickLine.cursorPosition, 7)

      clickArea.text = "first line\nsecond line\nthird"
      var lineH = clickArea.lineHeight
      mouseClick(clickArea, clickArea.padding + 1, clickArea.padding + lineH * 1.5)
      compare(clickArea.cursorPosition, 11)
      tm.text = "seco"
      mouseClick(clickArea, clickArea.padding + tm.advanceWidth + 1, clickArea.padding + lineH * 1.5)
      compare(clickArea.cursorPosition, 15)
      mouseClick(clickArea, clickArea.width - clickArea.padding - 2, clickArea.padding + lineH * 0.5)
      compare(clickArea.cursorPosition, 10)
    }

    // Every caret position in a long text with a URL: the caret is in the box,
    // and a click where it is drawn lands on the same position.
    function test_every_position_round_trips() {
      clickArea.text = "Reviewed https://example.com/a/very/long/path/that/never/fits?with=query and the state-machine,\nthen notes."
      clickArea.forceActiveFocus()
      var bad = ""
      for (var p = 0; p <= clickArea.text.length && bad === ""; p++) {
        clickArea.cursorPosition = p
        wait(0)
        if (clickArea.caretViewY > clickArea.height - clickArea.padding + 1 || clickArea.caretViewY - clickArea.lineStep < -1)
          bad = "out of view at " + p + ": " + clickArea.caretViewY
        var x = clickArea.padding + clickArea.caretViewX - clickArea.caretWidth
        var y = clickArea.padding + clickArea.caretViewY - clickArea.lineStep / 2
        if (bad === "" && clickArea.positionAt(x, y) !== p) bad = "click at " + p + " gave " + clickArea.positionAt(x, y)
      }
      compare(bad, "")
    }

    // The caret is drawn over the text: placing it inside a word adds no space.
    function test_the_caret_takes_no_room() {
      clickLine.text = "Auditoria"
      clickLine.focus = false
      wait(0)
      var unfocused = clickLine.contentWidth
      clickLine.forceActiveFocus()
      clickLine.cursorPosition = 6
      wait(0)
      compare(clickLine.contentWidth, unfocused)
      keyClick(Qt.Key_X)
      compare(clickLine.text, "Auditoxria")
    }

    // A word longer than the box (a URL) is broken over lines: with the caret
    // at its start the first line shows, at its end the last.
    function test_long_word_keeps_the_caret_line_in_view() {
      longWord.text = "abcdefghijklmnopqrstuvwxyz".repeat(5)
      longWord.cursorPosition = 0
      longWord.forceActiveFocus()
      wait(0)
      compare(longWord.scrolledY, 0)
      keyClick(Qt.Key_End, Qt.ControlModifier)
      wait(0)
      verify(longWord.scrolledY > 0, "end: " + longWord.scrolledY)
      keyClick(Qt.Key_Home, Qt.ControlModifier)
      wait(0)
      compare(longWord.scrolledY, 0)
    }

    // Ctrl+Home in a long summary: its first line comes into view.
    function test_long_text_keeps_the_caret_line_in_view() {
      longArea.text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen"
      longArea.cursorPosition = longArea.text.length
      longArea.forceActiveFocus()
      wait(0)
      verify(longArea.height < 70, "box is capped: " + longArea.height)
      verify(longArea.caretViewY > 0 && longArea.caretViewY <= longArea.height, "end: " + longArea.caretViewY)
      keyClick(Qt.Key_Home, Qt.ControlModifier)
      wait(0)
      compare(longArea.cursorPosition, 0)
      verify(longArea.caretViewY > 0 && longArea.caretViewY <= longArea.height, "start: " + longArea.caretViewY)
    }
    // Shift+arrows select; typing replaces the selection; Left drops it.
    function test_keyboard_selection() {
      clickLine.text = "hello world"
      clickLine.forceActiveFocus()
      clickLine.cursorPosition = 11
      keyClick(Qt.Key_Left, Qt.ShiftModifier | Qt.ControlModifier)
      compare(clickLine.selectedText, "world")
      keyClick(Qt.Key_Left, Qt.ShiftModifier)
      compare(clickLine.selectedText, " world")
      keyClick(Qt.Key_Left)
      verify(!clickLine.hasSelection)
      compare(clickLine.cursorPosition, 5)
      keyClick(Qt.Key_End, Qt.ShiftModifier)
      keyClick(Qt.Key_X)
      compare(clickLine.text, "hellox")
      keyClick(Qt.Key_Home, Qt.ShiftModifier)
      keyClick(Qt.Key_Backspace)
      compare(clickLine.text, "")
    }

    // Press and drag selects; Shift+click extends; a double click takes a word.
    function test_mouse_selection() {
      clickLine.text = "hello world"
      var y = clickLine.height / 2
      tm.text = "he"
      var x2 = clickLine.padding + tm.advanceWidth + 1
      tm.text = "hello wo"
      var x8 = clickLine.padding + tm.advanceWidth + 1
      mousePress(clickLine, x2, y)
      mouseMove(clickLine, x8, y)
      mouseRelease(clickLine, x8, y)
      compare(clickLine.selectedText, "llo wo")
      mouseClick(clickLine, clickLine.padding + 1, y, Qt.LeftButton, Qt.ShiftModifier)
      compare(clickLine.selectedText, "he")
      mouseDoubleClickSequence(clickLine, x8, y)
      compare(clickLine.selectedText, "world")
      mouseClick(clickLine, x2, y)
      verify(!clickLine.hasSelection)
      // A click that moves a pixel or two selects nothing; Enter then types
      // where the caret is.
      mousePress(clickLine, x2, y)
      mouseMove(clickLine, x2 + 2, y + 1)
      mouseRelease(clickLine, x2 + 2, y + 1)
      verify(!clickLine.hasSelection, "wobble selected " + JSON.stringify(clickLine.selectedText))
      compare(clickLine.cursorPosition, 2)
    }

    // A click at the end, then Enter and a paste: the new line is not
    // selected, so what comes next goes after it.
    function test_click_then_enter_selects_nothing() {
      area.text = "Hello?"
      mouseClick(area, area.width - area.padding - 2, area.padding + 4)
      compare(area.cursorPosition, 6)
      keyClick(Qt.Key_Return, Qt.ShiftModifier)
      verify(!area.hasSelection, "selected " + JSON.stringify(area.selectedText))
      area.insert("Hello?")
      compare(area.text, "Hello?\nHello?")
      // The same with the anchor a press leaves while the button is down.
      area.selectionAnchor = area.cursorPosition
      area.insert("!")
      verify(!area.hasSelection)
      compare(area.text, "Hello?\nHello?!")
    }

    // Up and Down move a line in a multi-line box, keeping the column.
    function test_lines_up_and_down() {
      area.text = "abcd\nefgh\nij"
      area.forceActiveFocus()
      area.cursorPosition = 7
      keyClick(Qt.Key_Up)
      compare(area.cursorPosition, 2)
      keyClick(Qt.Key_Down, Qt.ShiftModifier)
      keyClick(Qt.Key_Down, Qt.ShiftModifier)
      compare(area.cursorPosition, 12)
      compare(area.selectedText, "cd\nefgh\nij")
      keyClick(Qt.Key_Home)
      compare(area.cursorPosition, 10)
    }

    // The summary keeps keypad navigation (NumLock off); time boxes type digits.
    function test_keypad_in_summary() {
      area.text = "ab\ncd"
      area.forceActiveFocus()
      area.cursorPosition = 1
      keyClick(Qt.Key_Delete, Qt.KeypadModifier)
      compare(area.text, "a\ncd")
      keyClick(Qt.Key_Down, Qt.KeypadModifier)
      compare(area.cursorPosition, 3)
    }

    // Down twice across a short line comes back to the column it left.
    function test_vertical_moves_keep_the_column() {
      area.text = "abcdefghij\nx\nabcdefghij"
      area.forceActiveFocus()
      area.cursorPosition = 8
      keyClick(Qt.Key_Down)
      compare(area.cursorPosition, 12)
      keyClick(Qt.Key_Down)
      compare(area.cursorPosition, 21)
      keyClick(Qt.Key_Up, Qt.ShiftModifier)
      keyClick(Qt.Key_Up, Qt.ShiftModifier)
      compare(area.cursorPosition, 8)
    }

    // End on a word cut by the wrap stays on its line; typing goes there.
    function test_end_stays_on_a_wrapped_word_line() {
      longWord.text = "abcdefghijklmnopqrstuvwxyz".repeat(3)
      longWord.forceActiveFocus()
      longWord.cursorPosition = 0
      keyClick(Qt.Key_End)
      compare(longWord.caretLine, 0)
      verify(longWord.cursorPosition > 0 && longWord.cursorPosition === longWord.lines[0].end)
      var x = longWord.caretX
      keyClick(Qt.Key_Home)
      compare(longWord.cursorPosition, 0)
      keyClick(Qt.Key_End, Qt.ShiftModifier)
      compare(longWord.caretLine, 0)
      compare(longWord.caretX, x)
      // Right drops the selection at its end, then moves into the next line.
      keyClick(Qt.Key_Right)
      compare(longWord.caretLine, 0)
      keyClick(Qt.Key_Right)
      compare(longWord.caretLine, 1)
      compare(longWord.cursorPosition, longWord.lines[1].start + 1)
      // A click past the end of the first line lands at its end, on that line.
      mouseClick(longWord, longWord.width - longWord.padding - 1, longWord.padding + 2)
      compare(longWord.cursorPosition, longWord.lines[0].end)
      compare(longWord.caretLine, 0)
    }

    // Text set from outside (a form reload) drops the selection.
    function test_selection_after_external_text() {
      area.text = "hello world"
      area.forceActiveFocus()
      area.cursorPosition = 0
      keyClick(Qt.Key_End, Qt.ShiftModifier)
      compare(area.selectedText, "hello world")
      area.text = "other text!"
      verify(!area.hasSelection, "selected " + JSON.stringify(area.selectedText))
    }

    // Ctrl+X takes the selection out (the copy itself runs under qs).
    function test_cut_removes_the_selection() {
      clickLine.text = "hello world"
      clickLine.forceActiveFocus()
      clickLine.cursorPosition = 5
      keyClick(Qt.Key_End, Qt.ShiftModifier)
      keyClick(Qt.Key_X, Qt.ControlModifier)
      // No Quickshell here: the copy fails and the text stays.
      compare(clickLine.text, "hello world")
      keyClick(Qt.Key_Delete)
      compare(clickLine.text, "hello")
    }
  }
}
