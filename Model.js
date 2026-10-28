// Pure helpers shared by Service.qml, Panel.qml and the editor: formatting,
// live totals on top of the helper's view, chart geometry and the editor's
// segment checks (same rules as worklog.py, so the form and the helper agree).
// Tested with `node --test tests/`.

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var MIN_SEGMENT_SEC = 60

function pad2(n) { return (n < 10 ? "0" : "") + n }

// 4h 12m, 4h, 47m, 0m. Negative values keep their sign.
function fmtDuration(sec) {
  sec = Math.round(Number(sec) || 0)
  if (sec < 0) return "-" + fmtDuration(-sec)
  var m = Math.floor(sec / 60)
  var h = Math.floor(m / 60)
  m = m % 60
  if (h && m) return h + "h " + pad2(m) + "m"
  if (h) return h + "h"
  return m + "m"
}

// The pill clock: 0:07, 1:23, 12:05 (hours and minutes).
function fmtClock(sec) {
  sec = Math.max(0, Math.floor(Number(sec) || 0))
  var m = Math.floor(sec / 60)
  return Math.floor(m / 60) + ":" + pad2(m % 60)
}

// Hours for chart readouts: 3.5 -> "3h 30m".
function fmtHours(hours) { return fmtDuration(hours * 3600) }

// Spanish money format, as the reports write it: 1.800 €, 37,50 €.
function fmtMoney(value, currency, decimals) {
  if (value === null || value === undefined || !isFinite(value)) return "–"
  var d = decimals === undefined ? (Math.round(value) === value ? 0 : 2) : decimals
  var fixed = Math.abs(value).toFixed(d)
  var parts = fixed.split(".")
  var whole = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ".")
  return (value < 0 ? "-" : "") + whole + (parts[1] ? "," + parts[1] : "") + " " + (currency || "€")
}

function fmtPercent(value) {
  var v = Math.round(Number(value) * 10) / 10
  return String(v).replace(".", ",") + " %"
}

function parseIso(iso) {
  if (!iso) return NaN
  return Date.parse(iso)
}

function isoOf(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z")
}

// Local "14:02" of an ISO instant.
function localHM(iso) {
  var d = new Date(parseIso(iso))
  if (isNaN(d.getTime())) return "--:--"
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// Local date key "2026-10-27" of an instant (ms).
function localDateKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function dateFromKey(key) {
  var p = String(key).split("-")
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
}

// "Tue 27 Oct" for a date key.
function dayLabel(key) {
  var d = dateFromKey(key)
  if (isNaN(d.getTime())) return ""
  return DAY_NAMES[d.getDay()] + " " + d.getDate() + " " + MONTH_NAMES[d.getMonth()]
}

function shortDay(key) {
  var d = dateFromKey(key)
  return isNaN(d.getTime()) ? "" : DAY_NAMES[d.getDay()]
}

function monthLabel(key) {
  var p = String(key).split("-")
  var names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  return names[Number(p[1]) - 1] + " " + p[0]
}

function addDays(key, n) {
  var d = dateFromKey(key)
  d.setDate(d.getDate() + n)
  return localDateKey(d.getTime())
}

// "27 Oct – 2 Nov" for a Monday key.
function weekRange(mondayKey) {
  var a = dateFromKey(mondayKey)
  var b = dateFromKey(addDays(mondayKey, 6))
  return a.getDate() + " " + MONTH_NAMES[a.getMonth()] + " – " + b.getDate() + " " + MONTH_NAMES[b.getMonth()]
}

// "11:00", "9", "930", "9.30" -> minutes after midnight, or -1.
function parseClock(text) {
  var t = String(text || "").trim().replace(/[.h]/, ":")
  var m = /^(\d{1,2})(?::?(\d{2}))?$/.exec(t)
  if (!m) return -1
  var h = Number(m[1])
  var min = m[2] === undefined ? 0 : Number(m[2])
  if (h > 23 || min > 59) return -1
  return h * 60 + min
}

// Local date key + minutes after midnight -> ISO instant (DST safe: the
// Date constructor resolves local wall time).
function isoFromLocal(dateKey, minutes) {
  var d = dateFromKey(dateKey)
  d.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0)
  return isoOf(d.getTime())
}

function minutesOfDay(iso) {
  var d = new Date(parseIso(iso))
  return d.getHours() * 60 + d.getMinutes()
}

// ------------------------------------------------------------- live totals

// Seconds of the open segment that fall after `periodStartIso` (0 when no
// segment is open). The helper's totals count closed time only.
function openSec(view, nowMs, periodStartIso) {
  if (!view || !view.active || !view.active.openStart || view.state !== "running") return 0
  var start = parseIso(view.active.openStart)
  if (periodStartIso) start = Math.max(start, parseIso(periodStartIso))
  return Math.max(0, Math.floor((nowMs - start) / 1000))
}

// Seconds of the open segment inside [startMs, endMs).
function openSecBetween(view, nowMs, startMs, endMs) {
  if (!view || !view.active || !view.active.openStart || view.state !== "running") return 0
  var a = Math.max(parseIso(view.active.openStart), startMs)
  var b = Math.min(nowMs, endMs)
  return Math.max(0, Math.floor((b - a) / 1000))
}

function dayStartMs(key) { return parseIso(isoFromLocal(key, 0)) }

// The live session belongs to the company the track page shows.
function liveIsCurrent(view) {
  return !!(view && view.active && (!view.currentCompany || view.active.company === view.currentCompany))
}

function openSecMine(view, nowMs, periodStartIso) {
  return liveIsCurrent(view) ? openSec(view, nowMs, periodStartIso) : 0
}

function sessionWorkedSec(view, nowMs) {
  if (!view || !view.active) return 0
  return view.active.closedSec + openSec(view, nowMs, null)
}

// Paused time of the live session, the running pause included.
function sessionPausedSec(view, nowMs) {
  if (!view || !view.active) return 0
  var paused = view.active.pausedSec
  if (view.state === "paused" && view.active.lastEnd) paused += Math.max(0, Math.floor((nowMs - parseIso(view.active.lastEnd)) / 1000))
  return paused
}

function currentPauseSec(view, nowMs) {
  if (!view || view.state !== "paused" || !view.active || !view.active.lastEnd) return 0
  return Math.max(0, Math.floor((nowMs - parseIso(view.active.lastEnd)) / 1000))
}

function weekLive(view, nowMs) {
  var w = view.week
  var worked = w.workedSec + openSecMine(view, nowMs, w.startAt)
  var remaining = Math.max(0, w.targetSec - worked)
  return {
    workedSec: worked,
    targetSec: w.targetSec,
    remainingSec: remaining,
    daysLeft: w.daysLeft,
    perDaySec: w.daysLeft > 0 ? Math.ceil(remaining / w.daysLeft) : remaining,
    done: w.targetSec > 0 && worked >= w.targetSec
  }
}

// Half up to the cent, as worklog.py cents: the hundredths are rounded to six
// places first, so 10,05 at 10 % (100.4999... hundredths in binary) gives 1,01.
function round2(v) { return Math.floor(Number((v * 100).toFixed(6)) + 0.5) / 100 }

// Same formula as worklog.py money(): what a cycle bills for `workedSec`.
// The seconds the parts do not hold yet (the live segment) count in the
// live part. A package bills the hours over it at the extra hour rate unless
// the cycle waives them, and compares the total with the standard rate on
// the hours owed until worked passes them; hourly and mixed have no discount.
function money(fig, workedSec) {
  var parts = fig.parts || []
  var worked = []
  var held = 0
  for (var i = 0; i < parts.length; i++) { worked.push(parts[i].workedSec); held += parts[i].workedSec }
  if (parts.length && workedSec !== held) worked[fig.livePart !== undefined ? fig.livePart : parts.length - 1] += workedSec - held
  var lines = []
  var net = 0
  var vat = 0
  for (var j = 0; j < parts.length; j++) {
    var p = parts[j]
    var n = p.billing === "package" ? p.fee : (p.billing === "hourly" ? round2(worked[j] / 3600 * p.standardRate) : 0)
    var v = round2(n * p.vatPercent / 100)
    lines.push({ from: p.from, to: p.to, billing: p.billing, workedSec: worked[j], net: n, vat: v, vatPercent: p.vatPercent, standardRate: p.standardRate })
    net += n
    vat += v
  }
  var fee = round2(net)
  net = fee
  vat = round2(vat)
  var out = {
    billing: fig.billing, fee: fee, lines: lines, projected: false, standardValue: null, discount: null,
    discountPercent: null, effectiveRate: null, overSec: 0, overageRate: 0, overageNet: 0, overageWaived: false
  }
  if (fig.billing === "package") {
    var hours = workedSec / 3600
    var owed = fig.targetSec / 3600
    var overSec = Math.max(0, Math.floor(workedSec) - fig.targetSec)
    var rate = fig.overageRate !== undefined ? fig.overageRate : fig.standardRate
    var overNet = round2(overSec / 3600 * rate)
    if (overNet && !fig.waived) {
      net = round2(net + overNet)
      vat = round2(vat + round2(overNet * (fig.overageVat || 0) / 100))
    }
    var basis = Math.max(hours, owed)
    var value = basis * fig.standardRate
    var discount = Math.max(0, value - net)
    out.projected = hours < owed
    out.standardValue = round2(value)
    out.discount = round2(discount)
    out.discountPercent = value > 0 ? Math.floor(1000 * discount / value + 0.5) / 10 : 0
    out.effectiveRate = basis > 0 ? round2(net / basis) : null
    out.overSec = overSec
    out.overageRate = rate
    out.overageNet = overNet
    out.overageWaived = !!fig.waived
  }
  out.net = net
  out.vat = vat
  out.gross = round2(net + vat)
  return out
}

// A cycle's figures with the live segment added (the track page's month
// card and the month page's package card). `fig` from the helper.
function cycleLive(fig, openSecValue, openByPart) {
  var worked = fig.workedSec + (openSecValue || 0)
  // The live seconds per terms part, when known: a segment running across a
  // change of terms is billed on both sides of it.
  if (openByPart && fig.parts) {
    fig = Object.assign({}, fig, { parts: fig.parts.map(function(p, k) {
      return Object.assign({}, p, { workedSec: p.workedSec + (openByPart[k] || 0) })
    }) })
  }
  return {
    workedSec: worked,
    targetSec: fig.targetSec,
    remainingSec: Math.max(0, fig.targetSec - worked),
    expectedSec: fig.expectedSec,
    balanceSec: worked - fig.expectedSec,
    daysLeft: fig.daysLeft,
    billing: fig.billing,
    parts: fig.parts,
    currency: fig.currency,
    finished: fig.daysLeft === 0,
    money: money(fig, worked)
  }
}

function monthLive(view, nowMs) {
  var open = openSecMine(view, nowMs, view.month.startAt)
  return cycleLive(view.month, open, open > 0 ? openSecByPart(view.month, view, nowMs) : null)
}

// The live segment's seconds inside each terms part of a cycle; a part runs
// from local midnight of its first day to local midnight after its last.
function openSecByPart(fig, view, nowMs) {
  return (fig.parts || []).map(function(p) {
    return openSecBetween(view, nowMs, dayStartMs(p.from), dayStartMs(addDays(p.to, 1)))
  })
}

// "9h 40m of 12h · 2h 20m left · 3 days left · 47m a day"; no guide: hours only.
function weekLine(live) {
  if (!(live.targetSec > 0)) return fmtDuration(live.workedSec) + " this week"
  var head = fmtDuration(live.workedSec) + " of " + fmtDuration(live.targetSec)
  if (live.done) return head + " · done"
  var days = live.daysLeft === 1 ? "1 day left" : live.daysLeft + " days left"
  return head + " · " + fmtDuration(live.remainingSec) + " left · " + days + " · " + fmtDuration(live.perDaySec) + " a day"
}

function paceLine(live) {
  var b = live.balanceSec
  if (Math.abs(b) < 15 * 60) return "on pace"
  return (b > 0 ? "ahead " : "behind ") + fmtDuration(Math.abs(b))
}

// Every line of an hourly cycle at the same rate and VAT (one sentence
// says it all); otherwise each part gets its own line.
function uniformHourly(m) {
  if (!m || m.billing !== "hourly" || !m.lines.length) return false
  for (var i = 1; i < m.lines.length; i++)
    if (m.lines[i].standardRate !== m.lines[0].standardRate || m.lines[i].vatPercent !== m.lines[0].vatPercent) return false
  return true
}

// The package line of a cycle: running, finished short or over, hourly, none.
function monthLine(live) {
  var days = live.daysLeft === 1 ? "1 day left" : live.daysLeft + " days left"
  if (live.billing === "hourly") {
    if (!uniformHourly(live.money)) return fmtDuration(live.workedSec) + " · " + fmtMoney(live.money.net, live.currency)
    return fmtDuration(live.workedSec) + " · " + fmtMoney(live.money.net, live.currency) + " at " + fmtMoney(live.money.lines[0].standardRate, live.currency) + "/h"
  }
  if (live.billing === "none") return fmtDuration(live.workedSec) + " · no terms"
  var head = fmtDuration(live.workedSec) + " of " + fmtDuration(live.targetSec)
  if (!live.finished) return head + " · " + fmtDuration(live.remainingSec) + " left · " + days
  var diff = live.workedSec - live.targetSec
  if (Math.abs(diff) < 60) return head + " · done"
  return head + " · " + (diff > 0 ? "+" + fmtDuration(diff) + " over the package" : fmtDuration(-diff) + " short")
}

// The track page's money line: what the cycle invoices so far and how, as
// { label, amount }; the month page shows the whole breakdown.
function moneySummary(live) {
  var m = live.money
  var cur = live.currency
  if (live.billing === "none") return { label: "No terms for this cycle", amount: "" }
  if (live.billing === "package")
    return { label: (m.overSec > 0 && !m.overageWaived ? "Package + extra" : "Package")
      + (m.effectiveRate !== null ? " · " + fmtMoney(m.effectiveRate, cur, 2) + "/h" : ""), amount: fmtMoney(m.net, cur) }
  if (uniformHourly(m)) return { label: fmtDuration(live.workedSec) + " at " + fmtMoney(m.lines[0].standardRate, cur) + "/h", amount: fmtMoney(m.net, cur) }
  return { label: "To invoice", amount: fmtMoney(m.net, cur) + " + VAT" }
}

// ------------------------------------------------------------- cycles

function daysInMonth(y, m) { return new Date(y, m, 0).getDate() }  // m: 1..12

function shiftMonth(y, m, n) {
  var k = y * 12 + (m - 1) + n
  return { y: Math.floor(k / 12), m: k % 12 + 1 }
}

function monthKey(y, m) { return y + "-" + pad2(m) }

function cycleFirst(cycleDay, y, m) { return monthKey(y, m) + "-" + pad2(Math.min(cycleDay, daysInMonth(y, m))) }

// { first, last } date keys of the cycle that starts in month `key`.
function cycleBounds(cycleDay, key) {
  var p = String(key).split("-")
  var y = Number(p[0])
  var m = Number(p[1])
  var n = shiftMonth(y, m, 1)
  return { first: cycleFirst(cycleDay, y, m), last: addDays(cycleFirst(cycleDay, n.y, n.m), -1) }
}

// Key of the cycle holding the date key.
function cycleOf(cycleDay, dateKey) {
  var p = String(dateKey).split("-")
  var y = Number(p[0])
  var m = Number(p[1])
  if (dateKey >= cycleFirst(cycleDay, y, m)) return monthKey(y, m)
  var prev = shiftMonth(y, m, -1)
  return monthKey(prev.y, prev.m)
}

function shiftCycle(key, n) {
  var p = String(key).split("-")
  var s = shiftMonth(Number(p[0]), Number(p[1]), n)
  return monthKey(s.y, s.m)
}

// "October 2026" for calendar cycles, else "21 Oct to 20 Nov 2026".
function cycleLabel(cycleDay, key) {
  if (cycleDay === 1) return monthLabel(key)
  var b = cycleBounds(cycleDay, key)
  var a = dateFromKey(b.first)
  var z = dateFromKey(b.last)
  if (a.getFullYear() !== z.getFullYear())
    return a.getDate() + " " + MONTH_NAMES[a.getMonth()] + " " + a.getFullYear() + " to " + z.getDate() + " " + MONTH_NAMES[z.getMonth()] + " " + z.getFullYear()
  return a.getDate() + " " + MONTH_NAMES[a.getMonth()] + " to " + z.getDate() + " " + MONTH_NAMES[z.getMonth()] + " " + z.getFullYear()
}

// "21 Oct" / "21 Oct 2026".
function dayMonth(key, withYear) {
  var d = dateFromKey(key)
  return d.getDate() + " " + MONTH_NAMES[d.getMonth()] + (withYear ? " " + d.getFullYear() : "")
}

function ordinal(n) {
  var s = (n % 100 >= 11 && n % 100 <= 13) ? "th" : ({ 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th")
  return n + s
}

function cycleName(cycleDay) { return cycleDay === 1 ? "calendar month" : "cycle " + ordinal(cycleDay) }

// ------------------------------------------------------------- companies

function companyOf(view, id) {
  var list = view && view.companies ? view.companies : []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

function companyName(view, id) {
  var c = companyOf(view, id)
  return c ? c.name : ""
}

function activeCompanies(view) {
  var out = []
  var list = view && view.companies ? view.companies : []
  for (var i = 0; i < list.length; i++) if (!list[i].archived) out.push(list[i])
  return out
}

// The element after (or before) `current` in `list`, wrapping.
function nextInList(list, current, step) {
  if (!list.length) return current
  var i = list.indexOf(current)
  return list[((i < 0 ? 0 : i + step) % list.length + list.length) % list.length]
}

// "48h · 1.800 € + VAT 21 %" or "Hourly 70 €/h + VAT 21 %".
function termsLine(t) {
  if (!t) return "no terms"
  if (t.billing === "hourly") return "Hourly " + fmtMoney(t.standardRate, t.currency) + "/h + VAT " + t.vatPercent + " %"
  return fmtDuration(t.monthlyHours * 3600) + " · " + fmtMoney(t.monthlyFee, t.currency) + " + VAT " + t.vatPercent + " %"
}

var TERM_RANGES = {
  monthlyHours: [0, 400], monthlyFee: [0, 1000000], vatPercent: [0, 100],
  standardRate: [0, 10000], weeklyGuideHours: [0, 80], overageRate: [0, 10000]
}

// The editor's check of a contract period (same rules as worklog.py
// clean_terms and parse_day). Returns { error, field }.
function checkTerms(t) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(t.from || "")) || isNaN(dateFromKey(t.from).getTime()) || localDateKey(dateFromKey(t.from).getTime()) !== t.from)
    return { error: "a date like 2026-10-21", field: "from" }
  if (t.from < "2000-01-01" || t.from > "2100-12-31") return { error: "date out of range", field: "from" }
  if (t.billing !== "package" && t.billing !== "hourly") return { error: "billing is package or hourly", field: "billing" }
  for (var key in TERM_RANGES) {
    if (t.billing === "hourly" && (key === "monthlyHours" || key === "monthlyFee" || key === "overageRate")) continue
    // Unset: worklog.py uses the standard rate.
    if (key === "overageRate" && t[key] === undefined) continue
    var v = Number(t[key])
    if (String(t[key]).trim() === "" || !isFinite(v) || v < TERM_RANGES[key][0] || v > TERM_RANGES[key][1])
      return { error: "from " + TERM_RANGES[key][0] + " to " + TERM_RANGES[key][1], field: key }
  }
  if (t.billing === "package" && !(Number(t.monthlyHours) > 0)) return { error: "a package needs hours", field: "monthlyHours" }
  var cur = String(t.currency || "").trim()
  if (cur.length < 1 || cur.length > 4) return { error: "1 to 4 characters", field: "currency" }
  return { error: "", field: "" }
}

// Hover text of a session row on the month page.
function sessionTip(s, companyNameText) {
  var segs = []
  for (var i = 0; i < s.segments.length; i++) {
    var g = s.segments[i]
    var reason = g.endReason && g.endReason !== "stop" && g.endReason !== "edited" && i < s.segments.length - 1 ? " (" + g.endReason + ")" : ""
    segs.push(localHM(g.start) + " to " + (g.end ? localHM(g.end) : "now") + reason)
  }
  var lines = [clip(String(s.summary || "").trim(), 300) || "No summary", segs.join(" · ")]
  if (s.tags && s.tags.length) lines.push(s.tags.join(", "))
  if (companyNameText) lines.push(companyNameText)
  return lines.join("\n")
}

// ------------------------------------------------------------- charts

// Axis maximum in hours: the next step of 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20…
function niceHours(max) {
  var steps = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 24, 30, 40, 50, 60, 80, 100]
  for (var i = 0; i < steps.length; i++) if (max <= steps[i]) return steps[i]
  return Math.ceil(max / 20) * 20
}

function barHeight(hours, yMax, plotHeight) {
  if (!(hours > 0) || !(yMax > 0)) return 0
  return Math.max(2, Math.min(1, hours / yMax) * plotHeight)
}

// The 7 bars of the week chart, the open segment added to today.
function daySeries(view, nowMs) {
  var out = []
  var today = view.today.date
  for (var i = 0; i < view.week.days.length; i++) {
    var d = view.week.days[i]
    // The open segment counts on every day it covers, not only today.
    var sec = d.workedSec + (liveIsCurrent(view) ? openSecBetween(view, nowMs, dayStartMs(d.date), dayStartMs(addDays(d.date, 1))) : 0)
    out.push({
      label: shortDay(d.date).charAt(0),
      readout: dayLabel(d.date) + " · " + fmtDuration(sec),
      hours: sec / 3600,
      state: d.date === today ? "current" : (d.date > today ? "future" : "past")
    })
  }
  return out
}

// The 8 bars of the trend, this week (live) last.
function weekSeries(view, nowMs) {
  var out = []
  var n = view.trend.length
  for (var i = 0; i < n; i++) {
    var t = view.trend[i]
    var last = i === n - 1
    var sec = t.workedSec + (liveIsCurrent(view) ? openSecBetween(view, nowMs, dayStartMs(t.start), dayStartMs(addDays(t.start, 7))) : 0)
    out.push({
      label: "W" + Number(t.key.split("-W")[1]),
      readout: t.key.replace("-", " ") + " · " + weekRange(t.start) + " · " + fmtDuration(sec),
      hours: sec / 3600,
      state: last ? "partial" : (t.targetSec > 0 && sec >= t.targetSec ? "met" : "past")
    })
  }
  return out
}

// The live segment's seconds that count on the month page (its company, or all).
function monthOpenSecBetween(month, view, nowMs, startMs, endMs) {
  if (!view || !view.active) return 0
  if (month.company !== "all" && view.active.company !== month.company) return 0
  return openSecBetween(view, nowMs, startMs, endMs)
}

// The live segment's seconds on one day of the month page, to the next local
// midnight (a DST day lasts 23 or 25 hours).
function dayOpenSec(month, view, nowMs, dateKey) {
  return monthOpenSecBetween(month, view, nowMs, dayStartMs(dateKey), dayStartMs(addDays(dateKey, 1)))
}

// One column per day of the month page's cycle. Labels: the first day,
// Mondays and the days new terms start; markers where terms start.
function cycleDaySeries(month, view, nowMs) {
  var series = []
  var markers = []
  var today = localDateKey(nowMs)
  for (var i = 0; i < month.days.length; i++) {
    var d = month.days[i]
    var sec = d.workedSec + monthOpenSecBetween(month, view, nowMs, dayStartMs(d.date), dayStartMs(addDays(d.date, 1)))
    var date = dateFromKey(d.date)
    if (d.termsStart && i > 0) markers.push(i)
    series.push({
      label: i === 0 || date.getDay() === 1 || d.termsStart ? String(date.getDate()) : "",
      readout: dayLabel(d.date) + " · " + fmtDuration(sec) + (d.termsStart ? " · new terms" : ""),
      hours: sec / 3600,
      state: d.date === today ? "current" : (d.date > today ? "future" : "past")
    })
  }
  return { series: series, markers: markers }
}

// The ISO weeks touching the cycle, hours inside the cycle only.
function cycleWeekSeries(month, view, nowMs) {
  var out = []
  var today = localDateKey(nowMs)
  for (var i = 0; i < month.weeks.length; i++) {
    var w = month.weeks[i]
    var a = w.start > month.start ? w.start : month.start
    var endKey = addDays(w.start, 6)
    var b = endKey < month.end ? endKey : month.end
    var sec = w.workedSec + monthOpenSecBetween(month, view, nowMs, dayStartMs(a), dayStartMs(addDays(b, 1)))
    var label = "W" + Number(w.key.split("-W")[1])
    var current = today >= w.start && today <= endKey
    out.push({
      label: label,
      readout: label + " · " + dayMonth(w.start) + " to " + dayMonth(endKey) + " · " + fmtDuration(sec)
        + (w.daysInCycle < 7 ? " (" + w.daysInCycle + (w.daysInCycle === 1 ? " day" : " days") + " in this cycle)" : ""),
      hours: sec / 3600,
      state: current ? "partial" : (w.start > today ? "future" : (w.targetSec > 0 && sec >= w.targetSec ? "met" : "past"))
    })
  }
  return out
}

// ------------------------------------------------------------- editor

// Rows the editor works with: { date, from, to, open } (minutes after
// midnight, `to` -1 while open). Built from stored segments.
function rowsFromSegments(segments) {
  var out = []
  for (var i = 0; i < segments.length; i++) {
    var s = segments[i]
    var startMs = parseIso(s.start)
    out.push({
      date: localDateKey(startMs),
      from: minutesOfDay(s.start),
      to: s.end ? minutesOfDay(s.end) : -1,
      open: !s.end,
      endReason: s.endReason || "",
      // The stored instants, kept while the row's minutes are untouched, so
      // seconds survive a review that changes nothing.
      startIso: s.start,
      endIso: s.end || ""
    })
  }
  return out
}

// The stored instant when the row still shows its minutes, else the wall
// time the row says. An end keeps its own date (a segment can run past
// midnight or for days), so only its minutes are compared.
function rowInstant(iso, dateKey, minutes, anyDate) {
  if (iso && minutesOfDay(iso) === minutes && (anyDate || localDateKey(parseIso(iso)) === dateKey)) return parseIso(iso)
  return parseIso(isoFromLocal(dateKey, minutes))
}

// Rows back to segments plus a verdict. An end earlier than the start on the
// same row means the segment crosses midnight. Segments under a minute are
// left out, as worklog.py does. Returns { segments, error, row, workedSec,
// pausedSec, first, last }.
function checkRows(rows, nowMs, allowOpen) {
  var segs = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.from < 0) return { error: "start time missing", row: i }
    var start = rowInstant(r.startIso, r.date, r.from, false)
    var end
    if (r.open) {
      if (!allowOpen || i !== rows.length - 1) return { error: "only the last segment can run on", row: i }
      end = nowMs
    } else {
      if (r.to < 0) return { error: "end time missing", row: i }
      var untouchedEnd = !!r.endIso && minutesOfDay(r.endIso) === r.to
      end = rowInstant(r.endIso, r.date, r.to, true)
      // An edited end before the start is the next day's wall time, not
      // +24 h: a DST night is 23 or 25 hours long.
      if (!untouchedEnd && (end < start || (end === start && r.to < r.from))) end = parseIso(isoFromLocal(addDays(r.date, 1), r.to))
    }
    if (start > nowMs + 60000 || end > nowMs + 60000) return { error: "segment " + (i + 1) + " is in the future", row: i }
    if (end - start < MIN_SEGMENT_SEC * 1000 && !r.open) continue
    segs.push({ start: start, end: end, open: r.open, row: i, endReason: r.endReason || "edited" })
  }
  segs.sort(function(a, b) { return a.start - b.start })
  var worked = 0
  var paused = 0
  for (var j = 0; j < segs.length; j++) {
    if (j > 0) {
      if (segs[j].start < segs[j - 1].end) return { error: "segments overlap", row: segs[j].row }
      paused += (segs[j].start - segs[j - 1].end) / 1000
    }
    worked += (segs[j].end - segs[j].start) / 1000
  }
  if (!segs.length) return { error: "nothing worked: every segment is under a minute", row: -1 }
  var out = []
  for (var k = 0; k < segs.length; k++) {
    var item = { start: isoOf(segs[k].start), end: segs[k].open ? null : isoOf(segs[k].end) }
    if (!segs[k].open) item.endReason = segs[k].endReason
    out.push(item)
  }
  return {
    segments: out,
    error: "",
    row: -1,
    workedSec: Math.round(worked),
    pausedSec: Math.round(paused),
    first: out[0].start,
    last: segs[segs.length - 1].open ? null : out[out.length - 1].end
  }
}

function parseTags(text) {
  var out = []
  var parts = String(text || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var t = parts[i].trim().replace(/\s+/g, " ").toLowerCase()
    if (t && out.indexOf(t) === -1) out.push(t)
  }
  return out
}

function clip(s, n) {
  s = String(s === undefined || s === null ? "" : s)
  return s.length > n ? s.slice(0, n - 1) + "…" : s
}

function firstLine(s) {
  var t = String(s || "").split("\n")[0].trim()
  return t
}

if (typeof module !== "undefined") {
  module.exports = {
    fmtDuration: fmtDuration,
    fmtClock: fmtClock,
    fmtHours: fmtHours,
    fmtMoney: fmtMoney,
    fmtPercent: fmtPercent,
    localHM: localHM,
    localDateKey: localDateKey,
    dayLabel: dayLabel,
    monthLabel: monthLabel,
    addDays: addDays,
    weekRange: weekRange,
    parseClock: parseClock,
    isoFromLocal: isoFromLocal,
    openSec: openSec,
    openSecBetween: openSecBetween,
    sessionWorkedSec: sessionWorkedSec,
    sessionPausedSec: sessionPausedSec,
    currentPauseSec: currentPauseSec,
    weekLive: weekLive,
    monthLive: monthLive,
    cycleLive: cycleLive,
    openSecByPart: openSecByPart,
    money: money,
    weekLine: weekLine,
    paceLine: paceLine,
    monthLine: monthLine,
    moneySummary: moneySummary,
    uniformHourly: uniformHourly,
    cycleBounds: cycleBounds,
    cycleOf: cycleOf,
    shiftCycle: shiftCycle,
    cycleLabel: cycleLabel,
    cycleName: cycleName,
    dayMonth: dayMonth,
    companyOf: companyOf,
    companyName: companyName,
    activeCompanies: activeCompanies,
    nextInList: nextInList,
    termsLine: termsLine,
    checkTerms: checkTerms,
    sessionTip: sessionTip,
    cycleDaySeries: cycleDaySeries,
    monthOpenSecBetween: monthOpenSecBetween,
    dayOpenSec: dayOpenSec,
    cycleWeekSeries: cycleWeekSeries,
    niceHours: niceHours,
    barHeight: barHeight,
    daySeries: daySeries,
    weekSeries: weekSeries,
    rowsFromSegments: rowsFromSegments,
    checkRows: checkRows,
    parseTags: parseTags,
    clip: clip,
    firstLine: firstLine
  }
}
