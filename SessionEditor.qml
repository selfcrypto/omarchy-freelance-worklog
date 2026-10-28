import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The session form: what was done, tags, the work segments and their totals,
// then the buttons. Three uses:
//   review  the end-of-session page (Confirm, Back to work, Discard)
//   edit    a confirmed session from the history (Save, Cancel, Delete)
//   new     time that was not tracked (Add, Cancel); the last segment can run
//           on until now ("now"), which starts a timer with the earlier
//           segments already in it
//
// Rows live in a ListModel so typing in a time field never rebuilds the row
// under the cursor; `revision` ticks on every edit and drives the live check
// (Model.checkRows, the same rules worklog.py applies on save).
Item {
  id: editor

  property string mode: "review"
  property color foreground: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property var suggestions: []
  property double nowMs: Date.now()
  property bool busy: false
  property string error: ""
  property string errorField: ""
  // Day the rows of a new entry fall on; the ‹ › buttons move it.
  property string dateKey: Model.localDateKey(Date.now())
  // Companies ({ id, name, tag, archived }) and the one this session belongs
  // to. The chips show with two or more active companies, or when the
  // session's own company is archived.
  property var companies: []
  property string company: ""
  readonly property var companyChoices: companies.filter(function(c) { return !c.archived || c.id === editor.company })
  readonly property bool showCompanies: companies.filter(function(c) { return !c.archived }).length > 1
    || companies.some(function(c) { return c.archived && c.id === editor.company })

  readonly property color dim: Util.alpha(foreground, 0.72)
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  // Only with no session live: the running segment becomes the timer.
  property bool canRunOn: true
  readonly property bool allowOpen: mode === "new" && canRunOn

  property int revision: 0
  readonly property var check: { revision; nowMs; return Model.checkRows(rowsArray(), nowMs, allowOpen) }
  readonly property bool runsOn: { revision; return rowModel.count > 0 && rowModel.get(rowModel.count - 1).open === true }
  readonly property string summaryText: summaryEdit.text
  readonly property string tagsText: tagsField.text

  signal submitted(var segments, string summary, string tags, bool running)
  signal cancelled()
  signal destroyRequested()
  signal draftEdited(string summary, string tags)
  signal escapePressed()

  ListModel { id: rowModel }

  function rowsArray() {
    var out = []
    for (var i = 0; i < rowModel.count; i++) {
      var r = rowModel.get(i)
      out.push({ date: r.date, from: r.from, to: r.to, open: r.open, endReason: r.endReason, startIso: r.startIso, endIso: r.endIso })
    }
    return out
  }

  function load(rows, summary, tags, companyId) {
    if (companyId !== undefined) company = companyId
    rowModel.clear()
    for (var i = 0; i < rows.length; i++)
      rowModel.append({ date: rows[i].date, from: rows[i].from, to: rows[i].to, open: !!rows[i].open, endReason: rows[i].endReason || "",
        startIso: rows[i].startIso || "", endIso: rows[i].endIso || "" })
    if (rows.length) dateKey = rows[0].date
    summaryEdit.text = summary || ""
    tagsField.text = (tags || []).join(", ")
    error = ""
    errorField = ""
    revision++
  }

  // A new entry: today one segment ending now, an hour long; another day
  // 09:00 to 10:00 on that day.
  function loadNew(day, companyId) {
    var now = new Date()
    var today = Model.localDateKey(now.getTime())
    var key = day || today
    if (key >= today) {
      var to = now.getHours() * 60 + now.getMinutes()
      load([{ date: today, from: Math.max(0, to - 60), to: to, open: false }], "", [], companyId)
    } else {
      load([{ date: key, from: 540, to: 600, open: false }], "", [], companyId)
    }
  }

  // Delayed: the panel's own focus prime lands on its key catcher first.
  function focusSummary() { focusTimer.restart() }
  Timer {
    id: focusTimer
    interval: 120
    onTriggered: summaryEdit.forceActiveFocus()
  }

  function setRow(i, key, value) {
    rowModel.setProperty(i, key, value)
    if (key !== "open") rowModel.setProperty(i, "endReason", "edited")
    revision++
  }

  function addRow() {
    var last = rowModel.count ? rowModel.get(rowModel.count - 1) : null
    var start = last ? (last.open ? Math.min(1439, minutesNow()) : last.to) : Math.max(0, minutesNow() - 60)
    if (last && last.open) {
      rowModel.setProperty(rowModel.count - 1, "open", false)
      rowModel.setProperty(rowModel.count - 1, "to", start)
    }
    rowModel.append({ date: last ? last.date : dateKey, from: start, to: Math.min(1439, minutesNow()), open: false, endReason: "edited", startIso: "", endIso: "" })
    revision++
  }

  function removeRow(i) {
    if (rowModel.count <= 1) return
    rowModel.remove(i)
    revision++
  }

  function shiftDate(days) {
    dateKey = Model.addDays(dateKey, days)
    for (var i = 0; i < rowModel.count; i++) rowModel.setProperty(i, "date", dateKey)
    revision++
  }

  function minutesNow() {
    var d = new Date(nowMs)
    return d.getHours() * 60 + d.getMinutes()
  }


  function submit() {
    if (busy) return
    if (check.error) { error = check.error; errorField = "segments"; return }
    // A session that runs on gets its summary at the review.
    if (summaryEdit.text.trim() === "" && !runsOn) { error = "Write what you did"; errorField = "summary"; summaryEdit.forceActiveFocus(); return }
    error = ""
    submitted(check.segments, summaryEdit.text.trim(), tagsField.text, runsOn)
  }

  function addTag(tag) {
    var tags = Model.parseTags(tagsField.text)
    if (tags.indexOf(tag) === -1) tags.push(tag)
    tagsField.text = tags.join(", ")
    draftEdited(summaryEdit.text, tagsField.text)
  }

  // Shared key handling for every field: Ctrl+Enter submits, Esc leaves the
  // form, Tab walks the fields (plain Tab would otherwise reach the panel).
  function fieldKey(item, event) {
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
      submit()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      escapePressed()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var next = item.nextItemInFocusChain((event.modifiers & Qt.ShiftModifier) === 0 && event.key === Qt.Key_Tab)
      if (next) next.forceActiveFocus()
      event.accepted = true
    }
  }

  implicitHeight: layout.implicitHeight

  component Caption: Text {
    textFormat: Text.PlainText
    color: editor.dim
    font.family: editor.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool on: false
    property bool warn: false
    property bool clickable: false
    signal clicked()
    implicitWidth: chipText.implicitWidth + Style.space(10)
    implicitHeight: chipText.implicitHeight + Style.space(4)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: on ? Style.selectedAccentFill : "transparent"
    border.width: 1
    border.color: warn ? editor.urgent : (on ? editor.accent : Util.alpha(editor.foreground, 0.28))

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      textFormat: Text.PlainText
      color: chip.warn ? editor.urgent : (chip.on ? editor.accent : (chipMouse.containsMouse ? editor.foreground : editor.dim))
      font.family: editor.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      enabled: chip.clickable
      hoverEnabled: true
      cursorShape: chip.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: chip.clicked()
    }
  }

  Column {
    id: layout
    width: parent.width
    spacing: Style.space(12)

    Rectangle {
      width: parent.width
      height: form.implicitHeight + Style.space(24)
      radius: Style.cornerRadius
      color: Style.normalFillFor(editor.foreground, editor.accent)

      Column {
        id: form
        x: Style.space(12)
        y: Style.space(12)
        width: parent.width - Style.space(24)
        spacing: Style.space(6)

        Caption { text: "What did you do?" }

        // Multi-line summary: a KeyField (no editable Qt text control).
        KeyField {
          id: summaryEdit
          width: parent.width
          multiline: true
          minHeight: Style.space(72)
          maxHeight: Style.space(160)
          maximumLength: 2000
          radius: Style.cornerRadius
          foreground: editor.foreground
          accent: editor.accent
          urgent: editor.urgent
          invalid: editor.errorField === "summary"
          font.family: editor.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Ctrl+Enter saves"
          onTextEdited: {
            if (editor.errorField === "summary") {
              editor.error = ""
              editor.errorField = ""
            }
            draftTimer.restart()
          }
          onUnhandledKey: function(event) { editor.fieldKey(summaryEdit, event) }
        }

        Item { width: 1; height: Style.space(2); visible: editor.showCompanies }
        Caption { text: "Company"; visible: editor.showCompanies }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: editor.showCompanies

          Repeater {
            model: editor.companyChoices
            delegate: Chip {
              required property var modelData
              label: modelData.name
              on: modelData.id === editor.company
              opacity: modelData.archived ? 0.6 : 1
              clickable: true
              onClicked: editor.company = modelData.id
            }
          }
        }

        Item { width: 1; height: Style.space(2) }
        Caption { text: "Tags" }

        KeyField {
          id: tagsField
          width: parent.width
          radius: Style.cornerRadius
          foreground: editor.foreground
          accent: editor.accent
          font.family: editor.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: "comma separated"
          maximumLength: 340
          onTextEdited: draftTimer.restart()
          onUnhandledKey: function(event) { editor.fieldKey(tagsField, event) }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: suggestionRepeater.count > 0

          Repeater {
            id: suggestionRepeater
            model: {
              var have = Model.parseTags(tagsField.text)
              return editor.suggestions.filter(function(t) { return have.indexOf(t) === -1 }).slice(0, 8)
            }
            delegate: Chip {
              required property string modelData
              label: "+ " + modelData
              clickable: true
              onClicked: editor.addTag(modelData)
            }
          }
        }
      }
    }

    // Segments.
    Column {
      width: parent.width
      spacing: Style.space(6)

      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          Layout.fillWidth: true
          text: "Time"
          foreground: editor.foreground
          fontFamily: editor.fontFamily
        }

        // The day of a new entry.
        PanelActionButton {
          visible: editor.mode === "new"
          iconText: "󰅁"
          tooltipText: "Day before"
          foreground: editor.dim
          hoverColor: editor.foreground
          fontFamily: editor.fontFamily
          onClicked: editor.shiftDate(-1)
        }
        Text {
          visible: editor.mode === "new"
          text: editor.dateKey === Model.localDateKey(editor.nowMs) ? "Today, " + Model.dayLabel(editor.dateKey) : Model.dayLabel(editor.dateKey)
          textFormat: Text.PlainText
          color: editor.foreground
          font.family: editor.fontFamily
          font.pixelSize: Style.font.body
        }
        PanelActionButton {
          visible: editor.mode === "new"
          enabled: editor.dateKey < Model.localDateKey(editor.nowMs)
          opacity: enabled ? 1 : 0.35
          iconText: "󰅂"
          tooltipText: "Day after"
          foreground: editor.dim
          hoverColor: editor.foreground
          fontFamily: editor.fontFamily
          onClicked: editor.shiftDate(1)
        }
      }

      Rectangle {
        width: parent.width
        height: segmentRows.implicitHeight
        radius: Style.cornerRadius
        color: Style.normalFillFor(editor.foreground, editor.accent)

        Column {
          id: segmentRows
          width: parent.width

          Repeater {
            model: rowModel
            delegate: Rectangle {
              id: segRow
              required property int index
              required property string date
              required property int from
              required property int to
              required property bool open
              required property string endReason
              required property string startIso
              required property string endIso
              readonly property bool isLast: index === rowModel.count - 1
              readonly property bool flagged: editor.check.error !== "" && editor.check.row === index
              readonly property int seconds: {
                editor.revision
                var c = Model.checkRows([{ date: date, from: from, to: to, open: open, startIso: startIso, endIso: endIso }], editor.nowMs, true)
                return c.error ? 0 : c.workedSec
              }
              width: segmentRows.width
              height: Style.space(44)
              radius: Style.cornerRadius
              color: rowHover.hovered ? editor.hoverFill : "transparent"

              HoverHandler { id: rowHover }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(6)

                Rectangle {
                  Layout.preferredWidth: Style.space(30)
                  Layout.preferredHeight: Style.space(30)
                  radius: Style.cornerRadius
                  color: segRow.open ? Style.selectedAccentFill : Style.normalFillFor(editor.foreground, editor.accent)

                  Text {
                    anchors.centerIn: parent
                    text: segRow.flagged ? "󰀦" : (segRow.open ? "󰐊" : "󰔟")
                    color: segRow.flagged ? editor.urgent : (segRow.open ? editor.accent : editor.dim)
                    font.family: editor.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                }

                TimeField {
                  id: fromField
                  Layout.preferredWidth: Style.space(62)
                  foreground: editor.foreground
                  accent: editor.accent
                  font.family: editor.fontFamily
                  font.pixelSize: Style.font.body
                  minutes: segRow.from
                  onMinutesEdited: function(m) { editor.setRow(segRow.index, "from", m) }
                  radius: Style.cornerRadius
                  onUnhandledKey: function(event) { editor.fieldKey(fromField, event) }
                }

                Text {
                  text: "–"
                  color: editor.dim
                  font.family: editor.fontFamily
                  font.pixelSize: Style.font.body
                }

                TimeField {
                  id: toField
                  visible: !segRow.open
                  Layout.preferredWidth: Style.space(62)
                  foreground: editor.foreground
                  accent: editor.accent
                  font.family: editor.fontFamily
                  font.pixelSize: Style.font.body
                  minutes: segRow.to
                  onMinutesEdited: function(m) { editor.setRow(segRow.index, "to", m) }
                  radius: Style.cornerRadius
                  onUnhandledKey: function(event) { editor.fieldKey(toField, event) }
                }

                // A new entry's last segment can run on: "now".
                Chip {
                  visible: editor.allowOpen && segRow.isLast
                  label: "now"
                  on: segRow.open
                  clickable: true
                  onClicked: {
                    var opening = !segRow.open
                    editor.setRow(segRow.index, "open", opening)
                    if (!opening && segRow.to < 0) editor.setRow(segRow.index, "to", editor.minutesNow())
                  }

                  HoverHandler { id: nowHover }
                  PanelToolTip {
                    visible: nowHover.hovered
                    text: segRow.open ? "Still working: Add starts the timer from here" : "Still working on it: keep this segment running"
                    fontFamily: editor.fontFamily
                  }
                }

                Text {
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  horizontalAlignment: Text.AlignRight
                  text: segRow.seconds < 60 && !segRow.open ? "not counted" : Model.fmtDuration(segRow.seconds)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: editor.dim
                  font.family: editor.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Chip {
                  visible: segRow.endReason !== "" && segRow.endReason !== "edited" && segRow.endReason !== "stop" && !segRow.open
                  label: segRow.endReason
                }

                PanelActionButton {
                  visible: rowModel.count > 1
                  iconText: "󰆴"
                  tooltipText: "Remove this segment"
                  foreground: editor.dim
                  hoverColor: editor.urgent
                  fontFamily: editor.fontFamily
                  onClicked: editor.removeRow(segRow.index)
                }
              }
            }
          }

          // Add a segment.
          Rectangle {
            width: segmentRows.width
            height: Style.space(36)
            radius: Style.cornerRadius
            color: addMouse.containsMouse ? editor.hoverFill : "transparent"

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: editor.addRow()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(12)
              text: "+  Add segment"
              textFormat: Text.PlainText
              color: addMouse.containsMouse ? editor.foreground : editor.dim
              font.family: editor.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Totals, live.
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: editor.check.error ? "" : Model.fmtDuration(editor.check.workedSec) + " worked · "
          + Model.fmtDuration(editor.check.pausedSec) + " paused · "
          + Model.localHM(editor.check.first) + " – " + (editor.check.last ? Model.localHM(editor.check.last) : "now")
        textFormat: Text.PlainText
        color: editor.dim
        font.family: editor.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: editor.error !== "" ? editor.error : editor.check.error
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: editor.urgent
      font.family: editor.fontFamily
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Button {
        text: editor.mode === "review" ? "Confirm" : (editor.mode === "edit" ? "Save" : (editor.runsOn ? "Add and keep running" : "Add"))
        iconText: "󰄬"
        active: true
        bordered: true
        foreground: editor.foreground
        accent: editor.accent
        fontFamily: editor.fontFamily
        tooltipText: "Ctrl+Enter"
        onClicked: editor.submit()
      }

      Button {
        text: editor.mode === "review" ? "Back to work" : "Cancel"
        foreground: editor.foreground
        accent: editor.accent
        fontFamily: editor.fontFamily
        onClicked: editor.cancelled()
      }

      Item { Layout.fillWidth: true }

      Button {
        id: destroyButton
        visible: editor.mode !== "new"
        text: editor.mode === "review" ? "Discard" : "Delete"
        foreground: hot ? editor.urgent : editor.dim
        accent: editor.urgent
        fontFamily: editor.fontFamily
        onClicked: editor.destroyRequested()
      }
    }
  }

  // The review page keeps its draft in active.json, 1 s after the last edit.
  Timer {
    id: draftTimer
    interval: 1000
    onTriggered: if (editor.mode === "review") editor.draftEdited(summaryEdit.text, tagsField.text)
  }
}
