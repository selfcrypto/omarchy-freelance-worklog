import QtQuick
import QtTest
import "../.."

// TimeField keeps what is typed (review 2026-10-27). Run:
// QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/qml/tst_timefield.qml
// TimeField is a KeyField: plain Text, keys one by one, no Quickshell needed.
Item {
  width: 200
  height: 100

  ListModel { id: rows; ListElement { from: 660 } }

  Repeater {
    id: repeated
    model: rows
    delegate: TimeField {
      required property int index
      required property int from
      width: 150
      minutes: from
      onMinutesEdited: function(m) { rows.setProperty(index, "from", m) }
    }
  }

  TestCase {
    name: "TimeField"
    when: windowShown

    function test_typing_over_a_time() {
      var field = repeated.itemAt(0)
      field.forceActiveFocus()
      field.selectAll()
      keyClick(Qt.Key_1)
      compare(field.text, "1")
      keyClick(Qt.Key_0)
      keyClick(Qt.Key_Colon)
      keyClick(Qt.Key_3)
      keyClick(Qt.Key_0)
      compare(field.text, "10:30")
      compare(rows.get(0).from, 630)
      field.editingFinished()
      compare(field.text, "10:30")
    }

    // A click into a full time box selects it, so digits replace it; keypad
    // keys type digits even when NumLock is reported off.
    function test_click_then_keypad_replaces_the_time() {
      var field = repeated.itemAt(0)
      field.focus = false
      wait(0)
      mouseClick(field, field.width - 4, field.height / 2)
      verify(field.allSelected, "click selects: " + field.selectedText)
      keyClick(Qt.Key_End, Qt.KeypadModifier)
      keyClick(Qt.Key_PageUp, Qt.KeypadModifier)
      compare(field.text, "19:")
      keyClick(Qt.Key_Colon)
      keyClick(Qt.Key_Down, Qt.KeypadModifier)
      keyClick(Qt.Key_0, Qt.KeypadModifier)
      compare(field.text, "19:20")
      // A second click, already focused, places the caret.
      mouseClick(field, field.width - 4, field.height / 2)
      verify(!field.hasSelection)
      field.editingFinished()
    }

    // Digits only: the colon comes and goes by itself.
    function test_colon_comes_and_goes() {
      var field = repeated.itemAt(0)
      field.forceActiveFocus()
      field.selectAll()
      keyClick(Qt.Key_1)
      keyClick(Qt.Key_7)
      compare(field.text, "17:")
      keyClick(Qt.Key_Colon)
      compare(field.text, "17:")
      keyClick(Qt.Key_3)
      keyClick(Qt.Key_0)
      compare(field.text, "17:30")
      compare(rows.get(0).from, 1050)
      keyClick(Qt.Key_Backspace)
      keyClick(Qt.Key_Backspace)
      compare(field.text, "17")
      keyClick(Qt.Key_4)
      keyClick(Qt.Key_5)
      compare(field.text, "17:45")
      compare(rows.get(0).from, 1065)
      field.editingFinished()
    }

    // "17" then Tab: the automatic colon leaves "17:", which is 17:00.
    function test_hour_alone_then_blur() {
      var field = repeated.itemAt(0)
      rows.setProperty(0, "from", 660)
      field.focus = false
      wait(0)
      field.forceActiveFocus()
      keyClick(Qt.Key_1)
      keyClick(Qt.Key_7)
      compare(field.text, "17:")
      var typed = rows.get(0).from
      field.focus = false
      wait(0)
      var after = field.text
      rows.setProperty(0, "from", 660)   // the box is blank here; the next tests need a time in it
      verify(typed === 1020 && after === "17:00", "from=" + typed + " text after blur=" + after)
    }

    // Enter formats the time while focused; the caret goes to its end.
    function test_enter_then_backspace() {
      var field = repeated.itemAt(0)
      rows.setProperty(0, "from", 660)
      field.focus = false
      wait(0)
      field.forceActiveFocus()
      keyClick(Qt.Key_9)
      keyClick(Qt.Key_Return)
      compare(field.text, "09:00")
      compare(field.cursorPosition, 5)
      keyClick(Qt.Key_Backspace)
      compare(field.text, "09:0")
      field.focus = false
      wait(0)
    }

    function test_follows_the_model_when_not_edited() {
      var field = repeated.itemAt(0)
      field.focus = false
      rows.setProperty(0, "from", 545)
      compare(field.text, "09:05")
    }
  }
}
