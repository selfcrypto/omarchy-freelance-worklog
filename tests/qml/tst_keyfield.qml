import QtQuick
import QtTest
import "../.."

// KeyField: typing without an editable Qt text control. Run:
// QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/qml/tst_keyfield.qml
Item {
  width: 300
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

  SignalSpy { id: accepted; target: line; signalName: "accepted" }
  SignalSpy { id: edited; target: line; signalName: "textEdited" }

  TestCase {
    name: "KeyField"
    when: windowShown

    function init() { line.text = ""; passed = []; edited.clear(); accepted.clear() }

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

    // A word longer than the box (a URL) is broken over lines: with the caret
    // at its start the first line shows, at its end the last.
    function test_long_word_keeps_the_caret_line_in_view() {
      longWord.text = "abcdefghijklmnopqrstuvwxyz".repeat(5)
      longWord.cursorPosition = 0
      longWord.forceActiveFocus()
      wait(0)
      compare(longWord.scrolledY, 0)
      keyClick(Qt.Key_End)
      wait(0)
      verify(longWord.scrolledY > 0, "end: " + longWord.scrolledY)
      keyClick(Qt.Key_Up)
      wait(0)
      compare(longWord.scrolledY, 0)
    }

    // Up (start) in a long summary: its first line comes into view.
    function test_long_text_keeps_the_caret_line_in_view() {
      longArea.text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen"
      longArea.cursorPosition = longArea.text.length
      longArea.forceActiveFocus()
      wait(0)
      verify(longArea.height < 70, "box is capped: " + longArea.height)
      verify(longArea.caretViewY > 0 && longArea.caretViewY <= longArea.height, "end: " + longArea.caretViewY)
      keyClick(Qt.Key_Up)
      wait(0)
      compare(longArea.cursorPosition, 0)
      verify(longArea.caretViewY > 0 && longArea.caretViewY <= longArea.height, "start: " + longArea.caretViewY)
    }
  }
}
