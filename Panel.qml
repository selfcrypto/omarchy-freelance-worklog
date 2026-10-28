import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Worklog: a bar pill (the running clock) with a panel of seven pages.
//   track      the session, the current company's cycle against its terms,
//              this week, the last 8 weeks, recent sessions
//   away       back from an automatic pause: resume, count it, stay paused, end
//   review     the end of a session: what was done, the times, confirm
//   editor     a session from the history, or time that was not tracked
//   history    sessions week by week: edit, delete, add, export
//   month      one billing cycle (or a calendar month for all companies):
//              every day with its sessions, the package and the money
//   companies  companies and their contract periods
// All state lives in Service.qml, loaded once; this widget exists once per
// monitor and only reads from and calls into that service.
//
// Left-click opens the panel, right-click starts, pauses or resumes, middle
// ends the session. NOTE: after editing this file run `omarchy restart shell`.
Panel {
  id: root
  moduleName: "io.github.selfcrypto.worklog"
  ipcTarget: "io.github.selfcrypto.worklog"

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("io.github.selfcrypto.worklog") : null
  readonly property bool ready: svc !== null && svc !== undefined && svc.ready
  readonly property var view: ready ? svc.view : null
  readonly property string sessionState: ready ? svc.sessionState : "idle"
  readonly property double nowMs: ready ? svc.nowMs : Date.now()
  readonly property var week: ready ? svc.week : null
  readonly property var month: ready ? svc.month : null
  readonly property string currency: ready ? svc.currency : "€"
  readonly property string activeSince: view && view.active && view.active.since ? view.active.since : ""

  property string page: "track"
  property string editorMode: "new"
  property string editingId: ""
  property string confirmAction: ""

  // History: one week at a time.
  property string historyWeek: "this"
  property var history: null
  property int cursor: 0
  // Where the editor goes back to after an edit or an add.
  property string returnPage: "history"

  // Month page: a cycle key ("this" until loaded) and a company id or "all".
  property string monthKey: "this"
  property string monthCompany: ""
  property var monthData: null
  property int monthCursor: -1

  // Companies page: list, company (form) or contract (form).
  property string companiesMode: "list"
  property int companyCursor: 0
  property string formCompanyId: ""
  property string formFrom: ""
  property string formError: ""
  property string formErrorField: ""

  readonly property bool several: ready && svc.severalCompanies

  readonly property string monthMeta: {
    if (!monthData) return "Loading…"
    var worked = Model.fmtDuration(monthData.workedSec + monthOpenSec)
    if (monthData.company === "all") return worked + " · all companies"
    var c = companyInfo(monthData.company)
    var name = c ? c.name : ""
    var f = monthFigures
    if (!f) return worked + " · " + name
    if (f.billing === "none") return worked + " · no terms in this cycle · " + name
    if (f.billing === "hourly") return worked + " · " + name
    return worked + " of " + Model.fmtDuration(f.targetSec) + " · " + name
  }

  readonly property string companiesTitle: companiesMode === "company" ? (formCompanyId === "" ? "New company" : "Edit company")
    : (companiesMode === "contract" ? "Terms for " + (companyInfo(formCompanyId) ? companyInfo(formCompanyId).name : "") : "Companies")
  readonly property string companiesMeta: {
    if (!view) return ""
    if (companiesMode === "contract") return formFrom ? "from " + Model.dayMonth(formFrom, true) : "New period"
    if (companiesMode === "company") return "Name, tag and billing cycle"
    var active = view.companies.filter(function(c) { return !c.archived }).length
    var archived = view.companies.length - active
    return active + " active" + (archived ? " · " + archived + " archived" : "")
  }
  function companyInfo(id) { return view ? Model.companyOf(view, id) : null }

  readonly property color foreground: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Util.alpha(foreground, 0.72)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)

  readonly property string reasonText: {
    var r = ready ? svc.pauseReason : ""
    return r === "lock" ? "screen locked" : (r === "idle" ? "idle" : (r === "suspend" ? "suspend" : (r === "restart" ? "shutdown" : "")))
  }

  // The footer's key hints, page by page. Keys that belong to one row or
  // button stay beside it (away actions, discard, add on a day).
  readonly property var footerKeys: {
    if (!ready) return []
    if (page === "review" || page === "editor")
      return [{ key: "ctrl+enter", text: page === "review" ? "confirm" : "save" }, { key: "tab", text: "next field" }, { key: "esc", text: "back" }]
    if (page === "companies")
      return companiesMode === "list"
        ? [{ key: "enter", text: "edit" }, { key: "p", text: "new terms" }, { key: "a", text: "add" }, { key: "u", text: "use" }, { key: "del", text: "archive" }]
        : [{ key: "ctrl+enter", text: "save" }, { key: "tab", text: "next field" }, { key: "esc", text: "back" }]
    if (page === "month")
      return [{ key: "←/→", text: "cycle" }].concat(monthFilters.length > 1 ? [{ key: "c", text: "company" }] : [])
        .concat([{ key: "enter", text: "edit" }, { key: "del", text: "delete" }, { key: "n", text: "add" }, { key: "x", text: "export" }])
    if (page === "history")
      return [{ key: "←/→", text: "week" }, { key: "enter", text: "edit" }, { key: "del", text: "delete" }, { key: "n", text: "add" }, { key: "m", text: "month" }]
    if (page === "away") return []
    var live = sessionState === "running" || sessionState === "paused"
    return [{ key: "space", text: sessionState === "running" ? "pause" : (sessionState === "paused" ? "resume" : (sessionState === "ending" ? "review" : "start")) }]
      .concat(live ? [{ key: "e", text: "end" }] : []).concat([{ key: "n", text: "add time" }, { key: "m", text: "month" }, { key: "h", text: "history" }])
      .concat(several ? [{ key: "c", text: "company" }] : [])
  }

  // Track page: the activity chart shows this week ("week") or 8 weeks ("weeks").
  property string activityRange: "week"
  // Month page: hours by day ("days") or by week ("weeks").
  property string monthChart: "days"

  // ------------------------------------------------------------ navigation

  function go(target) {
    if (!ready) return
    if (target === "review" && sessionState !== "ending") target = "track"
    if (target === "away" && !svc.prompt) target = "track"
    page = target
    if (target === "review") {
      editorMode = "review"
      editor.load(Model.rowsFromSegments(view.active.segments), view.active.draft.summary, view.active.draft.tags, view.active.company || svc.currentCompany)
      Qt.callLater(editor.focusSummary)
      return
    }
    if (target === "history") loadHistory()
    if (target === "month") loadMonth()
    if (target === "companies") {
      companiesMode = "list"
      selectedCompanyId = svc.currentCompany
      companyCursor = Math.max(0, companyIndex(svc.currentCompany))
    }
    if (target === "track" && !svc.prompt) svc.announce()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // dateKey: the day the new rows fall on (the month page's day rows).
  function newEntry(dateKey) {
    if (!ready) return
    returnPage = page === "month" ? "month" : (page === "history" ? "history" : "track")
    editorMode = "new"
    editingId = ""
    page = "editor"
    var company = returnPage === "month" && monthCompany !== "all" ? monthCompany : svc.currentCompany
    editor.loadNew(dateKey || "", company)
    Qt.callLater(editor.focusSummary)
  }

  function editSession(s) {
    returnPage = page === "month" ? "month" : "history"
    editorMode = "edit"
    editingId = s.id
    page = "editor"
    editor.load(Model.rowsFromSegments(s.segments), s.summary, s.tags, s.company || svc.currentCompany)
    Qt.callLater(editor.focusSummary)
  }

  // ------------------------------------------------------------ month page

  function openMonth(key, company) {
    if (!ready) return
    monthKey = key || "this"
    monthCompany = company || svc.currentCompany
    monthData = null
    monthCursor = -1
    go("month")
  }

  // Every request carries a number; an answer to an older one is dropped,
  // so a slow reply never shows another company or cycle than the one picked.
  property int monthRequest: 0
  function loadMonth() {
    var ticket = ++monthRequest
    svc.monthData(monthKey, monthCompany, function(r) {
      if (!r.ok || ticket !== root.monthRequest) return
      root.monthData = r.month
      root.monthKey = r.month.key
      root.monthCursor = Math.min(root.monthCursor, root.monthRows.length - 1)
    })
  }

  // The month page is a snapshot: re-read it when the data changes (a pause
  // closes a segment, an edit elsewhere, an IPC call).
  Timer {
    id: monthReload
    interval: 300
    onTriggered: if (root.opened && root.page === "month") root.loadMonth()
  }
  Connections {
    target: root.svc
    function onViewChanged() { if (root.page === "month") monthReload.restart() }
  }

  // The cycle the month page cannot go past: the one holding today.
  readonly property string monthLimit: {
    var today = Model.localDateKey(nowMs)
    if (monthCompany === "all" || !monthData) return today.slice(0, 7)
    return Model.cycleOf(monthData.cycleDay, today)
  }

  function shiftMonth(n) {
    if (!monthData) return
    var next = Model.shiftCycle(monthData.key, n)
    if (next > monthLimit) return
    monthKey = next
    monthCursor = -1
    loadMonth()
  }

  // The month page's filter: All (with several companies), then each active
  // company, then archived ones that have sessions in the shown period.
  readonly property var monthFilters: {
    if (!view) return []
    var list = view.companies
    var history = list.filter(function(c) { return c.archived && c.sessionCount > 0 })
    var out = several || history.length ? [{ id: "all", name: "All", archived: false }] : []
    for (var i = 0; i < list.length; i++) if (!list[i].archived) out.push(list[i])
    for (var j = 0; j < history.length; j++) out.push(history[j])
    if (monthCompany !== "all" && !out.some(function(c) { return c.id === root.monthCompany })) {
      var own = companyInfo(monthCompany)
      if (own) out.push(own)
    }
    return out
  }

  function setMonthCompany(id) {
    if (id === monthCompany) return
    // Companies cut cycles on different days: keep the cycle holding the
    // first day shown, re-cut for the new filter.
    var first = monthData ? monthData.start : Model.localDateKey(nowMs)
    var info = companyInfo(id)
    monthKey = id === "all" ? first.slice(0, 7) : Model.cycleOf(info ? info.cycleDay : 1, first)
    monthCompany = id
    monthCursor = -1
    loadMonth()
  }

  function cycleMonthCompany(step) {
    var ids = monthFilters.map(function(c) { return c.id })
    if (ids.length > 1) setMonthCompany(Model.nextInList(ids, monthCompany, step))
  }

  // Day and session rows, flattened for the keyboard cursor.
  readonly property var monthRows: {
    var out = []
    if (!monthData) return out
    for (var i = 0; i < monthData.days.length; i++) {
      var d = monthData.days[i]
      out.push({ kind: "day", date: d.date, day: d })
      for (var j = 0; j < d.sessions.length; j++) out.push({ kind: "session", date: d.date, session: d.sessions[j] })
    }
    return out
  }

  // The figures the package card shows: the one company's, or null for all.
  readonly property var monthFigures: monthData && monthData.company !== "all" && monthData.companies.length ? monthData.companies[0].figures : null
  readonly property int monthOpenSec: monthData && view ? Model.monthOpenSecBetween(monthData, view, nowMs, Date.parse(monthData.startAt), Date.parse(monthData.endAt)) : 0
  readonly property var monthLiveFig: monthFigures ? Model.cycleLive(monthFigures, monthOpenSec,
    monthOpenSec > 0 ? Model.openSecByPart(monthFigures, view, nowMs) : null) : null
  readonly property var monthSeries: monthData && view ? Model.cycleDaySeries(monthData, view, nowMs) : { series: [], markers: [] }
  readonly property var monthWeekSeries: monthData && view ? Model.cycleWeekSeries(monthData, view, nowMs) : []
  readonly property real monthGuideHours: monthData && monthData.weeks.length ? monthData.weeks[monthData.weeks.length - 1].targetSec / 3600 : 0

  // Field keys on the companies forms: Ctrl+Enter saves, Esc goes back to the list.
  function formKey(item, event) {
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var next = item.nextItemInFocusChain((event.modifiers & Qt.ShiftModifier) === 0 && event.key === Qt.Key_Tab)
      if (next) next.forceActiveFocus()
      event.accepted = true
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
      if (companiesMode === "company") saveCompany()
      else savePeriod()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      companiesMode = "list"
      keyCatcher.forceActiveFocus()
      event.accepted = true
    }
  }

  // Scroll the panel so `item` (a row) is in view.
  function ensureVisible(item) {
    if (!item) return
    var p = item.mapToItem(column, 0, 0)
    if (p.y < viewport.contentY) viewport.contentY = Math.max(0, p.y - Style.space(8))
    else if (p.y + item.height > viewport.contentY + viewport.height)
      viewport.contentY = Math.min(column.implicitHeight - viewport.height, p.y + item.height - viewport.height + Style.space(8))
  }

  // A chart click: the rows of those days come into view and light up
  // for a moment (`flashFrom` to `flashTo`, date keys).
  property string flashFrom: ""
  property string flashTo: ""
  Timer {
    id: flashTimer
    interval: 1400
    onTriggered: { root.flashFrom = ""; root.flashTo = "" }
  }

  function dayRowIndex(dateKey) {
    for (var i = 0; i < monthRows.length; i++) if (monthRows[i].kind === "day" && monthRows[i].date >= dateKey) return i
    return -1
  }

  function revealDays(from, to, select) {
    var i = dayRowIndex(from)
    if (i < 0) return
    flashFrom = from
    flashTo = to
    flashTimer.restart()
    if (select) monthCursor = i
    var item = monthRowRepeater.itemAt(i)
    if (!item) return
    // The first row of the range near the top of the panel.
    var p = item.mapToItem(column, 0, 0)
    viewport.contentY = Math.max(0, Math.min(column.implicitHeight - viewport.height, p.y - Style.space(48)))
  }

  function revealWeek(i) {
    var w = monthData ? monthData.weeks[i] : null
    if (!w) return
    var from = w.start > monthData.start ? w.start : monthData.start
    var end = Model.addDays(w.start, 6)
    revealDays(from, end < monthData.end ? end : monthData.end, false)
  }

  function monthActivate(i) {
    var r = monthRows[i]
    if (!r) return
    if (r.kind === "session") editSession(r.session)
    else newEntry(r.date)
  }

  function askDeleteMonthRow() {
    var r = monthRows[monthCursor]
    if (!r || r.kind !== "session") return
    editingId = r.session.id
    returnPage = "month"
    confirmAction = "delete"
    dialog.message = "Delete the session of " + Model.dayLabel(r.date) + " (" + Model.fmtDuration(r.session.workedSec) + ")? This cannot be undone."
    dialog.confirmText = "Delete"
    dialog.selectedIndex = 0
    dialog.opened = true
  }

  // ------------------------------------------------------------ companies page

  // Company rows, the selected company's periods under it (newest first).
  property string selectedCompanyId: ""
  readonly property var companyRows: {
    var out = []
    if (!view) return out
    var list = view.companies
    for (var i = 0; i < list.length; i++) {
      out.push({ kind: "company", company: list[i] })
      if (list[i].id === selectedCompanyId)
        for (var j = list[i].contracts.length - 1; j >= 0; j--) out.push({ kind: "period", company: list[i], period: list[i].contracts[j] })
    }
    return out
  }

  function companyIndex(id) {
    for (var i = 0; i < companyRows.length; i++) if (companyRows[i].kind === "company" && companyRows[i].company.id === id) return i
    return -1
  }

  readonly property var companyRow: companyRows[companyCursor] || null
  readonly property var selectedCompany: companyInfo(selectedCompanyId)

  function selectCompanyRow(i) {
    var row = companyRows[i]
    if (!row) return
    if (row.kind === "company" && row.company.id !== selectedCompanyId) {
      // Another company: its periods replace the previous one's.
      selectedCompanyId = row.company.id
      companyCursor = companyIndex(row.company.id)
    } else {
      companyCursor = i
    }
  }

  function moveCompanyCursor(step) {
    if (companyRows.length) selectCompanyRow(Math.max(0, Math.min(companyRows.length - 1, companyCursor + step)))
  }

  function activateCompanyRow() {
    var row = companyRow
    if (!row) return
    if (row.kind === "company") editCompany(row.company)
    else editPeriod(row.company, row.period)
  }

  function editCompany(c) {
    formCompanyId = c ? c.id : ""
    formError = ""
    formErrorField = ""
    companiesMode = "company"
    companyNameField.text = c ? c.name : ""
    companyTagField.text = c ? c.tag : ""
    companyCycleField.text = String(c ? c.cycleDay : 1)
    Qt.callLater(function() { companyNameField.forceActiveFocus() })
  }

  function saveCompany() {
    var args = { name: companyNameField.text, tag: companyTagField.text, cycleDay: companyCycleField.text }
    var done = function(r) {
      if (!r.ok) { root.formError = r.error; root.formErrorField = r.field; return }
      if (root.formCompanyId === "") {
        // A new company: its first period, copied from the current terms,
        // goes straight to the terms form.
        var c = Model.companyOf(r.view, r.company)
        if (c) { root.editPeriod(c, c.contracts[0]); return }
      }
      root.companiesMode = "list"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
    if (formCompanyId === "") svc.company("add", args, done)
    else svc.company("rename", Object.assign({ id: formCompanyId }, args), done)
  }

  // A period of `c`; null `period` adds one from the next cycle's first day.
  function editPeriod(c, period) {
    if (!c) return
    var base = period || c.inForce || c.contracts[c.contracts.length - 1]
    var from = period ? period.from : Model.cycleBounds(c.cycleDay, Model.shiftCycle(Model.cycleOf(c.cycleDay, Model.localDateKey(nowMs)), 1)).first
    formCompanyId = c.id
    formFrom = period ? period.from : ""
    formError = ""
    formErrorField = ""
    termsBilling = base.billing
    termsFromField.text = from
    termsHoursField.text = String(base.monthlyHours || 40)
    termsFeeField.text = String(base.monthlyFee || 0)
    termsVatField.text = String(base.vatPercent)
    termsRateField.text = String(base.standardRate)
    termsGuideField.text = String(base.weeklyGuideHours)
    termsCurrencyField.text = base.currency
    termsExtraField.text = String(base.overageRate !== undefined ? base.overageRate : base.standardRate)
    companiesMode = "contract"
    Qt.callLater(function() { termsFromField.forceActiveFocus() })
  }

  property string termsBilling: "package"
  readonly property var termsDraft: ({
    from: termsFromField.text.trim(), billing: termsBilling, overageRate: termsExtraField.text,
    monthlyHours: termsHoursField.text, monthlyFee: termsFeeField.text, vatPercent: termsVatField.text,
    standardRate: termsRateField.text, weeklyGuideHours: termsGuideField.text, currency: termsCurrencyField.text
  })
  readonly property var termsCheck: companiesMode === "contract" ? Model.checkTerms(termsDraft) : { error: "", field: "" }

  // A date in the middle of a cycle prorates that cycle.
  readonly property string termsCaption: {
    var c = companyInfo(formCompanyId)
    var from = termsDraft.from
    if (!c || termsCheck.field === "from") return ""
    var key = Model.cycleOf(c.cycleDay, from)
    var b = Model.cycleBounds(c.cycleDay, key)
    if (b.first === from) return "Starts with the cycle " + Model.cycleLabel(c.cycleDay, key)
    return "Mid-cycle: the cycle " + Model.cycleLabel(c.cycleDay, key) + " is prorated by days"
  }

  function savePeriod() {
    if (termsCheck.error) { formError = termsCheck.error; formErrorField = termsCheck.field; return }
    var t = termsDraft
    var terms = { billing: t.billing, vatPercent: Number(t.vatPercent), standardRate: Number(t.standardRate),
      weeklyGuideHours: Number(t.weeklyGuideHours), currency: t.currency.trim() }
    if (t.billing === "package") {
      terms.monthlyHours = Number(t.monthlyHours)
      terms.monthlyFee = Number(t.monthlyFee)
      terms.overageRate = Number(t.overageRate)
    }
    svc.contract("set", { id: formCompanyId, from: t.from, terms: terms, replace: formFrom }, function(r) {
      if (!r.ok) { root.formError = r.error; root.formErrorField = r.field.replace("terms.", ""); return }
      root.companiesMode = "list"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    })
  }

  function askCompanyDelete() {
    var row = companyRow
    if (!row) return
    dialog.selectedIndex = 0
    if (row.kind === "period") {
      formCompanyId = row.company.id
      formFrom = row.period.from
      confirmAction = "deletePeriod"
      var c = row.company
      dialog.message = "Delete the terms from " + Model.dayMonth(row.period.from, true) + "? The cycles from "
        + Model.cycleLabel(c.cycleDay, Model.cycleOf(c.cycleDay, row.period.from)) + " on fall back to the previous terms."
      dialog.confirmText = "Delete"
    } else if (!row.company.archived) {
      formCompanyId = row.company.id
      confirmAction = "archive"
      dialog.message = "Archive " + row.company.name + "? Its sessions and cycles stay. It leaves the pickers."
      dialog.confirmText = "Archive"
    } else {
      formCompanyId = row.company.id
      confirmAction = "deleteCompany"
      dialog.message = "Delete " + row.company.name + "? " + (row.company.sessionCount ? "It has " + row.company.sessionCount + " sessions." : "It has no sessions.")
      dialog.confirmText = "Delete"
    }
    dialog.opened = true
  }

  function loadHistory() {
    svc.sessions("week", historyWeek, function(r) {
      if (!r.ok) return
      root.history = r.sessions
      root.cursor = Math.min(root.cursor, Math.max(0, r.sessions.sessions.length - 1))
    })
  }

  function shiftWeek(n) {
    var monday = history ? history.first : Model.localDateKey(nowMs)
    var next = Model.addDays(monday, 7 * n)
    if (next > Model.localDateKey(nowMs)) return
    var d = new Date(Model.addDays(next, 3) + "T12:00:00")
    // ISO week of the Thursday of that week.
    var jan4 = new Date(d.getFullYear(), 0, 4)
    var wk = 1 + Math.round(((d - jan4) / 86400000 - 3 + (jan4.getDay() + 6) % 7) / 7)
    historyWeek = d.getFullYear() + "-W" + (wk < 10 ? "0" : "") + wk
    cursor = 0
    loadHistory()
  }

  readonly property var historyRows: history ? history.sessions : []

  // ------------------------------------------------------------ actions

  function submitEditor(segments, summary, tags, running) {
    editor.busy = true
    var company = editor.company
    var done = function(r) {
      editor.busy = false
      if (!r.ok) { editor.error = r.error; editor.errorField = r.field; return }
      if (root.editorMode === "review" || running) root.go("track")
      else root.go(root.returnPage)
    }
    if (editorMode === "review") svc.confirm(summary, tags, segments, done, company)
    else if (editorMode === "edit") svc.updateSession(editingId, segments, summary, tags, done, company)
    else if (running) svc.startWithSegments(segments, company, function(r) {
      if (r.ok) svc.saveDraft(summary, tags)
      done(r)
    })
    else svc.addSession(segments, summary, tags, done, company)
  }

  function cancelEditor() {
    if (editorMode === "review") { svc.back(); go("track") }
    else go(returnPage)
  }

  function askDestroy() {
    if (editorMode === "review") {
      confirmAction = "discard"
      dialog.message = "Discard this session? " + Model.fmtDuration(editor.check.error ? svc.sessionSec : editor.check.workedSec) + " will not be recorded."
      dialog.confirmText = "Discard"
    } else {
      confirmAction = "delete"
      dialog.message = "Delete this session? This cannot be undone."
      dialog.confirmText = "Delete"
    }
    dialog.selectedIndex = 0
    dialog.opened = true
  }

  // The live session (running, paused or waiting for review), from the
  // track page or the d key. Nothing is written; the dialog defaults to Cancel.
  function askDiscard() {
    if (!ready || sessionState === "idle") return
    confirmAction = "discard"
    dialog.message = "Discard this session? " + Model.fmtDuration(svc.sessionSec) + " since " + Model.localHM(activeSince) + " will not be recorded."
    dialog.confirmText = "Discard"
    dialog.selectedIndex = 0
    dialog.opened = true
  }

  function askDeleteRow() {
    var s = historyRows[cursor]
    if (!s) return
    editingId = s.id
    returnPage = "history"
    confirmAction = "delete"
    dialog.message = "Delete the session of " + Model.dayLabel(s.date) + " (" + Model.fmtDuration(s.workedSec) + ")? This cannot be undone."
    dialog.confirmText = "Delete"
    dialog.selectedIndex = 0
    dialog.opened = true
  }

  function runConfirmed() {
    dialog.opened = false
    var back = function(r) {
      if (r && !r.ok) root.svc.notify("Worklog", r.error)
      root.companiesMode = "list"
      keyCatcher.forceActiveFocus()
    }
    if (confirmAction === "discard") svc.discard(function() { root.go("track") })
    else if (confirmAction === "delete") svc.deleteSession(editingId, function() { root.go(root.returnPage === "month" ? "month" : "history") })
    else if (confirmAction === "archive") svc.company("archive", { id: formCompanyId }, back)
    else if (confirmAction === "deleteCompany") svc.company("delete", { id: formCompanyId }, back)
    else if (confirmAction === "deletePeriod") svc.contract("delete", { id: formCompanyId, from: formFrom }, back)
    confirmAction = ""
  }

  // The month page for the cycle holding the shown week's Monday.
  function openHistoryMonth() {
    var c = svc.currentCompanyInfo
    var monday = history ? history.first : Model.localDateKey(nowMs)
    openMonth(Model.cycleOf(c ? c.cycleDay : 1, monday), svc.currentCompany)
  }

  // Next active company on the track page (the live session moves with it).
  function cycleCompany(step) {
    var ids = svc.activeCompanies.map(function(c) { return c.id })
    if (ids.length > 1) svc.useCompany(Model.nextInList(ids, svc.currentCompany, step), null)
  }

  function primaryAction() {
    if (!ready) return
    if (sessionState === "ending") go("review")
    else svc.toggle()
  }

  // ------------------------------------------------------------ panel life

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) { dialog.opened = false; return }
    if (!ready) return
    var wanted = svc.requestedPage
    svc.requestedPage = ""
    if (wanted === "") wanted = svc.prompt ? "away" : (sessionState === "ending" ? "review" : "track")
    historyWeek = "this"
    go(wanted)
  }

  Connections {
    target: root.svc
    function onRequestedPageChanged() {
      if (root.opened && root.svc.requestedPage !== "") {
        var p = root.svc.requestedPage
        root.svc.requestedPage = ""
        // Already open: the keyboard may have moved to a window on another
        // monitor. Take it back as a fresh open does.
        panel.focusPrimed = false
        panel.beginFocusPrime()
        root.go(p)
      }
    }
    function onSessionStateChanged() {
      if (!root.opened) return
      if (root.page === "review" && root.sessionState !== "ending") root.go("track")
      if (root.page === "away" && !root.svc.prompt) root.go("track")
    }
  }

  // A key as printed on the keyboard, for the keys the panel answers to.
  component KeyCap: Rectangle {
    required property string label
    implicitWidth: Math.max(implicitHeight, capText.implicitWidth + Style.space(8))
    implicitHeight: capText.implicitHeight + Style.space(2)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.28)

    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A card: the shared fill and padding.
  component Card: Rectangle {
    default property alias content: cardColumn.data
    property alias spacing: cardColumn.spacing
    width: parent ? parent.width : 0
    height: cardColumn.implicitHeight + Style.space(24)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent)

    Column {
      id: cardColumn
      x: Style.space(12)
      y: Style.space(12)
      width: parent.width - Style.space(24)
      spacing: Style.space(8)
    }
  }

  // Card header: a title on the left, a figure (or the chart readout) right.
  component CardHeader: Item {
    id: cardHeader
    property string title: ""
    property string figure: ""
    // A header that opens a page: hover shows it, a click opens it.
    property bool link: false
    property string linkTip: ""
    signal activated()
    // A figure too long to share the line goes under the title.
    readonly property bool stacked: figure !== "" && titleText.implicitWidth + figureText.implicitWidth + Style.space(8) > width
    width: parent ? parent.width : 0
    implicitHeight: headerRow.implicitHeight

    GridLayout {
      id: headerRow
      anchors.fill: parent
      columns: cardHeader.stacked ? 1 : 2
      columnSpacing: Style.space(8)
      rowSpacing: Style.space(2)

      Text {
        id: titleText
        Layout.fillWidth: true
        text: cardHeader.title + (cardHeader.link ? "  󰅂" : "")
        textFormat: Text.PlainText
        color: cardHeader.link && headerMouse.containsMouse ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        id: figureText
        Layout.fillWidth: cardHeader.stacked
        visible: cardHeader.figure !== ""
        text: cardHeader.figure
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: headerMouse
      anchors.fill: parent
      enabled: cardHeader.link
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: cardHeader.activated()

      PanelToolTip {
        visible: headerMouse.containsMouse && cardHeader.linkTip !== ""
        text: cardHeader.linkTip
        fontFamily: root.fontFamily
      }
    }
  }

  // A pill-shaped choice: filled when on (the WireGuard verdict chip look).
  component ChoiceChip: Rectangle {
    id: chip
    property string label: ""
    property bool on: false
    property bool faded: false
    // Long labels (company names) are cut; the tooltip has them whole.
    property real maxWidth: Style.space(160)
    signal clicked()
    implicitWidth: Math.min(chipText.implicitWidth, maxWidth) + Style.space(12)
    implicitHeight: chipText.implicitHeight + Style.space(6)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: on ? Style.selectedAccentFill : "transparent"
    border.width: 1
    border.color: on ? root.accent : Util.alpha(root.foreground, 0.28)
    opacity: faded ? 0.6 : 1

    Text {
      id: chipText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, chip.maxWidth)
      text: chip.label
      textFormat: Text.PlainText
      color: chip.on ? root.accent : (chipMouse.containsMouse ? root.foreground : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }

    PanelToolTip {
      visible: chipMouse.containsMouse && chipText.truncated
      text: chip.label
      fontFamily: root.fontFamily
    }
  }

  // A row of company chips; `companies` items carry id, name and archived.
  component CompanyChips: Flow {
    id: chips
    property var companies: []
    property string current: ""
    signal picked(string id)
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Repeater {
      model: chips.companies
      delegate: ChoiceChip {
        required property var modelData
        label: modelData.name
        on: modelData.id === chips.current
        faded: !!modelData.archived
        onClicked: chips.picked(modelData.id)
      }
    }
  }

  // What a cycle bills: a package against the standard rate, an hourly
  // total, or one line per part when the terms change kind inside it.
  // `live` from Model.cycleLive, `fig` the helper's cycle figures.
  component MoneyBlock: Column {
    id: moneyBlock
    property var live: null
    property var fig: null
    readonly property string cur: fig ? fig.currency : "€"
    readonly property var m: live ? live.money : null
    readonly property var packageParts: fig ? fig.parts.filter(function(p) { return p.billing === "package" }) : []
    width: parent ? parent.width : 0
    spacing: Style.space(2)

    function partTerms(p) {
      return Model.fmtDuration(p.monthlyHours * 3600) + " / " + Model.fmtMoney(p.monthlyFee, moneyBlock.cur)
    }

    // Terms changed inside a package cycle.
    Text {
      width: parent.width
      visible: moneyBlock.fig !== null && moneyBlock.fig.billing === "package" && moneyBlock.packageParts.length > 1
      text: {
        var ps = moneyBlock.packageParts
        if (ps.length < 2) return ""
        var out = []
        for (var i = 0; i < ps.length; i++) out.push(moneyBlock.partTerms(ps[i]) + " for " + ps[i].days + (ps[i].days === 1 ? " day" : " days"))
        return "Terms changed " + Model.dayMonth(ps[1].from) + ": " + out.join(", then ")
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      bottomPadding: Style.space(4)
    }

    // Package against the standard rate.
    GridLayout {
      width: parent.width
      visible: moneyBlock.fig !== null && moneyBlock.fig.billing === "package"
      columns: 2
      columnSpacing: Style.space(8)
      rowSpacing: Style.space(2)

      Text {
        text: moneyBlock.fig ? "At " + Model.fmtMoney(moneyBlock.fig.standardRate, moneyBlock.cur) + "/h" : ""
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        Layout.alignment: Qt.AlignRight
        text: moneyBlock.m ? Model.fmtMoney(moneyBlock.m.standardValue, moneyBlock.cur) : ""
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: true
      }

      Text {
        text: (moneyBlock.m && moneyBlock.m.overSec > 0 && !moneyBlock.m.overageWaived ? "Package + extra · " : "Package · ")
          + (moneyBlock.m && moneyBlock.m.effectiveRate !== null ? Model.fmtMoney(moneyBlock.m.effectiveRate, moneyBlock.cur, 2) + "/h" : "")
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        Layout.alignment: Qt.AlignRight
        text: moneyBlock.m ? Model.fmtMoney(moneyBlock.m.net, moneyBlock.cur) : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        visible: text !== ""
        text: !moneyBlock.m || !moneyBlock.fig || moneyBlock.m.discount === null || moneyBlock.m.discount <= 0 ? "" : "Discount " + Model.fmtMoney(moneyBlock.m.discount, moneyBlock.cur)
          + " (" + Model.fmtPercent(moneyBlock.m.discountPercent) + ")"
          + (moneyBlock.m.projected ? " on the " + Model.fmtDuration(moneyBlock.fig.targetSec) + " owed" : "")
          + (moneyBlock.m.overSec > 0 ? " · " + Model.fmtDuration(moneyBlock.m.overSec) + " over the package" : "")
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Hours over the package: billed at the extra hour rate, or waived.
    RowLayout {
      width: parent.width
      visible: moneyBlock.m !== null && moneyBlock.fig !== null && moneyBlock.fig.billing === "package" && moneyBlock.m.overSec > 0
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: !parent.visible ? "" : "Extra " + Model.fmtDuration(moneyBlock.m.overSec) + " at " + Model.fmtMoney(moneyBlock.m.overageRate, moneyBlock.cur) + "/h · "
          + Model.fmtMoney(moneyBlock.m.overageNet, moneyBlock.cur, 2) + (moneyBlock.m.overageWaived ? " waived" : "")
        textFormat: Text.PlainText
        color: moneyBlock.m && moneyBlock.m.overageWaived ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.strikeout: moneyBlock.m !== null && moneyBlock.m.overageWaived
        elide: Text.ElideRight
      }
      ChoiceChip {
        label: moneyBlock.m && moneyBlock.m.overageWaived ? "Bill them" : "Waive"
        onClicked: root.svc.overage(moneyBlock.m.overageWaived ? "bill" : "waive", moneyBlock.fig.company, moneyBlock.fig.key, function() {
          if (root.page === "month") root.loadMonth()
        })

        HoverHandler { id: waiveHover }
        PanelToolTip {
          visible: waiveHover.hovered
          text: moneyBlock.m && moneyBlock.m.overageWaived ? "Bill the extra hours of this cycle again" : "Leave the extra hours of this cycle off the invoice; the report lists them as waived"
          fontFamily: root.fontFamily
        }
      }
    }

    // Hourly: one line.
    Text {
      width: parent.width
      visible: moneyBlock.fig !== null && moneyBlock.m !== null && Model.uniformHourly(moneyBlock.m)
      text: !visible || !moneyBlock.live ? "" : Model.fmtDuration(moneyBlock.live.workedSec) + " at " + Model.fmtMoney(moneyBlock.m.lines[0].standardRate, moneyBlock.cur) + "/h · "
        + Model.fmtMoney(moneyBlock.m.net, moneyBlock.cur) + " + VAT " + moneyBlock.m.lines[0].vatPercent + " % = " + Model.fmtMoney(moneyBlock.m.gross, moneyBlock.cur, 2)
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Mixed or no terms: one line per part, then the total.
    Repeater {
      model: moneyBlock.fig && moneyBlock.m && (moneyBlock.fig.billing === "mixed" || moneyBlock.fig.billing === "none"
        || (moneyBlock.fig.billing === "hourly" && !Model.uniformHourly(moneyBlock.m))) ? moneyBlock.m.lines : []
      delegate: RowLayout {
        required property var modelData
        width: moneyBlock.width
        spacing: Style.space(8)
        Text {
          Layout.fillWidth: true
          text: Model.dayMonth(modelData.from) + " to " + Model.dayMonth(modelData.to) + " · "
            + (modelData.billing === "package" ? "package" : (modelData.billing === "hourly" ? Model.fmtDuration(modelData.workedSec) + " at " + Model.fmtMoney(modelData.standardRate, moneyBlock.cur) + "/h"
              : "no terms, " + Model.fmtDuration(modelData.workedSec) + " not billed"))
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          text: modelData.billing === "none" ? "" : Model.fmtMoney(modelData.net, moneyBlock.cur)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
    RowLayout {
      width: parent.width
      visible: moneyBlock.fig !== null && moneyBlock.m !== null && (moneyBlock.fig.billing === "mixed"
        || (moneyBlock.fig.billing === "hourly" && !Model.uniformHourly(moneyBlock.m)))
      Text {
        Layout.fillWidth: true
        text: "To invoice"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        text: moneyBlock.m ? Model.fmtMoney(moneyBlock.m.net, moneyBlock.cur) + " + VAT" : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }
  }

  // Progress against a target; `marker` (0..1, -1 none) is where the pace
  // says the bar should be by now.
  component Meter: Item {
    property real value: 0
    property real marker: -1
    width: parent ? parent.width : 0
    height: Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.foreground, 0.16)
    }
    Rectangle {
      width: Math.max(value > 0 ? height : 0, parent.width * Math.min(1, value))
      height: parent.height
      radius: height / 2
      color: root.accent
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
    Rectangle {
      visible: marker >= 0
      x: Math.round(parent.width * Math.min(1, marker)) - 1
      y: -Style.space(3)
      width: 2
      height: parent.height + Style.space(6)
      radius: 1
      color: root.foreground
    }
  }

  // A two-line action row with its key, as in the other panels.
  component ActionRow: Rectangle {
    id: actionRow
    property string glyph: ""
    property string title: ""
    property string caption: ""
    property string key: ""
    property bool primary: false
    signal triggered()
    width: parent ? parent.width : 0
    height: Style.space(48)
    radius: Style.cornerRadius
    color: actionMouse.containsMouse ? root.hoverFill : "transparent"

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: actionRow.triggered()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        Layout.preferredWidth: Style.space(30)
        Layout.preferredHeight: Style.space(30)
        radius: Style.cornerRadius
        color: actionRow.primary ? Style.selectedAccentFill : Style.normalFillFor(root.foreground, root.accent)

        Text {
          anchors.centerIn: parent
          text: actionRow.glyph
          color: actionRow.primary ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: actionRow.title
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: actionRow.primary
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: actionRow.caption !== ""
          text: actionRow.caption
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      KeyCap { visible: actionRow.key !== ""; label: actionRow.key }
    }
  }

  // A session in a list: day, times, duration; summary and tags under it.
  component SessionRow: Rectangle {
    id: sessionRow
    required property var session
    property bool selected: false
    property bool showDate: true
    signal activated()
    width: parent ? parent.width : 0
    height: Style.space(48)
    radius: Style.cornerRadius
    color: selected ? Style.selectedFill : (sessionMouse.containsMouse ? root.hoverFill : "transparent")

    MouseArea {
      id: sessionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: sessionRow.activated()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        readonly property bool today: sessionRow.session.date === Model.localDateKey(root.nowMs)
        Layout.preferredWidth: Style.space(30)
        Layout.preferredHeight: Style.space(30)
        radius: Style.cornerRadius
        color: today ? Style.selectedAccentFill : Style.normalFillFor(root.foreground, root.accent)

        Text {
          anchors.centerIn: parent
          text: sessionRow.session.source === "manual" ? "󰏫" : "󰃭"
          color: parent.today ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: (sessionRow.showDate ? Model.dayLabel(sessionRow.session.date) + " · " : "")
            + Model.localHM(sessionRow.session.start) + "–" + Model.localHM(sessionRow.session.end)
            + " · " + Model.fmtDuration(sessionRow.session.workedSec)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: sessionRow.selected
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: (root.several && root.companyInfo(sessionRow.session.company) ? root.companyInfo(sessionRow.session.company).tag + " · " : "")
            + Model.clip(Model.firstLine(sessionRow.session.summary), 200)
            + (sessionRow.session.tags.length ? "  ·  " + sessionRow.session.tags.join(", ") : "")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component Hints: Flow {
    property var keys: []
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Repeater {
      model: parent.keys
      delegate: Row {
        id: hint
        required property var modelData
        spacing: Style.space(5)
        rightPadding: Style.space(8)

        KeyCap { label: hint.modelData.key }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: hint.modelData.text
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ------------------------------------------------------------ bar pill

  readonly property string pillLabel: {
    if (!ready || !svc.showElapsed) return ""
    var tag = several && svc.liveCompanyInfo ? svc.liveCompanyInfo.tag + " " : ""
    if (sessionState === "running") return tag + Model.fmtClock(svc.sessionSec)
    if (sessionState === "paused") return tag + Model.fmtClock(svc.sessionSec)
    if (sessionState === "ending") return "review"
    return ""
  }

  readonly property string liveCompanyName: several && svc.liveCompanyInfo ? " " + svc.liveCompanyInfo.name : ""

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.sessionState === "paused" ? "󰏤" : (root.sessionState === "ending" ? "󰗠" : "󰔟")) + (root.pillLabel !== "" ? " " + root.pillLabel : "")
    active: root.sessionState === "running" || root.sessionState === "ending"
    activeColor: root.accent
    dimmed: root.sessionState === "idle"
    tooltipText: {
      if (!root.ready) return "Worklog: service not running"
      var w = root.week ? Model.weekLine(root.week) : ""
      if (root.sessionState === "running") return "Worklog: running" + root.liveCompanyName + " since " + Model.localHM(root.activeSince) + " · today " + Model.fmtDuration(root.svc.todaySec) + " · right-click pauses"
      if (root.sessionState === "paused") return "Worklog: paused " + Model.fmtDuration(root.svc.pauseSec) + (root.reasonText ? " (" + root.reasonText + ")" : "") + " · right-click resumes"
      if (root.sessionState === "ending") return "Worklog: session waiting for review"
      if (root.several && root.svc.currentCompanyInfo) return "Worklog: next start is " + root.svc.currentCompanyInfo.name + " · " + w + " · right-click starts"
      return "Worklog: " + w + " · right-click starts"
    }
    onPressed: function(buttonCode) {
      if (!root.ready) return
      if (buttonCode === Qt.RightButton) root.primaryAction()
      else if (buttonCode === Qt.MiddleButton) root.svc.stop()
      else root.toggle()
    }

    // After an automatic pause, until the panel has been opened.
    SequentialAnimation on opacity {
      running: root.ready && root.svc.autoPaused
      loops: Animation.Infinite
      onRunningChanged: if (!running) button.opacity = 1
      NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(hero.implicitHeight + Style.space(12) + column.implicitHeight
      + (footer.visible ? Style.space(12) + footer.implicitHeight : 0), Style.space(720))

    // Not the stock PanelKeyCatcher: it eats h/j/k/l and x as cursor keys.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        if (dialog.opened) { if (dialog.handleKey(event)) event.accepted = true; return }
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Escape) {
          if (root.page === "track") root.close()
          else if (root.page === "editor") root.cancelEditor()
          else if (root.page === "companies" && root.companiesMode !== "list") { root.companiesMode = "list"; keyCatcher.forceActiveFocus() }
          else root.go("track")
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        if (root.page === "review" || root.page === "editor") {
          if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { editor.submit(); event.accepted = true }
          return
        }
        if (root.page === "companies") {
          if (root.companiesMode !== "list") {
            if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
              if (root.companiesMode === "company") root.saveCompany()
              else root.savePeriod()
              event.accepted = true
            }
            return
          }
          if (event.key === Qt.Key_Up) root.moveCompanyCursor(-1)
          else if (event.key === Qt.Key_Down) root.moveCompanyCursor(1)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.activateCompanyRow()
          else if (event.key === Qt.Key_Delete) root.askCompanyDelete()
          else if (event.text === "a") root.editCompany(null)
          else if (event.text === "p") root.editPeriod(root.selectedCompany, null)
          else if (event.text === "u" && root.selectedCompany && !root.selectedCompany.archived) root.svc.useCompany(root.selectedCompany.id, null)
          else return
          event.accepted = true
          return
        }
        if (root.page === "month") {
          var n = root.monthRows.length
          if (event.key === Qt.Key_Left) root.shiftMonth(-1)
          else if (event.key === Qt.Key_Right) root.shiftMonth(1)
          else if (event.key === Qt.Key_Up) root.monthCursor = Math.max(0, root.monthCursor - 1)
          else if (event.key === Qt.Key_Down) root.monthCursor = Math.min(n - 1, root.monthCursor + 1)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.monthActivate(root.monthCursor)
          else if (event.key === Qt.Key_Delete) root.askDeleteMonthRow()
          else if (event.text === "n") {
            var r = root.monthRows[root.monthCursor]
            var today = Model.localDateKey(root.nowMs)
            root.newEntry(r ? r.date : (root.monthData && root.monthData.end < today ? root.monthData.end : today))
          }
          else if (event.text === "c") root.cycleMonthCompany(1)
          else if (event.text === "C") root.go("companies")
          else if (event.text === "x") root.svc.exportPeriod("month", root.monthKey, root.monthCompany, null)
          else return
          event.accepted = true
          return
        }
        if (root.page === "history") {
          if (event.key === Qt.Key_Left) root.shiftWeek(-1)
          else if (event.key === Qt.Key_Right) root.shiftWeek(1)
          else if (event.key === Qt.Key_Up) root.cursor = Math.max(0, root.cursor - 1)
          else if (event.key === Qt.Key_Down) root.cursor = Math.min(root.historyRows.length - 1, root.cursor + 1)
          else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.historyRows[root.cursor]) root.editSession(root.historyRows[root.cursor])
          else if (event.key === Qt.Key_Delete) root.askDeleteRow()
          else if (event.text === "n") root.newEntry()
          else if (event.text === "x") root.svc.exportPeriod("week", root.historyWeek, "", null)
          else if (event.text === "m") root.openHistoryMonth()
          else if (event.text === "h") root.go("track")
          else return
          event.accepted = true
          return
        }
        if (root.page === "away") {
          if (event.text === "r") root.svc.resume()
          else if (event.text === "c") root.svc.unpause()
          else if (event.text === "p") { root.svc.keepPaused(); root.go("track") }
          else if (event.text === "e") root.svc.stop()
          else return
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Space) root.primaryAction()
        else if (event.text === "e") root.svc.stop()
        else if (event.text === "d") root.askDiscard()
        else if (event.text === "n") root.newEntry()
        else if (event.text === "h") root.go("history")
        else if (event.text === "m") root.openMonth("this", root.svc.currentCompany)
        else if (event.text === "c" && root.several) root.cycleCompany(1)
        else if (event.text === "a") root.activityRange = root.activityRange === "week" ? "weeks" : "week"
        else if (event.text === "C") root.go("companies")
        else return
        event.accepted = true
      }

      // The frame: the hero and the key hints stay put; the page scrolls
      // between them.
      PanelHero {
        id: hero
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: root.page === "history" ? "History" : (root.page === "review" ? "Session ended"
          : (root.page === "away" ? "Welcome back" : (root.page === "editor" ? (root.editorMode === "edit" ? "Edit session" : "Add time")
          : (root.page === "month" ? (root.monthData ? root.monthData.label : "Month")
          : (root.page === "companies" ? root.companiesTitle : "Freelance Worklog")))))
        meta: {
          if (!root.ready) return "Service not running"
          if (root.page === "month") return root.monthMeta
          if (root.page === "companies") return root.companiesMeta
          if (root.page === "history") return root.history
            ? root.history.key.replace("-", " ") + " · " + Model.weekRange(root.history.first) + " · " + Model.fmtDuration(root.history.figures.workedSec)
            : "Loading…"
          // The form's total: segments under a minute are left out.
          if (root.page === "review") return (editor.check.error ? "Nothing to record" : Model.fmtDuration(editor.check.workedSec) + " worked")
            + " · " + Model.dayLabel(Model.localDateKey(Date.parse(root.activeSince || root.view.now)))
          if (root.page === "away") return root.svc.prompt ? "Away " + Model.fmtDuration(root.svc.prompt.awaySec) + " · paused at " + Model.localHM(root.svc.prompt.since) : ""
          if (root.page === "editor") return root.editorMode === "edit" ? "Changes are saved as edited" : "Work you did not track"
          if (root.sessionState === "running") return "Running · since " + Model.localHM(root.activeSince)
          if (root.sessionState === "paused") return "Paused " + Model.fmtDuration(root.svc.pauseSec) + (root.reasonText ? " · " + root.reasonText : "")
          if (root.sessionState === "ending") return "Waiting for review"
          return "Not tracking"
        }
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Text {
            text: root.page === "history" ? "󰋚" : (root.page === "review" ? "󰗠" : (root.page === "editor" ? "󰏫"
              : (root.page === "month" ? "󰃭" : (root.page === "companies" ? "󰒔" : (root.sessionState === "paused" ? "󰏤" : "󰔟")))))
            color: root.sessionState === "running" || root.page === "review" ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
        trailingControl: root.page === "history" ? weekNavComponent : (root.page === "track" ? switchComponent
          : (root.page === "month" ? monthNavComponent : (root.page === "companies" ? backComponent : null)))
      }

      Flickable {
        id: viewport
        anchors.top: hero.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: footer.visible ? Style.space(12) : 0
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: viewport.width
          spacing: Style.space(12)

          Component {
            id: switchComponent
            Row {
              spacing: Style.space(10)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒓"
                tooltipText: "Companies and contract terms (C)"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.go("companies")
              }

              ToggleSwitch {
                id: runSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: root.sessionState === "running"
                interactive: root.ready && root.sessionState !== "ending"
                foreground: root.foreground
                onToggled: root.primaryAction()

                PanelToolTip {
                  visible: runSwitch.containsMouse
                  text: root.sessionState === "running" ? "Pause" : (root.sessionState === "paused" ? "Resume" : "Start")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Component {
            id: weekNavComponent
            Row {
              spacing: Style.space(4)
              PanelActionButton {
                iconText: "󰁍"
                tooltipText: "Back (h)"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.go("track")
              }
              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Previous week"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.shiftWeek(-1)
              }
              PanelActionButton {
                iconText: "󰅂"
                tooltipText: "Next week"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.shiftWeek(1)
              }
            }
          }

          Component {
            id: monthNavComponent
            Row {
              spacing: Style.space(4)
              PanelActionButton {
                iconText: "󰁍"
                tooltipText: "Back (esc)"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.go("track")
              }
              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Previous cycle (←)"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.shiftMonth(-1)
              }
              PanelActionButton {
                iconText: "󰅂"
                tooltipText: "Next cycle (→)"
                foreground: root.monthData && Model.shiftCycle(root.monthData.key, 1) <= root.monthLimit ? root.dim : Util.alpha(root.foreground, 0.3)
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.shiftMonth(1)
              }
            }
          }

          Component {
            id: backComponent
            PanelActionButton {
              iconText: "󰁍"
              tooltipText: "Back (esc)"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.companiesMode === "list" ? root.go("track") : (root.companiesMode = "list")
            }
          }

          // ---------------------------------------------------- track

          Column {
            visible: root.page === "track" && root.ready
            width: parent.width
            spacing: Style.space(12)

            // The live card: the session, its clock and its controls.
            Card {
              CardHeader {
                title: root.sessionState === "idle" ? "No session running" : (root.sessionState === "ending" ? "Session ended" : "This session")
                figure: root.sessionState === "idle" && root.svc.todaySec === 0 ? "" : "Today " + Model.fmtDuration(root.svc.todaySec)
              }

              // Several companies: which one this session (or the next) is for.
              CompanyChips {
                visible: root.several && root.sessionState !== "ending"
                companies: root.ready ? root.svc.activeCompanies : []
                current: root.view && root.view.active ? root.view.active.company : (root.ready ? root.svc.currentCompany : "")
                onPicked: function(id) { root.svc.useCompany(id, null) }
              }

              Text {
                visible: root.sessionState === "running" || root.sessionState === "paused"
                text: {
                  var s = root.svc.sessionSec
                  return Model.fmtClock(s) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
                }
                textFormat: Text.PlainText
                color: root.sessionState === "running" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: root.sessionState === "running"
              }

              Text {
                width: parent.width
                text: {
                  if (root.sessionState === "idle") return "Space starts the clock; n adds time you did not track."
                  if (root.sessionState === "ending") return "Write what you did and confirm the times."
                  if (!root.view || !root.view.active) return ""
                  var paused = Model.sessionPausedSec(root.view, root.nowMs)
                  var n = root.view.active.segments.length
                  return "Since " + Model.localHM(root.activeSince) + (paused >= 60 ? " · paused " + Model.fmtDuration(paused) : "")
                    + (n > 1 ? " · " + n + " segments" : "")
                }
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.sessionState === "running" ? "Pause" : (root.sessionState === "paused" ? "Resume" : (root.sessionState === "ending" ? "Review" : "Start"))
                  iconText: root.sessionState === "running" ? "󰏤" : (root.sessionState === "ending" ? "󰗠" : "󰐊")
                  active: true
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  tooltipText: "Space"
                  onClicked: root.primaryAction()
                }

                Button {
                  visible: root.sessionState === "running" || root.sessionState === "paused"
                  text: "End session"
                  iconText: "󰓛"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  tooltipText: "e"
                  onClicked: root.svc.stop()
                }

                Item { Layout.fillWidth: true }

                PanelActionButton {
                  visible: root.sessionState !== "idle"
                  iconText: "󰆴"
                  tooltipText: "Discard this session (d)"
                  foreground: root.dim
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.askDiscard()
                }

                Button {
                  text: "Add time"
                  iconText: "󰐕"
                  foreground: root.dim
                  accent: root.accent
                  fontFamily: root.fontFamily
                  tooltipText: "n: a session you did not track"
                  onClicked: root.newEntry()
                }
              }
            }

            // The current company's cycle: hours against its terms, this week,
            // and what it invoices so far (the month page has the breakdown).
            Card {
              visible: root.month !== null
              CardHeader {
                title: root.view ? root.view.month.label + (root.several && root.svc.currentCompanyInfo ? " · " + root.svc.currentCompanyInfo.name : "") : ""
                figure: !root.month ? "" : (root.month.billing === "package" ? Model.fmtDuration(root.month.workedSec) + " of " + Model.fmtDuration(root.month.targetSec)
                  : Model.fmtDuration(root.month.workedSec))
                link: true
                linkTip: "Every day of this cycle (m)"
                onActivated: root.openMonth("this", root.svc.currentCompany)
              }

              Meter {
                visible: root.month !== null && root.month.billing === "package"
                value: root.month && root.month.targetSec > 0 ? root.month.workedSec / root.month.targetSec : 0
                marker: root.month && root.month.targetSec > 0 ? root.month.expectedSec / root.month.targetSec : -1

                HoverHandler { id: meterHover }
                PanelToolTip {
                  visible: meterHover.hovered
                  text: root.month ? "The tick is the pace: " + Model.fmtDuration(root.month.expectedSec) + " by today" : ""
                  fontFamily: root.fontFamily
                }
              }

              RowLayout {
                width: parent.width
                visible: root.month !== null && root.month.billing === "package"
                spacing: Style.space(6)

                Text {
                  text: root.month ? Model.paceLine(root.month) : ""
                  textFormat: Text.PlainText
                  color: root.month && root.month.balanceSec <= -15 * 60 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  Layout.fillWidth: true
                  text: root.month ? (root.month.remainingSec > 0 ? "· " + Model.fmtDuration(root.month.remainingSec) + " left · "
                    + root.month.daysLeft + (root.month.daysLeft === 1 ? " day" : " days") : "· package done") : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                width: parent.width
                visible: root.month !== null && root.month.billing !== "package"
                text: root.month ? Model.monthLine(root.month) : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: root.week !== null
                text: {
                  var w = root.week
                  if (!w) return ""
                  if (!(w.targetSec > 0)) return "This week " + Model.fmtDuration(w.workedSec)
                  return "This week " + Model.fmtDuration(w.workedSec) + " of " + Model.fmtDuration(w.targetSec)
                    + (w.done ? " · done" : " · " + Model.fmtDuration(w.perDaySec) + " a day")
                }
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.1) }

              RowLayout {
                id: moneyLine
                readonly property var summary: root.month ? Model.moneySummary(root.month) : null
                width: parent.width
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: moneyLine.summary ? moneyLine.summary.label : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  text: moneyLine.summary ? moneyLine.summary.amount : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }
            }

            // Recent sessions.
            Column {
              width: parent.width
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  Layout.fillWidth: true
                  text: "Recent"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // The way into the history: every session, week by week.
                Text {
                  text: "All sessions  󰅂"
                  textFormat: Text.PlainText
                  color: allMouse.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: allMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.go("history")
                  }
                }
              }

              Text {
                visible: root.view !== null && root.view.recent.length === 0
                width: parent.width
                text: "No sessions yet. Space starts one, n adds time you did not track."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                topPadding: Style.space(6)
              }

              Rectangle {
                visible: root.view !== null && root.view.recent.length > 0
                width: parent.width
                height: recentRows.implicitHeight
                radius: Style.cornerRadius
                color: Style.normalFillFor(root.foreground, root.accent)

                Column {
                  id: recentRows
                  width: parent.width

                  Repeater {
                    model: root.view ? root.view.recent.slice(0, 3) : []
                    delegate: SessionRow {
                      required property var modelData
                      session: modelData
                      onActivated: root.editSession(modelData)
                    }
                  }
                }
              }
            }

            // Activity: this week by day, or the last 8 weeks (a).
            Card {
              visible: root.view !== null

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: "Activity"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                ChoiceChip { label: "Week"; on: root.activityRange === "week"; onClicked: root.activityRange = "week" }
                ChoiceChip { label: "8 weeks"; on: root.activityRange === "weeks"; onClicked: root.activityRange = "weeks" }
              }

              Text {
                width: parent.width
                text: {
                  if (root.activityRange === "week") return dayChart.readout !== "" ? dayChart.readout : (root.view ? Model.weekRange(root.view.week.start) : "")
                  if (trendChart.readout !== "") return trendChart.readout
                  if (!root.view) return ""
                  var t = root.view.trend
                  var sum = 0
                  for (var i = Math.max(0, t.length - 5); i < t.length - 1; i++) sum += t[i].workedSec
                  return "4-week average " + Model.fmtDuration(sum / 4)
                }
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              WeekChart {
                id: dayChart
                visible: root.activityRange === "week"
                width: parent.width
                series: root.view ? Model.daySeries(root.view, root.nowMs) : []
                target: root.week ? root.week.targetSec / 3600 / 5 : 0
                targetSubtle: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
              }

              WeekChart {
                id: trendChart
                visible: root.activityRange === "weeks"
                width: parent.width
                series: root.view ? Model.weekSeries(root.view, root.nowMs) : []
                target: root.week ? root.week.targetSec / 3600 : 0
                targetLabel: root.week ? Model.fmtDuration(root.week.targetSec) : ""
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
              }

              // What the dashed line is.
              Text {
                width: parent.width
                visible: text !== ""
                text: !root.week || !(root.week.targetSec > 0) ? ""
                  : (root.activityRange === "week" ? "Dashed line: " + Model.fmtDuration(root.week.targetSec / 5) + " a weekday, the weekly guide over five days"
                    : "Dashed line: the weekly guide")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------------------------------------------------- away

          Column {
            visible: root.page === "away" && root.ready && root.svc.prompt !== null
            width: parent.width
            spacing: Style.space(12)

            Card {
              Text {
                width: parent.width
                text: root.svc && root.svc.prompt
                  ? "The session paused at " + Model.localHM(root.svc.prompt.since) + " ("
                    + (root.svc.prompt.reason === "lock" ? "screen locked" : (root.svc.prompt.reason === "restart" ? "shutdown" : root.svc.prompt.reason))
                    + "). You were away " + Model.fmtDuration(root.svc.prompt.awaySec) + "."
                  : ""
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                text: "Session so far: " + Model.fmtDuration(root.svc ? root.svc.sessionSec : 0)
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              width: parent.width
              height: awayRows.implicitHeight
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)

              Column {
                id: awayRows
                width: parent.width

                ActionRow {
                  glyph: "󰐊"
                  title: "Resume now"
                  caption: "The time away is not counted"
                  key: "r"
                  primary: true
                  onTriggered: root.svc.resume()
                }
                ActionRow {
                  glyph: "󰄬"
                  title: "Count it as work"
                  caption: root.svc && root.svc.prompt ? "Add the " + Model.fmtDuration(root.svc.prompt.awaySec) + " away and keep running" : ""
                  key: "c"
                  onTriggered: root.svc.unpause()
                }
                ActionRow {
                  glyph: "󰏤"
                  title: "Stay paused"
                  caption: "Resume later from the bar"
                  key: "p"
                  onTriggered: { root.svc.keepPaused(); root.go("track") }
                }
                ActionRow {
                  glyph: "󰓛"
                  title: "End the session"
                  caption: "Review and confirm what you did"
                  key: "e"
                  onTriggered: root.svc.stop()
                }
              }
            }
          }

          // ---------------------------------------------------- month

          Column {
            visible: root.page === "month" && root.ready
            width: parent.width
            spacing: Style.space(12)

            CompanyChips {
              visible: root.monthFilters.length > 1
              companies: root.monthFilters
              current: root.monthCompany
              onPicked: function(id) { root.setMonthCompany(id) }
            }

            Text {
              visible: root.monthData === null
              text: "Loading…"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // One company: its terms and money.
            Card {
              visible: root.monthLiveFig !== null
              CardHeader {
                title: !root.monthFigures ? "" : (root.monthFigures.billing === "package" ? "Package"
                  : (root.monthFigures.billing === "hourly" ? "Hourly" : (root.monthFigures.billing === "none" ? "No terms" : "Terms")))
                figure: root.monthLiveFig ? Model.monthLine(root.monthLiveFig) : ""
              }

              Meter {
                visible: root.monthLiveFig !== null && root.monthLiveFig.billing === "package"
                value: root.monthLiveFig && root.monthLiveFig.targetSec > 0 ? root.monthLiveFig.workedSec / root.monthLiveFig.targetSec : 0
                marker: root.monthLiveFig && root.monthLiveFig.targetSec > 0 && !root.monthLiveFig.finished ? root.monthLiveFig.expectedSec / root.monthLiveFig.targetSec : -1
              }

              Text {
                visible: root.monthLiveFig !== null && root.monthLiveFig.billing === "package" && !root.monthLiveFig.finished
                  && root.monthFigures.elapsedDays > 0
                text: root.monthLiveFig ? Model.paceLine(root.monthLiveFig) : ""
                textFormat: Text.PlainText
                color: root.monthLiveFig && root.monthLiveFig.balanceSec <= -15 * 60 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                width: parent.width
                visible: root.monthFigures !== null && root.monthFigures.billing === "none"
                text: "No terms cover this cycle. Add a period on the companies page (C)."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.1); visible: root.monthFigures !== null && root.monthFigures.billing !== "none" }

              MoneyBlock {
                visible: root.monthFigures !== null && root.monthFigures.billing !== "none"
                live: root.monthLiveFig
                fig: root.monthFigures
              }
            }

            // All companies: hours and what each invoices.
            Card {
              visible: root.monthData !== null && root.monthData.company === "all"
              CardHeader {
                title: "Companies"
                figure: root.monthData ? Model.fmtDuration(root.monthData.workedSec + root.monthOpenSec) + " in " + root.monthData.label : ""
              }

              Text {
                visible: root.monthData !== null && root.monthData.companies.length === 0
                text: "Nothing logged in this month."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.monthData && root.monthData.company === "all" ? root.monthData.companies : []
                delegate: RowLayout {
                  required property var modelData
                  width: parent ? parent.width : 0
                  spacing: Style.space(8)

                  ChoiceChip { label: modelData.tag; faded: modelData.archived; onClicked: root.setMonthCompany(modelData.id) }
                  Text {
                    Layout.fillWidth: true
                    text: modelData.name + " · " + Model.fmtDuration(modelData.figures.workedSec) + " · " + modelData.figures.label
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Text {
                    text: Model.fmtMoney(modelData.figures.money.net, modelData.figures.currency)
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Repeater {
                model: root.monthData && root.monthData.company === "all" ? root.monthData.invoice : []
                delegate: RowLayout {
                  required property var modelData
                  width: parent ? parent.width : 0
                  Text {
                    Layout.fillWidth: true
                    text: "To invoice"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: Model.fmtMoney(modelData.net, modelData.currency) + " + VAT"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
              }
            }

            // Hours by day or by week; a bar brings its rows below into view.
            Card {
              visible: root.monthData !== null

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: "Hours"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                ChoiceChip { label: "By day"; on: root.monthChart === "days"; onClicked: root.monthChart = "days" }
                ChoiceChip {
                  visible: root.monthWeekSeries.length > 0
                  label: "By week"
                  on: root.monthChart === "weeks"
                  onClicked: root.monthChart = "weeks"
                }
              }

              Text {
                width: parent.width
                text: root.monthChart === "weeks" && root.monthWeekSeries.length > 0
                  ? (weeksChart.readout !== "" ? weeksChart.readout : "A bar shows that week's days below")
                  : (daysChart.readout !== "" ? daysChart.readout
                    : (root.monthData ? Model.dayMonth(root.monthData.start) + " to " + Model.dayMonth(root.monthData.end) + " · a bar shows its day below" : ""))
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              WeekChart {
                id: daysChart
                visible: root.monthChart === "days"
                width: parent.width
                series: root.monthSeries.series
                markers: root.monthSeries.markers
                thinning: false
                clickable: true
                onColumnClicked: function(i) {
                  var d = root.monthData ? root.monthData.days[i] : null
                  if (d) root.revealDays(d.date, d.date, true)
                }
                target: root.monthFigures && root.monthFigures.billing === "package" && root.monthFigures.days > 0
                  ? root.monthFigures.targetSec / 3600 / root.monthFigures.days * 7 / 5 : 0
                targetSubtle: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
              }

              WeekChart {
                id: weeksChart
                visible: root.monthChart === "weeks"
                width: parent.width
                implicitHeight: Style.space(72)
                series: root.monthWeekSeries
                clickable: true
                onColumnClicked: function(i) { root.revealWeek(i) }
                target: root.monthCompany !== "all" ? root.monthGuideHours : 0
                targetLabel: root.monthCompany !== "all" && root.monthGuideHours > 0 ? Model.fmtHours(root.monthGuideHours) : ""
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
              }

              // What the lines on the chart are.
              Text {
                width: parent.width
                visible: text !== ""
                text: {
                  if (root.monthChart === "weeks" && root.monthWeekSeries.length > 0)
                    return root.monthCompany !== "all" && root.monthGuideHours > 0 ? "Dashed line: the weekly guide, " + Model.fmtHours(root.monthGuideHours) : ""
                  var parts = []
                  if (daysChart.target > 0) parts.push("Dashed line: " + Model.fmtHours(daysChart.target) + " a weekday")
                  if (root.monthSeries.markers.length > 0) parts.push("dotted upright line: new terms start")
                  return parts.join(" · ")
                }
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Every day, its sessions under it; the actions sit above the list.
            RowLayout {
              visible: root.monthData !== null
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "Days"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Button {
                text: "Add time"
                iconText: "󰐕"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "n: on the selected day"
                onClicked: {
                  var r = root.monthRows[root.monthCursor]
                  var today = Model.localDateKey(root.nowMs)
                  root.newEntry(r ? r.date : (root.monthData.end < today ? root.monthData.end : today))
                }
              }
              Button {
                text: "Export"
                iconText: "󰈔"
                foreground: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "The report for the client: CSV, Markdown and HTML in " + (root.svc ? root.svc.exportDir.replace(Quickshell.env("HOME"), "~") : "") + " (x)"
                onClicked: root.svc.exportPeriod("month", root.monthKey, root.monthCompany, null)
              }
            }

            Text {
              visible: root.monthData !== null
              width: parent.width
              text: "Click a session to edit it; + on a day adds time on that day."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              visible: root.monthData !== null
              width: parent.width
              height: monthList.implicitHeight
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)

              Column {
                id: monthList
                width: parent.width
                spacing: Style.space(2)

                Repeater {
                  id: monthRowRepeater
                  model: root.monthRows
                  delegate: Rectangle {
                    id: monthRow
                    required property var modelData
                    required property int index
                    readonly property bool isDay: modelData.kind === "day"
                    readonly property bool selected: index === root.monthCursor
                    onSelectedChanged: if (selected) root.ensureVisible(monthRow)
                    readonly property bool today: modelData.date === Model.localDateKey(root.nowMs)
                    readonly property bool weekend: { var d = new Date(modelData.date + "T12:00:00").getDay(); return d === 0 || d === 6 }
                    width: monthList.width
                    height: isDay ? Style.space(28) : Style.space(40)
                    radius: Style.cornerRadius
                    readonly property bool flashing: root.flashFrom !== "" && modelData.date >= root.flashFrom && modelData.date <= root.flashTo
                    // Day rows carry an accent tint so each day reads as the head of
                    // its sessions; today and the selected day a stronger one.
                    color: flashing ? Util.alpha(root.accent, 0.42)
                      : (isDay ? Util.alpha(root.accent, selected ? 0.34 : (today ? 0.26 : 0.16))
                        : (selected ? Style.selectedFill : (rowHover.hovered ? root.hoverFill : "transparent")))
                    Behavior on color { ColorAnimation { duration: 260 } }

                    HoverHandler { id: rowHover }

                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: monthRow.isDay ? Qt.ArrowCursor : Qt.PointingHandCursor
                      onClicked: {
                        root.monthCursor = monthRow.index
                        if (!monthRow.isDay) root.editSession(monthRow.modelData.session)
                      }
                    }

                    // Day row: the date, its total, + on hover.
                    RowLayout {
                      visible: monthRow.isDay
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(6)
                      spacing: Style.space(8)

                      Text {
                        Layout.fillWidth: true
                        text: Model.dayLabel(monthRow.modelData.date) + (monthRow.isDay && monthRow.modelData.day.termsStart ? "  ·  new terms" : "")
                        textFormat: Text.PlainText
                        color: monthRow.weekend ? root.dim : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: monthRow.today
                      }
                      Text {
                        text: {
                          if (!monthRow.isDay) return ""
                          var day = monthRow.modelData.day
                          var sec = day.workedSec + (root.view ? Model.dayOpenSec(root.monthData, root.view, root.nowMs, monthRow.modelData.date) : 0)
                          return sec > 0 ? Model.fmtDuration(sec) : ""
                        }
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      PanelActionButton {
                        Layout.preferredWidth: Style.space(22)
                        opacity: rowHover.hovered || monthRow.selected ? 1 : 0
                        iconText: "󰐕"
                        tooltipText: "Add time on this day (n)"
                        foreground: root.dim
                        hoverColor: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: { root.monthCursor = monthRow.index; root.newEntry(monthRow.modelData.date) }
                      }
                    }

                    // Session row: times and hours, the summary under them.
                    ColumnLayout {
                      visible: !monthRow.isDay
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(28)
                      anchors.rightMargin: Style.space(10)
                      spacing: 0

                      Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(3)
                        text: monthRow.isDay ? "" : (root.monthCompany === "all" && root.several && root.companyInfo(monthRow.modelData.session.company)
                            ? root.companyInfo(monthRow.modelData.session.company).tag + " · " : "")
                          + Model.localHM(monthRow.modelData.session.start) + " to " + Model.localHM(monthRow.modelData.session.end)
                          + " · " + Model.fmtDuration(monthRow.modelData.session.workedSec)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: monthRow.selected
                        elide: Text.ElideRight
                      }
                      Text {
                        Layout.fillWidth: true
                        text: monthRow.isDay ? "" : Model.clip(Model.firstLine(monthRow.modelData.session.summary), 200)
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelToolTip {
                      visible: !monthRow.isDay && rowHover.hovered
                      text: monthRow.isDay ? "" : Model.sessionTip(monthRow.modelData.session,
                        root.several ? root.companyInfo(monthRow.modelData.session.company) ? root.companyInfo(monthRow.modelData.session.company).name : "" : "")
                      fontFamily: root.fontFamily
                    }
                  }
                }
              }
            }


          }

          // ---------------------------------------------------- companies

          Column {
            visible: root.page === "companies" && root.ready && root.companiesMode === "list"
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: companyList.implicitHeight
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)

              Column {
                id: companyList
                width: parent.width

                Repeater {
                  model: root.companyRows
                  delegate: Rectangle {
                    id: companyRowItem
                    required property var modelData
                    required property int index
                    readonly property bool isCompany: modelData.kind === "company"
                    readonly property var c: modelData.company
                    readonly property bool selected: index === root.companyCursor
                    onSelectedChanged: if (selected) root.ensureVisible(companyRowItem)
                    readonly property bool inForce: !isCompany && c.inForce !== null && c.inForce.from === modelData.period.from
                    width: companyList.width
                    height: isCompany ? Style.space(48) : Style.space(36)
                    radius: Style.cornerRadius
                    color: selected ? Style.selectedFill : (companyMouse.containsMouse ? root.hoverFill : "transparent")
                    opacity: c.archived ? 0.7 : 1

                    MouseArea {
                      id: companyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        // A click selects; a click on the selected row edits it.
                        if (companyRowItem.selected) root.activateCompanyRow()
                        else root.selectCompanyRow(companyRowItem.index)
                      }
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: companyRowItem.isCompany ? Style.space(8) : Style.space(46)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(8)

                      Rectangle {
                        visible: companyRowItem.isCompany
                        Layout.preferredWidth: Style.space(30)
                        Layout.preferredHeight: Style.space(30)
                        radius: Style.cornerRadius
                        color: root.svc && companyRowItem.c.id === root.svc.currentCompany ? Style.selectedAccentFill : Style.normalFillFor(root.foreground, root.accent)

                        Text {
                          anchors.centerIn: parent
                          text: "󰒔"
                          color: root.svc && companyRowItem.c.id === root.svc.currentCompany ? root.accent : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.icon
                        }
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                          Layout.fillWidth: true
                          text: companyRowItem.isCompany
                            ? companyRowItem.c.name + " · " + companyRowItem.c.tag + (root.svc && companyRowItem.c.id === root.svc.currentCompany ? "  ·  current" : "")
                            : "from " + Model.dayMonth(companyRowItem.modelData.period.from, true) + " · " + Model.termsLine(companyRowItem.modelData.period)
                              + (companyRowItem.modelData.period.weeklyGuideHours > 0 ? " · " + companyRowItem.modelData.period.weeklyGuideHours + "h/week guide" : "")
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: companyRowItem.isCompany ? Style.font.body : Style.font.caption
                          font.bold: companyRowItem.isCompany ? companyRowItem.selected : companyRowItem.inForce
                          elide: Text.ElideRight
                        }
                        Text {
                          visible: companyRowItem.isCompany
                          Layout.fillWidth: true
                          text: !companyRowItem.isCompany ? "" : (companyRowItem.c.archived ? "archived"
                            : (companyRowItem.c.inForce ? Model.termsLine(companyRowItem.c.inForce) + " · from " + Model.dayMonth(companyRowItem.c.inForce.from, true) : "no terms today")
                              + " · " + Model.cycleName(companyRowItem.c.cycleDay))
                          textFormat: Text.PlainText
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Add company"
                iconText: "󰐕"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "a"
                onClicked: root.editCompany(null)
              }
              Button {
                visible: root.selectedCompany !== null
                text: "New terms"
                iconText: "󰐕"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "p: a period of terms for " + (root.selectedCompany ? root.selectedCompany.name : "") + " from a date"
                onClicked: root.editPeriod(root.selectedCompany, null)
              }
              Button {
                visible: root.selectedCompany !== null && !root.selectedCompany.archived && root.selectedCompany.id !== root.svc.currentCompany
                text: "Use"
                iconText: "󰄬"
                foreground: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "u: the next session is for this company"
                onClicked: root.svc.useCompany(root.selectedCompany.id, null)
              }
              Button {
                visible: root.selectedCompany !== null && root.selectedCompany.archived
                text: "Unarchive"
                foreground: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.svc.company("unarchive", { id: root.selectedCompany.id }, null)
              }
            }

          }

          // Company form.
          Card {
            visible: root.page === "companies" && root.companiesMode === "company"

            Text { text: "Name"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            KeyField {
              id: companyNameField
              radius: Style.cornerRadius
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 40
              placeholderText: "Acme Studio"
              onUnhandledKey: function(event) { root.formKey(companyNameField, event) }
            }

            Text { text: "Tag (on the pill and in lists)"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            KeyField {
              id: companyTagField
              radius: Style.cornerRadius
              width: Style.space(90)
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 4
              placeholderText: "AS"
              uppercase: true
              onUnhandledKey: function(event) { root.formKey(companyTagField, event) }
            }

            Text { text: "Billing cycle starts on day"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            KeyField {
              id: companyCycleField
              radius: Style.cornerRadius
              allowed: /[0-9]/
              width: Style.space(90)
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 2
              onUnhandledKey: function(event) { root.formKey(companyCycleField, event) }
            }
            Text {
              width: parent.width
              text: "1 = calendar month; 21 = the 21st to the 20th. Changing it re-cuts every cycle of this company."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.formError !== ""
              text: root.formError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: root.formCompanyId === "" ? "Add" : "Save"
                iconText: "󰄬"
                active: true
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "Ctrl+Enter"
                onClicked: root.saveCompany()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: { root.companiesMode = "list"; keyCatcher.forceActiveFocus() }
              }
              Item { Layout.fillWidth: true }
            }
          }

          // Contract period form.
          Card {
            visible: root.page === "companies" && root.companiesMode === "contract"

            Text { text: "From (the first day these terms apply)"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              KeyField {
                id: termsFromField
                radius: Style.cornerRadius
                allowed: /[0-9-]/
                Layout.preferredWidth: Style.space(130)
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 10
                placeholderText: "2026-10-21"
                onUnhandledKey: function(event) { root.formKey(termsFromField, event) }
              }
              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "One cycle earlier"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  var c = root.companyInfo(root.formCompanyId)
                  if (c && root.termsCheck.field !== "from") termsFromField.text = Model.cycleBounds(c.cycleDay, Model.shiftCycle(Model.cycleOf(c.cycleDay, root.termsDraft.from), -1)).first
                }
              }
              PanelActionButton {
                iconText: "󰅂"
                tooltipText: "One cycle later"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  var c = root.companyInfo(root.formCompanyId)
                  if (c && root.termsCheck.field !== "from") termsFromField.text = Model.cycleBounds(c.cycleDay, Model.shiftCycle(Model.cycleOf(c.cycleDay, root.termsDraft.from), 1)).first
                }
              }
              Item { Layout.fillWidth: true }
            }
            Text {
              width: parent.width
              visible: text !== ""
              text: root.termsCaption
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text { text: "Billing"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.space(6)
              ChoiceChip { label: "Package"; on: root.termsBilling === "package"; onClicked: root.termsBilling = "package" }
              ChoiceChip { label: "Hourly"; on: root.termsBilling === "hourly"; onClicked: root.termsBilling = "hourly" }
            }

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(10)
              rowSpacing: Style.space(4)

              Text { visible: root.termsBilling === "package"; text: "Hours a cycle"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { visible: root.termsBilling === "package"; text: "Fee a cycle, before VAT"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              KeyField {
                id: termsHoursField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                visible: root.termsBilling === "package"
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 6
                onUnhandledKey: function(event) { root.formKey(termsHoursField, event) }
              }
              KeyField {
                id: termsFeeField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                visible: root.termsBilling === "package"
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 10
                onUnhandledKey: function(event) { root.formKey(termsFeeField, event) }
              }

              Text { text: "Standard rate an hour"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: "VAT %"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              KeyField {
                id: termsRateField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 8
                onUnhandledKey: function(event) { root.formKey(termsRateField, event) }
              }
              KeyField {
                id: termsVatField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 5
                onUnhandledKey: function(event) { root.formKey(termsVatField, event) }
              }

              Text { visible: root.termsBilling === "package"; text: "Extra hour rate (over the package)"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Item { visible: root.termsBilling === "package"; width: 1; height: 1 }
              KeyField {
                id: termsExtraField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                visible: root.termsBilling === "package"
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 8
                onUnhandledKey: function(event) { root.formKey(termsExtraField, event) }
              }
              Item { visible: root.termsBilling === "package"; width: 1; height: 1 }

              Text { text: "Weekly guide, hours (0 = none)"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: "Currency"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              KeyField {
                id: termsGuideField
                radius: Style.cornerRadius
                allowed: /[0-9.]/
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 4
                onUnhandledKey: function(event) { root.formKey(termsGuideField, event) }
              }
              KeyField {
                id: termsCurrencyField
                Layout.fillWidth: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 4
                onUnhandledKey: function(event) { root.formKey(termsCurrencyField, event) }
              }
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: root.formError !== "" ? root.formError : (root.termsCheck.error !== "" ? root.termsCheck.field + ": " + root.termsCheck.error : "")
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: "Save"
                iconText: "󰄬"
                active: true
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "Ctrl+Enter"
                onClicked: root.savePeriod()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: { root.companiesMode = "list"; keyCatcher.forceActiveFocus() }
              }
              Item { Layout.fillWidth: true }
              Button {
                visible: root.formFrom !== "" && root.companyInfo(root.formCompanyId) !== null && root.companyInfo(root.formCompanyId).contracts.length > 1
                text: "Delete"
                foreground: hot ? root.urgent : root.dim
                accent: root.urgent
                fontFamily: root.fontFamily
                onClicked: {
                  root.confirmAction = "deletePeriod"
                  var c = root.companyInfo(root.formCompanyId)
                  dialog.message = "Delete the terms from " + Model.dayMonth(root.formFrom, true) + "? The cycles from "
                    + Model.cycleLabel(c.cycleDay, Model.cycleOf(c.cycleDay, root.formFrom)) + " on fall back to the previous terms."
                  dialog.confirmText = "Delete"
                  dialog.selectedIndex = 0
                  dialog.opened = true
                }
              }
            }
          }


          // ---------------------------------------------------- review / editor

          SessionEditor {
            id: editor
            visible: root.page === "review" || root.page === "editor"
            width: parent.width
            mode: root.page === "review" ? "review" : root.editorMode
            foreground: root.foreground
            accent: root.accent
            urgent: root.urgent
            fontFamily: root.fontFamily
            suggestions: root.view ? root.view.tags : []
            companies: root.view ? root.view.companies : []
            canRunOn: root.sessionState === "idle"
            nowMs: root.nowMs
            onSubmitted: function(segments, summary, tags, running) { root.submitEditor(segments, summary, tags, running && root.sessionState === "idle") }
            onCancelled: root.cancelEditor()
            onDestroyRequested: root.askDestroy()
            onDraftEdited: function(summary, tags) { if (root.page === "review") root.svc.saveDraft(summary, tags) }
            onEscapePressed: keyCatcher.forceActiveFocus()
          }


          // ---------------------------------------------------- history

          Column {
            visible: root.page === "history"
            width: parent.width
            spacing: Style.space(12)

            Text {
              visible: root.historyRows.length > 0
              width: parent.width
              text: "Click a session to edit or delete it."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.historyRows.length === 0
              text: "Nothing logged this week. 󰅁 goes to earlier weeks."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              topPadding: Style.space(6)
            }

            Rectangle {
              visible: root.historyRows.length > 0
              width: parent.width
              height: historyColumn.implicitHeight
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)

              Column {
                id: historyColumn
                width: parent.width

                Repeater {
                  model: root.historyRows
                  delegate: SessionRow {
                    id: historyRow
                    required property var modelData
                    required property int index
                    session: modelData
                    selected: index === root.cursor
                    onSelectedChanged: if (selected) root.ensureVisible(historyRow)
                    onActivated: { root.cursor = index; root.editSession(modelData) }
                  }
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Add time"
                iconText: "󰐕"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.newEntry()
              }
              Item { Layout.fillWidth: true }
              Button {
                text: "Export week"
                iconText: "󰈔"
                foreground: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "CSV, Markdown and HTML in " + (root.svc ? root.svc.exportDir.replace(Quickshell.env("HOME"), "~") : "")
                onClicked: root.svc.exportPeriod("week", root.historyWeek, "", null)
              }
              Button {
                text: "Month"
                iconText: "󰃭"
                foreground: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
                tooltipText: "The cycle of this week: every day, the package, the monthly report (m)"
                onClicked: root.openHistoryMonth()
              }
            }

          }
        }
      }

      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? implicitHeight : 0
        visible: root.footerKeys.length > 0
        spacing: Style.space(10)

        PanelSeparator { width: parent.width; foreground: root.foreground }
        Hints { keys: root.footerKeys }
      }

      ConfirmDialog {
        id: dialog
        anchors.fill: parent
        z: 10
        foreground: root.foreground
        background: Commons.Color.popups.background
        fontFamily: root.fontFamily
        onCanceled: { dialog.opened = false; keyCatcher.forceActiveFocus() }
        onConfirmed: root.runConfirmed()
      }
    }
  }
}
