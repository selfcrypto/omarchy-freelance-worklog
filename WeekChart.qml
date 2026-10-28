import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// A column chart drawn with Rectangles: one bar per entry of `series`
// ({ label, readout, hours, state }), grown from one baseline, with an
// optional dashed target line. Used for the days of the week and for the
// last weeks. Colors are the theme's: the accent marks today, this week and
// weeks that met the target; other bars are the foreground at 0.45, so on/off
// never relies on hue and a monochrome theme still separates them.
//
// Hovering a column sets `readout` (the card header shows it); the whole
// column is the hit target, wider than the bar. With `clickable` a click
// emits columnClicked(index).
Item {
  id: chart

  property var series: []
  property real target: 0            // hours; 0 hides the line
  property string targetLabel: ""    // shown at the line's right end
  property bool targetSubtle: false  // a hint (day chart) rather than a goal
  property var markers: []           // column indexes: a dashed line at the left edge
  property bool thinning: true       // drop every other label when columns are narrow
  property bool clickable: false     // columns answer clicks (columnClicked)

  signal columnClicked(int index)
  property color foreground: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  property int hoverIndex: -1
  readonly property string readout: hoverIndex >= 0 && hoverIndex < series.length ? series[hoverIndex].readout : ""

  readonly property real maxHours: {
    var m = target
    for (var i = 0; i < series.length; i++) m = Math.max(m, series[i].hours)
    return m
  }
  readonly property real yMax: Model.niceHours(Math.max(maxHours * 1.08, 0.5))
  readonly property real labelStrip: Style.space(16)
  readonly property real plotHeight: height - labelStrip
  readonly property real columnWidth: series.length > 0 ? width / series.length : width
  // Bars stay thin (at most 24 px); the rest of the column is air, less of it
  // when a month puts 31 columns in the card.
  readonly property real barWidth: Math.max(Style.space(4), Math.min(Style.space(24), columnWidth - Math.min(Style.space(8), columnWidth * 0.35)))
  readonly property bool thinLabels: thinning && columnWidth < Style.space(26)

  implicitHeight: Style.space(96)

  function barColor(state, hovered) {
    if (state === "current" || state === "met" || state === "partial") return chart.accent
    return Util.alpha(chart.foreground, hovered ? 0.62 : 0.45)
  }

  // Column backgrounds (hover) and bars.
  Row {
    id: columns
    width: parent.width
    height: chart.plotHeight

    Repeater {
      model: chart.series
      delegate: Item {
        id: column
        required property var modelData
        required property int index
        readonly property bool hovered: chart.hoverIndex === index
        width: chart.columnWidth
        height: columns.height

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: 1
          anchors.rightMargin: 1
          radius: Math.min(Style.cornerRadius, Style.space(4))
          color: column.hovered ? Util.alpha(chart.foreground, 0.06) : "transparent"
        }

        // Rounded data end, square at the baseline: a rounded bar with a
        // square patch over its lower corners.
        Item {
          id: bar
          readonly property real r: Math.min(Style.space(4), width / 2)
          width: chart.barWidth
          height: Model.barHeight(column.modelData.hours, chart.yMax, chart.plotHeight)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          visible: height > 0
          opacity: column.modelData.state === "partial" && !column.hovered ? 0.55 : 1

          Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

          Rectangle {
            anchors.fill: parent
            radius: bar.r
            color: chart.barColor(column.modelData.state, column.hovered)
          }
          Rectangle {
            visible: bar.height > bar.r
            width: parent.width
            height: Math.min(bar.r, bar.height / 2)
            anchors.bottom: parent.bottom
            color: chart.barColor(column.modelData.state, column.hovered)
          }
        }

        // Future days: a stub on the baseline, so the week reads as 7 slots.
        Rectangle {
          visible: column.modelData.state === "future"
          width: chart.barWidth
          height: Style.space(2)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          color: Util.alpha(chart.foreground, 0.16)
        }

        MouseArea {
          anchors.fill: parent
          anchors.bottomMargin: -chart.labelStrip
          hoverEnabled: true
          cursorShape: chart.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (chart.clickable) chart.columnClicked(column.index)
          onEntered: chart.hoverIndex = column.index
          onExited: if (chart.hoverIndex === column.index) chart.hoverIndex = -1
        }
      }
    }
  }

  // Markers: where something changes (new contract terms on the month page).
  Repeater {
    model: chart.markers
    delegate: Column {
      required property int modelData
      x: Math.round(modelData * chart.columnWidth)
      width: 1
      height: chart.plotHeight
      spacing: Style.space(2)
      clip: true

      Repeater {
        model: Math.max(0, Math.ceil(chart.plotHeight / Style.space(5)))
        delegate: Rectangle { width: 1; height: Style.space(3); color: Util.alpha(chart.accent, 0.7) }
      }
    }
  }

  // Baseline.
  Rectangle {
    width: parent.width
    height: 1
    y: chart.plotHeight
    color: Util.alpha(chart.foreground, 0.16)
  }

  // Dashed target line.
  Item {
    id: targetLine
    visible: chart.target > 0 && chart.target <= chart.yMax
    width: parent.width
    height: 1
    y: Math.round(chart.plotHeight * (1 - chart.target / chart.yMax))

    Row {
      id: dashes
      width: Math.max(0, parent.width - (targetText.visible ? targetText.implicitWidth + Style.space(6) : 0))
      spacing: Style.space(3)
      clip: true

      Repeater {
        model: Math.max(0, Math.ceil(dashes.width / Style.space(7)))
        delegate: Rectangle {
          width: Style.space(4)
          height: 1
          color: chart.targetSubtle ? Util.alpha(chart.foreground, 0.28) : Util.alpha(chart.accent, 0.75)
        }
      }
    }

    Text {
      id: targetText
      visible: chart.targetLabel !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: chart.targetLabel
      textFormat: Text.PlainText
      color: Util.alpha(chart.foreground, 0.72)
      font.family: chart.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Labels under the baseline.
  Row {
    y: chart.plotHeight + Style.space(3)
    width: parent.width

    Repeater {
      model: chart.series
      delegate: Text {
        required property var modelData
        required property int index
        width: chart.columnWidth
        horizontalAlignment: Text.AlignHCenter
        text: chart.thinLabels && index % 2 === 1 && index !== chart.series.length - 1 ? "" : modelData.label
        textFormat: Text.PlainText
        color: modelData.state === "current" || modelData.state === "partial" || chart.hoverIndex === index
          ? chart.foreground : Util.alpha(chart.foreground, 0.72)
        font.family: chart.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: modelData.state === "current" || modelData.state === "partial"
      }
    }
  }
}
