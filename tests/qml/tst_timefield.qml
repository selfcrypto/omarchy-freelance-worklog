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

    function test_follows_the_model_when_not_edited() {
      var field = repeated.itemAt(0)
      field.focus = false
      rows.setProperty(0, "from", 545)
      compare(field.text, "09:05")
    }
  }
}
