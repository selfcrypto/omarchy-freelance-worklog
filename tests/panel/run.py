"""Panel forms across a close: the real Panel.qml under qs, offscreen, with a
fake shared service fed views from the real helper on scratch data.
python3 tests/panel/run.py

Checks:
- a new-session form is still there after a close, the keyboard back in the field it was in
- a review whose session moved on while closed (another panel resumed and
  ended it) opens fresh with the session's real times and sends its reviewBase
- a session edit kept across a close sends the base it loaded, so the helper
  refuses it once the session changed elsewhere (tests/test_worklog.py)
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
SHELL = pathlib.Path("/usr/share/omarchy/shell")

# Offscreen has no layer-shell backend: the stock panel's open and focus
# lifecycle in a FloatingWindow. Compositor focus is not tested here.
KEYBOARD_PANEL = """import QtQuick
import Quickshell
FloatingWindow {
  id: root
  property Item anchorItem
  property QtObject bar
  property var owner
  property bool open: false
  property bool focusPrimed: false
  property Item focusTarget
  property int contentWidth: 400
  property int contentHeight: 700
  implicitWidth: contentWidth
  implicitHeight: contentHeight
  visible: open
  function fittedContentWidth(w) { return w }
  function fittedContentHeight(h, cap) { return Math.min(h, cap) }
  function beginFocusPrime() {}
  onOpenChanged: if (open && focusTarget) Qt.callLater(function() {
    if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
  })
}
"""

SHELL_QML = """import QtQuick
import Quickshell
ShellRoot {
  id: test
  property var views: __VIEWS__
  QtObject {
    id: svc
    property bool ready: true
    property var view: test.views.start
    property string sessionState: view.state
    property double nowMs: Date.parse("2026-11-25T12:00:00Z")
    property var week: view.week
    property var month: view.month
    property string currency: "€"
    property string currentCompany: view.currentCompany
    property bool severalCompanies: false
    property var prompt: null
    property string requestedPage: ""
    property bool autoPaused: false
    property bool showElapsed: true
    property real sessionSec: 0
    property real pauseSec: 0
    property real todaySec: 0
    property string pauseReason: ""
    function announce() {}
    function saveDraft() {}
    function serviceFor(id) { return svc }
    function confirm(summary, tags, segments, done, company, billIn, base) {
      console.log("PROBE confirm rows", segments.length, "base", base === test.views.ended.active.reviewBase ? "current" : "other")
    }
    function updateSession(id, segments, summary, tags, done, company, billIn, base) {
      console.log("PROBE update base", base === test.views.saved.recent[0].base ? "loaded" : "other")
    }
  }
  QtObject {
    id: fakeBar
    property var shell: svc
    property color urgent: "red"
    property color barForeground: "white"
    property string fontFamily: "monospace"
    property bool vertical: false
    property int barSize: 30
    property string position: "top"
    property var activePopout: null
    function requestPopout(p) { activePopout = p }
    function releasePopout(p) { activePopout = null }
    function hideTooltip(p) {}
    function showTooltip() {}
  }
  FloatingWindow {
    implicitWidth: 500; implicitHeight: 800; visible: true
    WorklogPanel { id: panel; bar: fakeBar; manageIpc: false }
  }
  property int step: 0
  Timer {
    interval: 300; running: true; repeat: true
    onTriggered: {
      step++
      if (step === 1) { panel.open(); panel.newEntry("2026-11-24") }
      if (step === 2) { panel.probeEditor.setRow(0, "from", 500); panel.probeEditor.probeTags.forceActiveFocus(); panel.close() }
      if (step === 3) { panel.open() }
      if (step === 4) {
        console.log("PROBE new", panel.page, panel.editorMode, "from", panel.probeEditor.rowsArray()[0].from,
          "focus", panel.focusNow === panel.probeEditor.probeTags)
        panel.close(); svc.view = test.views.stopped; svc.requestedPage = "review"; panel.open()
      }
      if (step === 5) { panel.close(); svc.view = test.views.ended }
      if (step === 6) { panel.open() }
      if (step === 7) {
        console.log("PROBE review", panel.page, "rows", panel.probeEditor.rowsArray().length)
        panel.submitEditor(panel.probeEditor.check.segments, "Review", "", false)
      }
      if (step === 8) { panel.close(); svc.view = test.views.saved; panel.open(); panel.editSession(svc.view.recent[0]) }
      if (step === 9) { panel.close(); svc.view = test.views.corrected }
      if (step === 10) { panel.open() }
      if (step === 11) {
        console.log("PROBE edit", panel.page, panel.editorMode, "summary", panel.probeEditor.summaryText)
        panel.submitEditor(panel.probeEditor.check.segments, panel.probeEditor.summaryText, "", false)
        Qt.quit()
      }
    }
  }
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="worklog-panel-", dir=os.environ.get("TMPDIR")) as tmp:
        p = pathlib.Path(tmp)
        (p / "runtime").mkdir(mode=0o700)
        env = dict(os.environ, WORKLOG_DATA_DIR=str(p / "data"), WORKLOG_TZ="Europe/Madrid",
                   QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=str(p / "runtime"))

        def helper(at, *args):
            env["WORKLOG_NOW"] = "2026-11-25T" + at + ":00Z"
            out = subprocess.run([sys.executable, "-I", str(REPO / "worklog.py"), "--stdin"],
                                 input=json.dumps(list(args)), env=env, capture_output=True, text=True, check=True)
            r = json.loads(out.stdout)
            assert r["ok"], r
            return r["view"]

        views = {"start": helper("08:00", "view")}
        helper("09:00", "start")
        views["stopped"] = helper("10:00", "stop")
        # Elsewhere, while this panel is closed: back to work and ended again.
        helper("10:01", "back")
        helper("11:00", "resume")
        views["ended"] = helper("12:00", "stop")
        views["saved"] = helper("12:01", "confirm", "--summary", "Original")
        views["corrected"] = helper("12:02", "update", "--id", views["saved"]["recent"][0]["id"], "--summary", "Corrected elsewhere")

        for f in REPO.glob("*.qml"):
            shutil.copy(f, p / f.name)
        shutil.copy(REPO / "Model.js", p / "Model.js")
        (p / "Commons").symlink_to(SHELL / "Commons")
        (p / "Ui").mkdir()
        for f in (SHELL / "Ui").iterdir():
            if f.name != "KeyboardPanel.qml":
                (p / "Ui" / f.name).symlink_to(f)
        (p / "Ui" / "KeyboardPanel.qml").write_text(KEYBOARD_PANEL)
        panel = (p / "Panel.qml").read_text().replace(
            "  id: root\n", "  id: root\n  property alias probeEditor: editor\n  property alias probeCatcher: keyCatcher\n", 1)
        (p / "WorklogPanel.qml").write_text(panel)
        (p / "Panel.qml").unlink()
        editor = (p / "SessionEditor.qml").read_text()
        i = editor.index("  property string mode:")
        (p / "SessionEditor.qml").write_text(editor[:i] + "  property alias probeTags: tagsField\n" + editor[i:])
        (p / "shell.qml").write_text(SHELL_QML.replace("__VIEWS__", json.dumps(views)))

        r = subprocess.run(["timeout", "15", "qs", "-p", str(p), "--no-color"], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        probe = [line.split("PROBE ", 1)[1] for line in r.stdout.splitlines() if "PROBE " in line]
        want = [
            "new editor new from 500 focus true",
            "review review rows 2",
            "confirm rows 2 base current",
            "edit editor edit summary Original",
            "update base loaded",
        ]
        if probe != want or r.returncode != 0:
            print(r.stdout)
            print("got ", probe)
            print("want", want)
            raise SystemExit(1)
        print("panel: %d checks passed" % len(want))


main()
