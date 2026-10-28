import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// Worklog service: the one owner of the session state. The shell loads it
// once (keepLoaded); every bar widget reads `view` from here and calls the
// functions below, so the copies on each monitor never disagree.
//
// All data lives in files written only by worklog.py (fixed argv, one call at
// a time, each under `timeout`). Every call returns the full view, assigned
// to `view` in one go; the running clock is derived here from the open
// segment's start, so nothing is written per second. A heartbeat every 20 s
// while running lets the next start tell a shell restart (keep running) from
// a shutdown or crash (pause at the last heartbeat).
//
// Automatic pauses: a locked screen (polled through Hyprland, the probe
// omarchy-hyprland-session-locked uses), idle without lock (IdleMonitor,
// back-dated so the idle minutes do not count), suspend (a jump in the 1 s
// tick). Nothing resumes on its own: on return the panel opens with the time
// away and asks what to do with it (`prompt`).
//
// NOTE: after editing this file run `omarchy restart shell`; a keepLoaded
// service is not replaced by the hot reload.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property string pluginId: "io.github.selfcrypto.worklog"
  readonly property string home: Quickshell.env("HOME")
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("worklog.py")).replace(/^file:\/\//, ""))

  // ------------------------------------------------------------ settings

  property var fileConfig: null
  readonly property var entrySettings: {
    var layout = fileConfig && fileConfig.bar && fileConfig.bar.layout ? fileConfig.bar.layout : null
    if (!layout) return {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === pluginId) return entries[i]
      }
    }
    return {}
  }
  function setting(key, fallback) {
    var v = entrySettings[key]
    return v === undefined || v === null || v === "" ? fallback : v
  }
  function numberSetting(key, fallback, min, max) {
    var n = Number(setting(key, fallback))
    return isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback
  }
  function boolSetting(key, fallback) {
    var v = setting(key, fallback)
    return v === true || v === "true" ? true : (v === false || v === "false" ? false : fallback)
  }

  // Terms live in the data file (companies and their periods); the six v1
  // keys, when still in shell.json, only seed the first company.
  readonly property var legacy: {
    var out = {}
    var keys = ["weeklyTargetHours", "monthlyHours", "monthlyFee", "vatPercent", "standardRate", "currency"]
    for (var i = 0; i < keys.length; i++) {
      var v = entrySettings[keys[i]]
      if (v !== undefined && v !== null && v !== "") out[keys[i]] = v
    }
    return out
  }
  readonly property string currency: view && view.month ? view.month.currency : "€"
  readonly property bool pauseOnLock: boolSetting("pauseOnLock", true)
  readonly property int idlePauseMinutes: numberSetting("idlePauseMinutes", 15, 0, 120)
  readonly property real reminderHours: numberSetting("reminderHours", 4, 0, 12)
  readonly property bool showElapsed: boolSetting("showElapsed", true)
  readonly property string exportDir: String(setting("exportDir", "~/Documents/Worklog")).replace(/^~(?=\/|$)/, home)
  readonly property string reportLanguage: setting("reportLanguage", "en") === "es" ? "es" : "en"
  readonly property int reportRoundingMinutes: Number(setting("reportRoundingMinutes", 0)) === 15 ? 15 : 0
  readonly property bool reportShowDiscount: boolSetting("reportShowDiscount", true)
  readonly property bool reportHtml: boolSetting("reportHtml", true)

  readonly property string configJson: JSON.stringify({
    reportLanguage: reportLanguage, reportRoundingMinutes: reportRoundingMinutes,
    reportShowDiscount: reportShowDiscount, reportHtml: reportHtml, legacy: legacy
  })
  onConfigJsonChanged: if (ready) refresh()


  // ------------------------------------------------------------ state

  property var view: null
  readonly property bool ready: view !== null
  readonly property string sessionState: view ? view.state : "idle"
  readonly property string pauseReason: view ? view.pauseReason : ""
  readonly property bool announced: view ? view.announced : true
  property double nowMs: Date.now()
  property double lastTickMs: Date.now()
  property string bootId: ""
  property string lastError: ""
  property string lastErrorField: ""
  property bool locked: false
  // Set when the user is back from an automatic pause: { reason, awaySec, since }.
  property var prompt: null
  property double lastReminderMs: 0
  property double lastReviewToastMs: 0

  readonly property int sessionSec: view ? Model.sessionWorkedSec(view, nowMs) : 0
  readonly property int pauseSec: view ? Model.currentPauseSec(view, nowMs) : 0
  readonly property int todaySec: view ? view.today.workedSec + Model.openSec(view, nowMs, view.today.startAt) : 0
  readonly property var week: view ? Model.weekLive(view, nowMs) : null
  readonly property var month: view ? Model.monthLive(view, nowMs) : null

  // Companies: the one the track page shows and the next start uses.
  readonly property string currentCompany: view ? view.currentCompany : ""
  readonly property var currentCompanyInfo: view ? Model.companyOf(view, view.currentCompany) : null
  readonly property var activeCompanies: view ? Model.activeCompanies(view) : []
  readonly property bool severalCompanies: activeCompanies.length > 1
  readonly property var liveCompanyInfo: view && view.active ? Model.companyOf(view, view.active.company) : null

  // The page a summoned panel opens on (read once by the panel on open).
  property string requestedPage: ""

  // Opens the panel on the focused monitor through the shell's own summon.
  function openRequested(page) {
    requestedPage = page
    Quickshell.execDetached(["timeout", "-k", "2", "5", "omarchy-shell", "shell", "summon", pluginId])
  }
  // A helper error the panel shows next to the field it names.
  signal refused(string error, string field)

  // ------------------------------------------------------------ helper

  property var queue: []
  property var pending: null

  function run(args, done) {
    queue = queue.concat([{ args: args, done: done || null }])
    pump()
  }

  function pump() {
    if (pending || queue.length === 0) return
    pending = queue[0]
    queue = queue.slice(1)
    helperProc.command = ["timeout", "-k", "3", "15", "python3", "-I", helper].concat(pending.args).concat(["--config", configJson])
    helperProc.running = true
  }

  function handle(text) {
    var job = pending
    pending = null
    var result = null
    try { result = JSON.parse(String(text).trim().split("\n").pop()) } catch (e) { result = { ok: false, error: "helper failed", field: "" } }
    if (result.ok && result.view) view = result.view
    if (result.ok) {
      lastError = ""
      lastErrorField = ""
    } else if (String(result.error).indexOf("no-op") !== 0) {
      lastError = String(result.error || "helper failed").slice(0, 200)
      lastErrorField = String(result.field || "")
      refused(lastError, lastErrorField)
    }
    if (result.ok && result.view && result.view.migrated)
      notify("Worklog: data upgraded", "Your sessions now belong to " + Model.companyName(result.view, result.view.migrated.company)
        + ". Set the company's name, billing cycle and terms in the panel (C).")
    if (result.ok && result.view && result.view.recovered)
      notify("Worklog data recovered", "An unreadable " + result.view.recovered.file + " was moved aside as " + result.view.recovered.movedTo)
    try {
      if (job && job.done) job.done(result)
    } finally {
      pump()
    }
  }

  Process {
    id: helperProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handle(text)
    }
  }

  function refresh() { run(["view"]) }

  function notify(title, body) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", "󰔟", Model.clip(title, 80), Model.clip(body, 300)])
  }

  function isoAt(ms) { return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z") }

  // ------------------------------------------------------------ actions

  function start(note) {
    if (sessionState === "ending") { openRequested("review"); return "no-op: ending" }
    if (sessionState === "paused") return resume()
    if (sessionState !== "idle") return "no-op: " + sessionState
    run(["start", "--boot-id", bootId].concat(note ? ["--note", String(note).slice(0, 2000)] : []))
    return "ok"
  }

  // Manual entry that runs on: earlier segments plus an open last one.
  function startWithSegments(segments, company, done) {
    run(["start", "--boot-id", bootId, "--segments", JSON.stringify(segments)].concat(company ? ["--company", company] : []), done)
  }

  // Start for a company named by id, name or tag; it becomes current.
  function startFor(company) {
    if (sessionState !== "idle") return "no-op: " + sessionState
    run(["start", "--boot-id", bootId, "--company", String(company)])
    return "ok"
  }

  // The current company; with a live session, the session moves to it too.
  function useCompany(company, done) {
    if (view && view.active && sessionState !== "idle") run(["edit-active", "--company", String(company)], done)
    else run(["company", "--action", "use", "--id", String(company)], done)
  }

  // action: add (args name, tag, cycleDay), rename (id, name, tag, cycleDay),
  // use, archive, unarchive, delete (id).
  function company(action, args, done) {
    var a = ["company", "--action", action]
    if (args.id) a = a.concat(["--id", String(args.id)])
    if (args.name !== undefined) a = a.concat(["--name", String(args.name)])
    if (args.tag !== undefined) a = a.concat(["--tag", String(args.tag)])
    if (args.cycleDay !== undefined) a = a.concat(["--cycle-day", String(args.cycleDay)])
    run(a, done)
  }

  // action: set (id, from, terms, replace), delete (id, from).
  function contract(action, args, done) {
    var a = ["contract", "--action", action, "--id", String(args.id), "--from", String(args.from)]
    if (args.terms) a = a.concat(["--terms", JSON.stringify(args.terms)])
    if (args.replace && args.replace !== args.from) a = a.concat(["--replace", String(args.replace)])
    run(a, done)
  }

  // Hours over the package in one cycle: action "waive" or "bill".
  function overage(action, company, key, done) { run(["overage", "--action", action, "--id", String(company), "--month", String(key)], done) }

  // The month page: key YYYY-MM or "this", company id or "all".
  function monthData(key, company, done) { run(["month", "--month", key || "this", "--company", company || "all"], done) }

  function pause(reason, atMs) {
    if (sessionState !== "running") return "no-op: " + sessionState
    var args = ["pause", "--reason", reason || "manual"]
    if (atMs) args = args.concat(["--at", isoAt(atMs)])
    run(args)
    return "ok"
  }

  function resume() {
    prompt = null
    if (sessionState === "ending") { run(["back"]); return "ok" }
    if (sessionState !== "paused") return "no-op: " + sessionState
    run(["resume"])
    return "ok"
  }

  // The away time counts as work: the paused segment runs on.
  function unpause() {
    prompt = null
    if (sessionState !== "paused") return "no-op: " + sessionState
    run(["unpause"])
    return "ok"
  }

  function keepPaused() {
    prompt = null
    run(["announce"])
  }

  function toggle() {
    if (sessionState === "idle") return start("")
    if (sessionState === "running") return pause("manual", 0)
    if (sessionState === "paused") return resume()
    openRequested("review")
    return "no-op: ending"
  }

  function stop() {
    prompt = null
    if (sessionState === "ending") { openRequested("review"); return "no-op: ending" }
    if (sessionState !== "running" && sessionState !== "paused") return "no-op: " + sessionState
    run(["stop"], function(r) { if (r.ok) root.openRequested("review") })
    return "ok"
  }

  function back() { if (sessionState === "ending") run(["back"]) }

  function saveDraft(summary, tags) {
    if (sessionState === "idle") return
    run(["draft", "--summary", String(summary || "").slice(0, 2000), "--tags", String(tags || "")])
  }

  // null summary or tags: the helper uses the saved draft (IPC confirm).
  function confirm(summary, tags, segments, done, company) {
    var args = ["confirm"]
    if (company) args = args.concat(["--company", String(company)])
    if (summary !== null && summary !== undefined) args = args.concat(["--summary", String(summary)])
    if (tags !== null && tags !== undefined) args = args.concat(["--tags", String(tags)])
    if (segments) args = args.concat(["--segments", JSON.stringify(segments)])
    run(args, done)
  }

  function discard(done) {
    prompt = null
    run(["discard"], done)
  }

  function addSession(segments, summary, tags, done, company) {
    run(["add", "--segments", JSON.stringify(segments), "--summary", String(summary || ""), "--tags", String(tags || "")]
      .concat(company ? ["--company", String(company)] : []), done)
  }

  function updateSession(id, segments, summary, tags, done, company) {
    run(["update", "--id", String(id), "--segments", JSON.stringify(segments), "--summary", String(summary || ""), "--tags", String(tags || "")]
      .concat(company ? ["--company", String(company)] : []), done)
  }

  function deleteSession(id, done) { run(["delete", "--id", String(id)], done) }

  // kind "week" with a key YYYY-Www or "this".
  function sessions(kind, key, done) { run(["sessions", "--" + kind, key || "this"], done) }

  // kind "week" or "month"; key "this", YYYY-Www or YYYY-MM; company an id,
  // "all", or empty for the default (week: all, month: the current company).
  function exportPeriod(kind, key, company, done) {
    var args = ["export", "--" + kind, key || "this", "--out", exportDir].concat(company ? ["--company", String(company)] : [])
    run(args, function(r) {
      if (r.ok) {
        var files = r.export.reports ? r.export.reports : [r.export]
        var names = files.map(function(f) { return f.markdown.replace(root.home, "~") })
        root.notify("Worklog exported", r.export.sessions + " sessions → " + (names.length ? names.join(", ") : "nothing to export"))
      } else root.notify("Worklog export failed", r.error)
      if (done) done(r)
    })
  }

  function announce() { if (!announced) run(["announce"]) }

  // ------------------------------------------------------------ automatic pauses

  readonly property bool autoPaused: sessionState === "paused" && !announced
    && (pauseReason === "lock" || pauseReason === "idle" || pauseReason === "suspend" || pauseReason === "restart")

  // Back at the machine after an automatic pause: ask, once.
  function checkReturn() {
    if (!autoPaused || prompt !== null || locked) return
    if (idleMonitor && idleMonitor.isIdle) return
    prompt = { reason: pauseReason, awaySec: pauseSec, since: view.active.lastEnd }
    openRequested("away")
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      var now = Date.now()
      // A tick that comes far too late means the machine was asleep.
      if (now - root.lastTickMs > 90000 && root.sessionState === "running")
        root.pause("suspend", root.lastTickMs)
      root.lastTickMs = now
      root.nowMs = now
      // Day, week and month totals come from the helper: re-read them when
      // the local date changes, whatever the session state.
      var day = Model.localDateKey(now)
      if (root.view && day !== root.view.today.date && !root.pending && root.queue.length === 0) root.refresh()
      if (root.prompt) root.prompt = Object.assign({}, root.prompt, { awaySec: root.pauseSec })
      root.remind(now)
    }
  }

  function remind(now) {
    if (sessionState === "running" && reminderHours > 0 && view.active.openStart) {
      var open = (now - Date.parse(view.active.openStart)) / 1000
      if (open >= reminderHours * 3600 && now - lastReminderMs >= 3600000) {
        lastReminderMs = now
        notify("Worklog: still working?", "Running " + Model.fmtDuration(sessionSec) + " since " + Model.localHM(view.active.since))
      }
    }
    if (sessionState === "ending" && view.active.lastEnd && now - Date.parse(view.active.lastEnd) > 86400000 && now - lastReviewToastMs > 86400000) {
      lastReviewToastMs = now
      notify("Worklog", "A session is waiting for review")
    }
  }

  Timer {
    interval: 20000
    repeat: true
    running: root.sessionState === "running"
    onTriggered: root.run(["heartbeat", "--boot-id", root.bootId])
  }

  // Lock: polled while it matters (running, or waiting for the user to come
  // back). Exit 0 locked, 1 unlocked, 2 undetermined (treated as unlocked).
  Timer {
    interval: 5000
    repeat: true
    running: (root.sessionState === "running" && root.pauseOnLock) || root.autoPaused
    triggeredOnStart: true
    onTriggered: if (!lockProbe.running) lockProbe.running = true
  }

  Process {
    id: lockProbe
    command: ["timeout", "-k", "2", "4", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      root.locked = exitCode === 0
      if (root.locked && root.sessionState === "running" && root.pauseOnLock) root.pause("lock", Date.now())
      else root.checkReturn()
    }
  }

  // Quickshell 0.3.1: an IdleMonitor whose timeout changes goes deaf, so a new
  // one is created for each setting value and the old one destroyed.
  property var idleMonitor: null
  property int idleMonitorTimeout: 0

  Component {
    id: idleComponent
    IdleMonitor {
      property bool retired: false
      respectInhibitors: true
      onIsIdleChanged: if (!retired) root.idleChanged(isIdle, timeout)
    }
  }

  function armIdle() {
    var want = idlePauseMinutes * 60
    if (idleMonitor && idleMonitorTimeout === want) return
    if (idleMonitor) {
      idleMonitor.retired = true
      idleMonitor.destroy()
      idleMonitor = null
    }
    idleMonitorTimeout = want
    if (want > 0) idleMonitor = idleComponent.createObject(root, { timeout: want })
  }
  onIdlePauseMinutesChanged: armIdle()

  function idleChanged(idle, timeoutSec) {
    if (idle && sessionState === "running") pause("idle", Date.now() - timeoutSec * 1000)
    else if (!idle) checkReturn()
  }

  // ------------------------------------------------------------ files

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.fileConfig = JSON.parse(text()) } catch (e) { root.fileConfig = null }
    }
    onLoadFailed: root.fileConfig = null
    onFileChanged: reload()
  }

  // Changes made outside this service (the helper run by hand, a restore
  // from backups/) show up within a second. Own writes trigger a read too,
  // which is cheap and writes nothing.
  // Same lookup as the helper's data_dir().
  readonly property string dataDir: Quickshell.env("WORKLOG_DATA_DIR")
    || (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/omarchy-worklog"
  Timer {
    id: outsideChange
    interval: 800
    onTriggered: if (!root.pending && root.queue.length === 0) root.refresh()
  }
  FileView {
    path: root.dataDir + "/active.json"
    watchChanges: true
    printErrors: false
    onFileChanged: outsideChange.restart()
  }
  FileView {
    path: root.dataDir + "/worklog.json"
    watchChanges: true
    printErrors: false
    onFileChanged: outsideChange.restart()
  }

  FileView {
    id: bootIdFile
    path: "/proc/sys/kernel/random/boot_id"
    printErrors: false
    onLoaded: {
      root.bootId = String(text()).trim().slice(0, 64)
      root.run(["recover", "--boot-id", root.bootId], function(r) {
        if (r.ok && r.recovery && r.recovery.reason === "restart")
          root.notify("Worklog paused", "Session paused at " + Model.localHM(r.recovery.at) + " (shutdown)")
        root.armIdle()
      })
    }
    onLoadFailed: {
      root.run(["recover"])
      root.armIdle()
    }
  }

  // ------------------------------------------------------------ IPC

  IpcHandler {
    target: "worklog"

    function start(): string { return root.start("") }
    function startWith(note: string): string { return root.start(note) }
    function pause(): string { return root.pause("manual", 0) }
    function resume(): string { return root.resume() }
    function toggle(): string { return root.toggle() }
    function stop(): string { return root.stop() }
    function confirm(): string {
      if (root.sessionState !== "ending") return "no-op: " + root.sessionState
      root.confirm(null, null, null, function(r) {
        if (!r.ok) root.notify("Worklog: not confirmed", r.error)
      })
      return "ok"
    }
    function discard(): string {
      if (root.sessionState === "idle") return "no-op: idle"
      root.discard(null)
      return "ok"
    }
    function startFor(company: string): string { return root.startFor(company) }
    function useCompany(company: string): string { root.useCompany(company, null); return "ok" }
    function company(): string {
      var c = root.currentCompanyInfo
      return c ? c.name + " (" + c.id + ") · " + Model.cycleName(c.cycleDay) : ""
    }
    function companies(): string {
      var list = root.view ? root.view.companies : []
      return JSON.stringify(list.map(function(c) {
        return { id: c.id, name: c.name, tag: c.tag, archived: c.archived, cycleDay: c.cycleDay, current: c.id === root.currentCompany }
      }))
    }
    function status(): string {
      var c = root.currentCompanyInfo
      return JSON.stringify({
        company: root.currentCompany, companyName: c ? c.name : "", billing: root.view ? root.view.month.billing : "",
        cycle: root.view ? root.view.month.label : "",
        state: root.sessionState, pauseReason: root.pauseReason, elapsedSec: root.sessionSec, pausedSec: root.pauseSec,
        since: root.view && root.view.active ? root.view.active.since : null, todaySec: root.todaySec,
        weekSec: root.week ? root.week.workedSec : 0, weekTargetSec: root.week ? root.week.targetSec : 0,
        monthSec: root.month ? root.month.workedSec : 0, monthTargetSec: root.month ? root.month.targetSec : 0,
        locked: root.locked, error: root.lastError
      })
    }
    function week(): string { return root.week ? Model.weekLine(root.week) : "" }
    function month(): string {
      if (!root.month) return ""
      var c = root.currentCompanyInfo
      return Model.monthLine(root.month) + (root.month.billing === "package" && !root.month.finished ? " · " + Model.paceLine(root.month) : "")
        + " · " + (c ? c.name : "") + " · " + root.view.month.label
    }
    // The weekly guide of the current company's terms in force today (edited
    // in place: a guide change is no reason for a new period).
    function target(hours: string): string {
      var n = Number(hours)
      if (!isFinite(n) || n < 0 || n > 80) return "hours 0 to 80"
      var c = root.currentCompanyInfo
      if (!c || !c.inForce) return "no terms in force today"
      var terms = Object.assign({}, c.inForce, { weeklyGuideHours: n })
      delete terms.from
      root.contract("set", { id: c.id, from: c.inForce.from, terms: terms }, null)
      return "ok"
    }
    function exportWeek(): string { root.exportPeriod("week", "this", "", null); return "ok" }
    function exportMonth(): string { root.exportPeriod("month", "this", root.currentCompany, null); return "ok" }
    function exportPeriod(kind: string, key: string): string {
      if (kind !== "week" && kind !== "month") return "kind: week or month"
      root.exportPeriod(kind, key, kind === "month" ? root.currentCompany : "", null)
      return "ok"
    }
    function exportFor(kind: string, key: string, company: string): string {
      if (kind !== "week" && kind !== "month") return "kind: week or month"
      root.exportPeriod(kind, key, company, null)
      return "ok"
    }
    function refresh(): string { root.refresh(); return "ok" }
    function probe(): string { return JSON.stringify({ locked: root.locked, idle: root.idleMonitor ? root.idleMonitor.isIdle : null, idleTimeout: root.idleMonitorTimeout, bootId: root.bootId }) }
  }
}
