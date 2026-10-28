// Model.js: TZ=Europe/Madrid node --test tests/
process.env.TZ = "Europe/Madrid"
const test = require("node:test")
const assert = require("node:assert")
const M = require("../Model.js")

const NOW = Date.parse("2026-10-27T17:30:00Z") // Tue 18:30 Madrid

function pkg(from, to, days, hours, fee, worked, cycleDays) {
  var n = cycleDays || days
  return { from: from, to: to, days: days, billing: "package", monthlyHours: hours, monthlyFee: fee, vatPercent: 21,
    standardRate: 60, currency: "€", owedSec: Math.round(hours * 3600 * days / n / 60) * 60,
    fee: Math.round(fee * days / n * 100) / 100, workedSec: worked }
}

function view(over) {
  return Object.assign({
    state: "running",
    active: { closedSec: 5 * 3600, pausedSec: 3600, openStart: "2026-10-27T16:00:00Z", lastEnd: "2026-10-27T15:00:00Z" },
    today: { date: "2026-10-27", startAt: "2026-10-26T23:00:00Z", workedSec: 5 * 3600 },
    week: {
      startAt: "2026-10-25T23:00:00Z", workedSec: 6 * 3600, targetSec: 12 * 3600, daysLeft: 6,
      days: [
        { date: "2026-10-26", workedSec: 3600 }, { date: "2026-10-27", workedSec: 5 * 3600 },
        { date: "2026-10-28", workedSec: 0 }, { date: "2026-10-29", workedSec: 0 },
        { date: "2026-10-30", workedSec: 0 }, { date: "2026-10-31", workedSec: 0 }, { date: "2026-11-01", workedSec: 0 }
      ]
    },
    month: { startAt: "2026-09-30T22:00:00Z", workedSec: 20 * 3600, targetSec: 48 * 3600, days: 31, elapsedDays: 27, daysLeft: 5,
      expectedSec: Math.round(48 * 3600 * 27 / 31), billing: "package", standardRate: 60, currency: "€", livePart: 0,
      parts: [pkg("2026-10-01", "2026-10-31", 31, 48, 1800, 20 * 3600)] },
    trend: [
      { key: "2026-W43", start: "2026-10-19", workedSec: 13 * 3600, targetSec: 12 * 3600 },
      { key: "2026-W44", start: "2026-10-26", workedSec: 6 * 3600, targetSec: 12 * 3600 }
    ]
  }, over || {})
}

test("durations and clocks", () => {
  assert.strictEqual(M.fmtDuration(0), "0m")
  assert.strictEqual(M.fmtDuration(47 * 60), "47m")
  assert.strictEqual(M.fmtDuration(4 * 3600 + 12 * 60), "4h 12m")
  assert.strictEqual(M.fmtDuration(12 * 3600), "12h")
  assert.strictEqual(M.fmtDuration(-90 * 60), "-1h 30m")
  assert.strictEqual(M.fmtClock(83 * 60 + 59), "1:23")
  assert.strictEqual(M.fmtClock(7 * 60), "0:07")
})

test("money in Spanish format", () => {
  assert.strictEqual(M.fmtMoney(1800, "€"), "1.800 €")
  assert.strictEqual(M.fmtMoney(37.5, "€"), "37,50 €")
  assert.strictEqual(M.fmtMoney(2880, "€", 2), "2.880,00 €")
  assert.strictEqual(M.fmtMoney(null, "€"), "–")
  assert.strictEqual(M.fmtPercent(37.5), "37,5 %")
})

test("live totals add the open segment", () => {
  const v = view()
  assert.strictEqual(M.openSec(v, NOW, null), 1.5 * 3600)
  assert.strictEqual(M.sessionWorkedSec(v, NOW), 6.5 * 3600)
  const w = M.weekLive(v, NOW)
  assert.strictEqual(w.workedSec, 7.5 * 3600)
  assert.strictEqual(w.remainingSec, 4.5 * 3600)
  assert.strictEqual(w.perDaySec, 2700)
  assert.strictEqual(M.weekLine(w), "7h 30m of 12h · 4h 30m left · 6 days left · 45m a day")
  assert.strictEqual(M.openSec(view({ state: "paused" }), NOW, null), 0)
})

test("open segment is clipped to the period start", () => {
  const v = view({ active: { closedSec: 0, pausedSec: 0, openStart: "2026-10-26T22:00:00Z" } })
  assert.strictEqual(M.openSec(v, NOW, v.today.startAt), Math.floor((NOW - Date.parse("2026-10-26T23:00:00Z")) / 1000))
})

test("month pace and money", () => {
  const m = M.monthLive(view(), NOW)
  assert.strictEqual(m.workedSec, 21.5 * 3600)
  assert.strictEqual(m.expectedSec, Math.round(48 * 3600 * 27 / 31))
  assert.ok(m.balanceSec < 0)
  assert.match(M.paceLine(m), /^behind /)
  assert.strictEqual(m.money.standardValue, 2880)
  assert.strictEqual(m.money.discount, 1080)
  assert.strictEqual(m.money.effectiveRate, 37.5)
  assert.ok(m.money.projected)
  const fig = { targetSec: 48 * 3600, standardRate: 60, billing: "package", parts: [pkg("2026-10-01", "2026-10-31", 31, 48, 1800, 0)] }
  const over = M.money(fig, 60 * 3600)
  assert.strictEqual(over.standardValue, 3600)
  assert.strictEqual(over.overSec, 12 * 3600)
  // The 12 h over are billed at the extra hour rate (the standard rate when unset).
  assert.deepStrictEqual([over.fee, over.overageNet, over.net], [1800, 720, 2520])
  assert.strictEqual(over.effectiveRate, 42)
  const waived = M.money(Object.assign({}, fig, { waived: true, overageRate: 45, overageVat: 21 }), 60 * 3600)
  assert.deepStrictEqual([waived.overageNet, waived.net, waived.gross, waived.overageWaived], [540, 1800, 2178, true])
  const billed = M.money(Object.assign({}, fig, { overageRate: 45, overageVat: 21 }), 60 * 3600)
  assert.deepStrictEqual([billed.net, billed.vat, billed.gross], [2340, 491.4, 2831.4])
})

test("chart geometry and series", () => {
  assert.strictEqual(M.niceHours(0.4), 1)
  assert.strictEqual(M.niceHours(7), 8)
  assert.strictEqual(M.niceHours(13), 15)
  assert.strictEqual(M.barHeight(0, 8, 80), 0)
  assert.strictEqual(M.barHeight(4, 8, 80), 40)
  assert.strictEqual(M.barHeight(20, 8, 80), 80)
  const days = M.daySeries(view(), NOW)
  assert.strictEqual(days.length, 7)
  assert.strictEqual(days[1].state, "current")
  assert.strictEqual(days[1].hours, 6.5)
  assert.strictEqual(days[2].state, "future")
  assert.strictEqual(days[0].label, "M")
  const weeks = M.weekSeries(view(), NOW)
  assert.strictEqual(weeks[0].state, "met")
  assert.strictEqual(weeks[1].state, "partial")
  assert.strictEqual(weeks[1].hours, 7.5)
  assert.strictEqual(weeks[1].label, "W44")
})

test("clock parsing", () => {
  assert.strictEqual(M.parseClock("11:00"), 660)
  assert.strictEqual(M.parseClock("9"), 540)
  assert.strictEqual(M.parseClock("930"), 570)
  assert.strictEqual(M.parseClock("9.30"), 570)
  assert.strictEqual(M.parseClock("24:00"), -1)
  assert.strictEqual(M.parseClock("x"), -1)
  assert.strictEqual(M.isoFromLocal("2026-10-27", 660), "2026-10-27T10:00:00Z")
  assert.strictEqual(M.isoFromLocal("2026-07-01", 660), "2026-07-01T09:00:00Z")
})

test("editor rows: 11-16 and 17-now", () => {
  const rows = [{ date: "2026-10-27", from: 660, to: 960 }, { date: "2026-10-27", from: 1020, to: -1, open: true }]
  const r = M.checkRows(rows, NOW, true)
  assert.strictEqual(r.error, "")
  assert.strictEqual(r.workedSec, 5 * 3600 + 1.5 * 3600)
  assert.strictEqual(r.pausedSec, 3600)
  assert.deepStrictEqual(r.segments[1], { start: "2026-10-27T16:00:00Z", end: null })
  assert.strictEqual(M.checkRows(rows, NOW, false).error, "only the last segment can run on")
})

test("editor rows: errors", () => {
  const d = "2026-10-27"
  assert.strictEqual(M.checkRows([{ date: d, from: 600, to: 700 }, { date: d, from: 650, to: 720 }], NOW, false).error, "segments overlap")
  assert.match(M.checkRows([{ date: d, from: 1200, to: 1260 }], NOW, false).error, /future/)
  assert.strictEqual(M.checkRows([{ date: d, from: -1, to: 700 }], NOW, false).error, "start time missing")
  // End before start crosses midnight.
  const night = M.checkRows([{ date: "2026-10-25", from: 23 * 60, to: 60 }], NOW, false)
  assert.strictEqual(night.workedSec, 2 * 3600)
})

test("rows round-trip from segments", () => {
  const rows = M.rowsFromSegments([{ start: "2026-10-27T10:00:00Z", end: "2026-10-27T15:00:00Z", endReason: "lock" }, { start: "2026-10-27T16:00:00Z", end: null }])
  assert.deepStrictEqual(rows[0], { date: "2026-10-27", from: 660, to: 960, open: false, endReason: "lock", startIso: "2026-10-27T10:00:00Z", endIso: "2026-10-27T15:00:00Z" })
  assert.strictEqual(rows[1].open, true)
  const back = M.checkRows(rows, NOW, true)
  assert.strictEqual(back.segments[0].endReason, "lock")
})

test("labels and tags", () => {
  assert.strictEqual(M.dayLabel("2026-10-27"), "Tue 27 Oct")
  assert.strictEqual(M.weekRange("2026-10-26"), "26 Oct – 1 Nov")
  assert.strictEqual(M.monthLabel("2026-10"), "October 2026")
  assert.deepStrictEqual(M.parseTags(" Backend, review ,backend,, "), ["backend", "review"])
  assert.strictEqual(M.localHM("2026-10-27T13:02:00Z"), "14:02")
})

test("seconds survive an untouched row; short segments are left out", () => {
  const segs = [{ start: "2026-10-27T17:28:26Z", end: "2026-10-27T17:28:28Z", endReason: "manual" },
    { start: "2026-10-27T17:28:30Z", end: "2026-10-27T17:29:50Z", endReason: "stop" }]
  const r = M.checkRows(M.rowsFromSegments(segs), NOW, false)
  assert.strictEqual(r.error, "")
  assert.strictEqual(r.segments.length, 1)
  assert.strictEqual(r.segments[0].start, "2026-10-27T17:28:30Z")
  assert.strictEqual(r.segments[0].end, "2026-10-27T17:29:50Z")
  assert.match(M.checkRows(M.rowsFromSegments(segs.slice(0, 1)), NOW, false).error, /under a minute/)
  // An edited minute uses the wall time.
  const rows = M.rowsFromSegments(segs)
  rows[1].from = 17 * 60 + 30
  assert.strictEqual(M.checkRows(rows, NOW, false).segments[0].start, "2026-10-27T16:30:00Z")
})

// Review 2026-10-27 (Codex).
test("an untouched multi-day or DST segment keeps its instants", () => {
  const long = [{ start: "2026-10-25T08:00:00Z", end: "2026-10-27T10:00:00Z", endReason: "stop" }]
  const r = M.checkRows(M.rowsFromSegments(long), NOW, false)
  assert.strictEqual(r.error, "")
  assert.strictEqual(r.workedSec, 50 * 3600)
  assert.deepStrictEqual(r.segments[0], { start: long[0].start, end: long[0].end, endReason: "stop" })
  // Overnight across the DST change (25 Oct, 03:00 CEST -> 02:00 CET), with seconds.
  const night = [{ start: "2026-10-24T21:30:00Z", end: "2026-10-25T01:30:43Z", endReason: "lock" }]
  const n = M.checkRows(M.rowsFromSegments(night), NOW, false)
  assert.strictEqual(n.segments[0].end, "2026-10-25T01:30:43Z")
  assert.strictEqual(n.workedSec, 4 * 3600 + 43)
})

test("the open segment counts on every day and week it covers", () => {
  // Running since Monday 23:00 Madrid; now Tuesday 01:00.
  const now = Date.parse("2026-10-27T00:00:00Z")
  const v = view({ active: { closedSec: 0, pausedSec: 0, openStart: "2026-10-26T22:00:00Z" },
    today: { date: "2026-10-27", startAt: "2026-10-26T23:00:00Z", workedSec: 0 } })
  v.week.days = v.week.days.map(d => ({ date: d.date, workedSec: 0 }))
  v.week.workedSec = 0
  const days = M.daySeries(v, now)
  assert.strictEqual(days[0].hours, 1)
  assert.strictEqual(days[1].hours, 1)
  assert.strictEqual(M.weekLive(v, now).workedSec, 2 * 3600)
  // Running since Sunday 23:00 of the previous week.
  const w = view({ active: { closedSec: 0, pausedSec: 0, openStart: "2026-10-25T22:00:00Z" } })
  w.trend = [{ key: "2026-W43", start: "2026-10-19", workedSec: 0, targetSec: 43200 }, { key: "2026-W44", start: "2026-10-26", workedSec: 0, targetSec: 43200 }]
  const weeks = M.weekSeries(w, Date.parse("2026-10-26T00:00:00Z"))
  assert.strictEqual(weeks[0].hours, 1)
  assert.strictEqual(weeks[1].hours, 1)
})

// v2: cycles, prorated terms, companies.
test("cycles match worklog.py", () => {
  assert.deepStrictEqual(M.cycleBounds(21, "2026-10"), { first: "2026-10-21", last: "2026-11-20" })
  assert.strictEqual(M.cycleOf(21, "2026-10-20"), "2026-09")
  assert.strictEqual(M.cycleOf(21, "2026-10-21"), "2026-10")
  const seq = ["01", "02", "03", "04", "05"].map(m => M.cycleBounds(31, "2026-" + m))
  assert.deepStrictEqual(seq.map(b => b.first + "/" + b.last), ["2026-01-31/2026-02-27", "2026-02-28/2026-03-30",
    "2026-03-31/2026-04-29", "2026-04-30/2026-05-30", "2026-05-31/2026-06-29"])
  assert.strictEqual(M.cycleBounds(29, "2027-02").first, "2027-02-28")
  assert.strictEqual(M.cycleBounds(29, "2028-02").first, "2028-02-29")
  assert.deepStrictEqual(M.cycleBounds(1, "2026-02"), { first: "2026-02-01", last: "2026-02-28" })
  assert.strictEqual(M.cycleOf(31, "2026-03-30"), "2026-02")
  assert.strictEqual(M.shiftCycle("2026-12", 1), "2027-01")
  assert.strictEqual(M.shiftCycle("2026-01", -1), "2025-12")
  assert.strictEqual(M.cycleLabel(21, "2026-10"), "21 Oct to 20 Nov 2026")
  assert.strictEqual(M.cycleLabel(21, "2026-12"), "21 Dec 2026 to 20 Jan 2027")
  assert.strictEqual(M.cycleLabel(1, "2026-10"), "October 2026")
  assert.strictEqual(M.cycleName(21), "cycle 21st")
})

test("money: prorated package, hourly, mixed, none", () => {
  // Spec 2.4: a 30-day cycle, 48 h / 1.800 € then 60 h / 2.250 € from day 16.
  const parts = [pkg("2026-11-01", "2026-11-15", 15, 48, 1800, 30 * 3600, 30), pkg("2026-11-16", "2026-11-30", 15, 60, 2250, 24 * 3600, 30)]
  const fig = { targetSec: 54 * 3600, standardRate: 60, billing: "package", parts: parts, livePart: 1 }
  const m = M.money(fig, 54 * 3600)
  assert.deepStrictEqual([m.net, m.vat, m.gross, m.standardValue, m.discount], [2025, 425.25, 2450.25, 3240, 1215])
  const hourly = { billing: "hourly", targetSec: 0, livePart: 0,
    parts: [{ from: "2026-10-01", to: "2026-10-31", days: 31, billing: "hourly", vatPercent: 21, standardRate: 60, fee: 0, workedSec: 9 * 3600 }] }
  const h = M.money(hourly, 10 * 3600)  // one live hour on top
  assert.deepStrictEqual([h.net, h.gross, h.discount], [600, 726, null])
  const mixed = { billing: "mixed", targetSec: 24 * 3600, livePart: 1,
    parts: [parts[0], Object.assign({}, hourly.parts[0], { from: "2026-11-16", to: "2026-11-30", workedSec: 2 * 3600 })] }
  const x = M.money(mixed, 32 * 3600)
  assert.strictEqual(x.lines.length, 2)
  assert.strictEqual(x.net, 900 + 120)
  assert.strictEqual(x.discount, null)
  const none = M.money({ billing: "none", targetSec: 0, parts: [{ billing: "none", vatPercent: 0, standardRate: 0, fee: 0, workedSec: 3600 }] }, 3600)
  assert.strictEqual(none.net, 0)
})

test("month lines", () => {
  const base = { targetSec: 48 * 3600, expectedSec: 30 * 3600, daysLeft: 5, billing: "package", currency: "€", standardRate: 60,
    parts: [pkg("2026-10-21", "2026-11-20", 31, 48, 1800, 0)], livePart: 0 }
  assert.strictEqual(M.monthLine(M.cycleLive(Object.assign({}, base, { workedSec: 20 * 3600 }), 0)), "20h of 48h · 28h left · 5 days left")
  assert.strictEqual(M.monthLine(M.cycleLive(Object.assign({}, base, { workedSec: 44 * 3600, daysLeft: 0 }), 0)), "44h of 48h · 4h short")
  assert.strictEqual(M.monthLine(M.cycleLive(Object.assign({}, base, { workedSec: 51 * 3600, daysLeft: 0 }), 0)), "51h of 48h · +3h over the package")
  const hourly = { targetSec: 0, expectedSec: 0, daysLeft: 3, billing: "hourly", currency: "€", workedSec: 10 * 3600, livePart: 0,
    parts: [{ billing: "hourly", vatPercent: 21, standardRate: 60, fee: 0, workedSec: 10 * 3600 }] }
  assert.strictEqual(M.monthLine(M.cycleLive(hourly, 0)), "10h · 600 € at 60 €/h")
  assert.strictEqual(M.weekLine({ workedSec: 3600, targetSec: 0 }), "1h this week")
})

test("open segment counts only for its company", () => {
  const v = view({ currentCompany: "c_a", active: { company: "c_b", closedSec: 0, pausedSec: 0, openStart: "2026-10-27T16:00:00Z" } })
  assert.strictEqual(M.weekLive(v, NOW).workedSec, 6 * 3600)
  v.active.company = "c_a"
  assert.strictEqual(M.weekLive(v, NOW).workedSec, 7.5 * 3600)
})

test("terms check", () => {
  const ok = { from: "2026-11-16", billing: "package", monthlyHours: 60, monthlyFee: 2250, vatPercent: 21, standardRate: 60, weeklyGuideHours: 15, currency: "€" }
  assert.deepStrictEqual(M.checkTerms(ok), { error: "", field: "" })
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { from: "2026-02-30" })).field, "from")
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { monthlyHours: 0 })).field, "monthlyHours")
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { vatPercent: 101 })).field, "vatPercent")
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { currency: "EUROS" })).field, "currency")
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { overageRate: "x" })).field, "overageRate")
  assert.strictEqual(M.checkTerms(Object.assign({}, ok, { billing: "hourly", monthlyHours: "" })).field, "")
  assert.strictEqual(M.nextInList(["a", "b", "c"], "c", 1), "a")
  assert.strictEqual(M.nextInList(["a", "b", "c"], "a", -1), "c")
})

test("month page series", () => {
  const month = { company: "c_a", start: "2026-10-21", end: "2026-11-20",
    days: [], weeks: [{ key: "2026-W43", start: "2026-10-19", workedSec: 3600, daysInCycle: 5, targetSec: 43200 }] }
  for (let i = 0; i < 31; i++) month.days.push({ date: M.addDays("2026-10-21", i), workedSec: 0, termsStart: i === 16 })
  const v = view({ currentCompany: "c_a", active: { company: "c_a", closedSec: 0, pausedSec: 0, openStart: "2026-10-27T16:00:00Z" } })
  const d = M.cycleDaySeries(month, v, NOW)
  assert.strictEqual(d.series.length, 31)
  assert.strictEqual(d.series[0].label, "21")
  assert.strictEqual(d.series[1].label, "")
  assert.strictEqual(d.series[5].label, "26")  // Monday
  assert.deepStrictEqual(d.markers, [16])
  assert.match(d.series[16].readout, /new terms$/)
  assert.strictEqual(d.series[6].hours, 1.5)
  assert.strictEqual(d.series[6].state, "current")
  const w = M.cycleWeekSeries(month, v, NOW)
  assert.match(w[0].readout, /\(5 days in this cycle\)$/)
})

test("session tooltip", () => {
  const s = { summary: "Did it", tags: ["a"], segments: [{ start: "2026-10-27T13:02:00Z", end: "2026-10-27T14:10:00Z", endReason: "lock" },
    { start: "2026-10-27T14:28:00Z", end: "2026-10-27T17:30:00Z", endReason: "stop" }] }
  assert.strictEqual(M.sessionTip(s, "Acme Studio"), "Did it\n14:02 to 15:10 (lock) · 15:28 to 18:30\na\nAcme Studio")
})

// Codex review 2026-10-28.
test("money rounds half up to the cent, as worklog.py cents()", () => {
  const fig = { billing: "hourly", targetSec: 0, livePart: 0,
    parts: [{ from: "2026-10-01", to: "2026-10-31", days: 31, billing: "hourly", vatPercent: 0, standardRate: 50.01, fee: 0, workedSec: 1800 }] }
  assert.strictEqual(M.money(fig, 1800).net, 25.01)
})

test("hourly cycle with two rates is not one rate", () => {
  const p = (from, to, rate) => ({ from: from, to: to, days: 15, billing: "hourly", vatPercent: 0, standardRate: rate, fee: 0, workedSec: 3600 })
  const fig = { billing: "hourly", targetSec: 0, expectedSec: 0, daysLeft: 0, currency: "€", workedSec: 7200, livePart: 1,
    parts: [p("2026-11-01", "2026-11-15", 60), p("2026-11-16", "2026-11-30", 120)] }
  const live = M.cycleLive(fig, 0)
  assert.strictEqual(live.money.net, 180)
  assert.strictEqual(M.uniformHourly(live.money), false)
  assert.strictEqual(M.monthLine(live), "2h · 180 €")
})
