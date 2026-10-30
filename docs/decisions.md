# Decisions

Append-only. One entry per decision a future session would otherwise re-litigate or silently
contradict. Newest last. Navigate by grepping titles or the index; never read this file in full.

Format:

```
## YYYY-MM-DD · short title
**Decision.** What was decided.
**Why.** The reason, briefly. Who asked, if someone did.
**Alternative rejected.** What was not chosen, and what it would have cost.
```

Titles are never changed once cited from another file.

## Index

- `Monthly package is the contract` · `CLAUDE.md`
- `JSON files and a Python helper` · `CLAUDE.md`

## 2026-10-27 · Built, not installed from the marketplace
**Decision.** Own plugin. The closest ones (omaTime, Rimuru Time Tracker, OmaTrack) each miss the end-of-session summary with confirmation, a monthly package view or pause/resume.
**Why.** Kike asked for start/pause/resume, a summary and confirmation at the end, charts and trend.
**Alternative rejected.** omaTime: no target, no trend, no end flow.

## 2026-10-27 · Monthly package is the contract
**Decision.** A package is a fixed number of hours per cycle for a fixed fee, whatever the cycle's length. The weekly hours are a guide; double one week and none the next is fine. Pace = owed hours × days elapsed / days in the cycle.
**Why.** Kike, 2026-10-27, chose a fixed monthly figure over weekly hours × days/7 and over counting Mondays.
**Alternative rejected.** A weekly target as the main figure: wrong for a monthly fee.

## 2026-10-27 · Package price against the standard rate
**Decision.** The month card and the monthly report show the value at the standard rate, the package fee and the discount. The value uses max(worked, owed hours), so early in the cycle it shows the full package.
**Why.** Kike asked to see the real cost against the discounted one.
**Alternative rejected.** Value of hours worked so far only: shows a "negative discount" in the first days.

## 2026-10-27 · JSON files and a Python helper
**Decision.** `worklog.json` + `active.json` written only by `worklog.py` (flock, temp file, os.replace, daily backup). Sessions are lists of segments; a pause is the gap, its reason on the segment it ended.
**Why.** About 300 sessions a year; jq and a copy are enough; stdlib unittest runs without the shell; zoneinfo for DST.
**Alternative rejected.** SQLite: hardening for a few hundred rows. QML writing files: no atomic write or lock, no tests.

## 2026-10-27 · Ask on return, never auto-resume
**Decision.** Lock, idle (15 min, back-dated), suspend and shutdown pause the session. On return the panel opens on the away page: resume (time away not counted), count it as work, stay paused, end.
**Why.** Kike: idle pause "nice but ask when coming back to resume".
**Alternative rejected.** Auto-resume on unlock: counts or drops time without asking.

## 2026-10-27 · Rounding only in reports
**Decision.** `reportRoundingMinutes` 0 or 15, applied per session in exports. Storage and the panel stay exact.
**Why.** Kike: quarters would be fine if they add no complexity.
**Alternative rejected.** Rounding at confirm: loses the real data.

## 2026-10-27 · UI in English, reports in English or Spanish
**Decision.** Panel in English; `reportLanguage` `en` or `es` for exports, Spanish number format for money in both.
**Why.** Kike, 2026-10-27.
**Alternative rejected.** Spanish UI: the shell and the other plugins are English.

## 2026-10-27 · Panel keys and no PanelKeyCatcher
**Decision.** The panel handles its own keys (power-saving pattern); `SUPER+ALT+W` toggles, `SUPER+ALT+SHIFT+W` ends. The panel itself has no global key.
**Why.** The stock catcher eats h/j/k/l/x; `SUPER+ALT+CTRL+W` is Omarchy's weather toggle.
**Alternative rejected.** The spec's third binding, which collided.

## 2026-10-27 · Charts drawn with Rectangles
**Decision.** `WeekChart.qml` uses Rectangles: bars at most 24 px, rounded data end and square baseline, theme accent vs 0.45 foreground, dashed target line, hover readout in the card header.
**Why.** A dozen bars need no repaint logic and pick up theme colors through bindings; on/off never relies on hue.
**Alternative rejected.** Canvas: repaint plumbing for static bars.

## 2026-10-27 · Multi-line TextEdit accepted
**Decision.** Superseded on 2026-10-28 by `KeyField instead of Qt text controls`.

## 2026-10-27 · Codex review fixes
**Decision.** All 13 findings of the Codex review (gpt-6.1-sol, medium; report in `~/.local/state/codex-review/omarchy-worklog-20261027-1837/`) were confirmed against the code and fixed, each with a test that fails on the earlier code: confirm idempotent by session id (and recover drops an active session already in the log); exports clip segments to the period; resume and unpause write the heartbeat; unpause checks overlaps; the editor keeps an untouched end's instant whatever its date; `TimeField` holds typed text; the open segment counts on each day and week it covers; a date change refreshes the view; a parseable but malformed `worklog.json` is refused with the session number and left untouched (never set aside); backups are written to a temp file and renamed; the data dir is forced to 0700 and symlinks refused; CSV cells starting with = + - @ get a leading quote.
**Why.** Billing data: double counting, lost or shifted hours and inflated monthly reports were all reachable.
**Alternative rejected.** Setting a malformed file aside like an unparseable one: it would empty the visible history over one bad record.

## 2026-10-28 · Re-prime keyboard focus when the service switches an open panel

The stock `KeyboardPanel` grabs the keyboard (75 ms Exclusive, then OnDemand) only when it opens. A panel left open while the keyboard moved to a window on another monitor would show the away prompt or the review without keys. `Panel.qml` (`onRequestedPageChanged`) clears `focusPrimed` and calls `beginFocusPrime()`, the same steps an open takes. Seen once in a wtype test on 2026-10-27, not reproduced since.

## 2026-10-28 · v2: companies and contract terms in the data file

Kike asked how to switch companies and change the terms; then for a month view, mid-month changes, better reports and billed extra hours. The design (by Fable) decided: terms in `worklog.json` (history, versioned with the sessions); `client` renamed `company`; billing cycle anchored per company (`cycleDay`), periods carry terms and start on a date; no terms before the first period means uncontracted hours, shown and not billed; mid-cycle changes prorate owed hours and fee by days per part; `billing` is a field (package, hourly); the track page shows the current company, "all companies" lives on the month page; reports in Markdown, CSV and HTML, no PDF in the helper. Changes made while coding:

- The migration makes a generic company ("Company", calendar cycle, terms from the v1 settings, from the first day of the earliest session's month, or of a pending v1 session), not the maintainer's client: the plugin is public. A real company is named and given its cycle and terms on the companies page.
- `contract set --replace <date>` moves a period (the spec made `from` read-only); the form edits the date in place.
- "All companies" on the month page and the all-companies month export use each company's cycle that starts in the shown month (the spec said the cycle holding the month's first day, which showed a 21st-anchored company's previous cycle for October).
- Extra hours (Kike, 2026-10-28: "Each contract should have a price for the excess hours and an option to waive them on the final report"): `overageRate` on every package period, default the standard rate; hours over the owed hours of a pure package cycle are billed at the day-weighted rate with the VAT of the last package part. `waived` on the company lists the cycle keys whose extra hours are off the invoice; the report still lists them as waived. Mixed cycles bill no extra hours.
- The month page's target line is the owed hours per working day (owed / days × 7 / 5), a hint like the week chart's.

## 2026-10-28 · Display name Freelance Worklog

Kike: "Thinking about changing the name to Freelance Worklog". The name says who it is for and keeps it apart from the screen-time and generic time trackers in the marketplace. Only the display name changed: the plugin id `io.github.selfcrypto.worklog`, the IPC target `worklog` and the data folder stay, so nothing needs a reinstall. A gear button on the track and month pages opens the companies page (Kike: "having to press Shift+c is weird"); `C` stays as the key.

## 2026-10-28 · Codex review of v2

`codex-review` gpt-6.1-sol, medium; 13 findings, each checked against the code and real (the review-company one was already fixed). Choices made in the fixes:

- One currency per cycle: a period that changes the currency must start on a cycle's first day (also checked when the cycle day changes). Converting currencies is out of scope.
- Money is rounded half up to the cent in both `worklog.py` (`cents`) and `Model.js` (`round2`), so the panel and the reports never differ by a cent.
- Money in reports uses Spanish separators in both languages (the v2 design, and how the panel shows it).
- Stored data is checked strictly (types, every key); only CLI and form input is coerced.
- A report row's seconds go to the terms parts where its segments fall; with rounding, the difference goes to the part with most.
- Markdown reports escape every text line (no links, images or HTML from the data).

## 2026-10-28 · KeyField instead of Qt text controls
**Decision.** Every text field is a `KeyField`: a plain `Text` with a caret character, keys taken one by one, Tab/Escape/Ctrl+Enter passed out through `unhandledKey`. The clipboard is read only on Ctrl+V or Shift+Insert, through `timeout -k 1 2 wl-paste --no-newline --type text/plain`, stopped past 4096 bytes. No editable Qt text control is left.
**Why.** On Qt 6.12 an editable Qt text control reads every clipboard change through an uncapped Wayland receive loop; the marketplace review blocks them (Power Saving 1.4.4, OmaCal 1.1.0).
**Alternative rejected.** The stock `TextField` and a `TextEdit` for the summary: a verification blocker.

## 2026-10-28 · Neutral default terms
**Decision.** A fresh install's company starts at 40 h, 2.000 a cycle, 50 an hour (extra hours too), VAT 21 %, a 10 h weekly guide. v1 settings still seed the first company; an extra hour rate not given follows the standard rate.
**Why.** The previous defaults were the maintainer's real contract; the repo is public.

## 2026-10-28 · Helper arguments on stdin
**Decision.** The shell runs `timeout -k 3 15 python3 -I worklog.py --stdin` and writes the argument list as one JSON array of strings on stdin (`onStarted`: `write`, then `stdinEnabled = false` for EOF; capped at 1 MiB in `stdin_argv`). The argv form stays for the CLI and tests of it. Refusal texts name no company or tag, and the export toast gives counts and the folder, because `omarchy-notification-send` takes its text on argv.
**Why.** Marketplace review of 0.2.0 (#13084): `/proc/*/cmdline` is readable by other local users, and the arguments carried summaries, tags, company names and terms.
**Alternative rejected.** Moving only `--summary` and `--tags` off argv: company names and contract terms would still show; a temp file per call: more files to create, protect and clean up than a pipe.

## 2026-10-28 · Panel design shared with Power Saving and WireGuard
**Decision.** The same language as the sibling plugins, adapted to several pages: the hero stays at the top and the key hints at the bottom (`footerKeys`, at most one line per page), the page scrolls between them. Track opens on one live card (clock, controls, today), then a compact cycle card (pace, this week, `moneySummary`), three recent sessions, and one activity chart switching between this week and 8 weeks (`a`). Month shows the package, one chart by day or by week with a legend for the dashed guide and the terms markers, then the day list with its actions above it. Long card figures wrap under the title; chips are capped in width with the full name in a tooltip.
**Why.** Kike found the panel plain and long next to the refactored siblings. Codex (gpt-6-astra, medium) ranked the same changes independently: one dominant live card, the month's sessions before the analytics, a stable frame.
**Alternative rejected.** Copying the siblings' single page and one-line rows: Worklog needs several pages, forms and date lists. Keeping all four cards on Track: the trend and the week chart crowded the clock off the first screen.

## 2026-10-28 · Month day rows in the accent
**Decision.** A day row on the month page has an accent tint (stronger for today, strongest when selected) and the rows have a small gap.
**Why.** Kike: the day list was messy to read; the tint makes each day the head of its sessions.

## 2026-10-28 · KeyField scrolls to the caret
**Decision.** The text up to the caret is measured (`TextMetrics` on one line, a hidden wrapped `Text` on many) and the view keeps the caret's end, or its line, inside the box. No layout queries on the shown Text and no Qt text control.
**Why.** Found by Astra: after Home on a long line the caret sat 148 px left of the box and edits happened out of view. Tests in `tests/qml/tst_keyfield.qml` fail on 0.2.1.

## 2026-10-28 · Fanned preview with three captures
**Decision.** `preview.png` keeps the siblings' left column (name, tagline, three bullets) and shows three real captures on the right: Track in front, Month and the review behind, tilted 6°. Procedure in `docs/runbooks/preview.md`.
**Why.** Kike: the app has several sections, a single capture shows one; fanning them was his idea. The flat stagger was made too and looked static.
**Alternative rejected.** One capture like the siblings: hides the month page and the review, which are what sets the plugin apart.

## 2026-10-28 · Fixes from the 0.3.0 review
**Decision.** Codex (gpt-6.1-sol, medium) reported eight defects, all reproduced and fixed with tests that fail on 0.2.1:
- Paste: `SplitParser { splitMarker: "" }` hands over chunks as they arrive (64 KB), so a clipboard with no newline is no longer buffered whole; the cap counts UTF-8 bytes (`utf8Cut`), cut at a whole character. `tests/paste/run.sh` checks the producer is stopped under 1 MB and that 4096 bytes are kept, in ASCII and in two-byte characters.
- Money: `cents` and `round2` round the hundredths to six places before half up; 10,05 at 10 % VAT is 1,01, not 1,00. This can change a past cycle's VAT by a cent where it was exactly half a cent, which was the bug.
- Live money: `cycleLive` takes the live seconds per terms part (`openSecByPart`), so a session running across a change of terms is billed at both rates before it pauses.
- `resume` refuses a time in the future and runs the overlap check `unpause` already ran.
- Reports print a VAT rate as given (`fmt_rate`: 7,5 %), not rounded to whole points.
- The month page lists a session under every day it has work on (`session_days`), so hours entering from the previous day or cycle have a row to open.
- KeyField keeps the caret's line in view with two probes: the text to the end of the caret's word wraps exactly as shown, and the caret's line ends no lower than that and at most one line below the text up to the caret; the lower bound is kept in view. Predicting Qt's breaks inside a word (a URL breaks at `/`, `?`, `&`) was tried and failed. Checked against a read-only TextEdit oracle at every caret position of six texts (words, a long word, URLs, hyphens), kept out of the repo, which has no Qt text controls; `scrolledY` gives the repo tests an independent check.
- A month day row counts the live segment to the next local midnight (`dayOpenSec`), so DST days are 23 or 25 hours, as in the chart.
**Why.** Asked by Kike as the review before releasing 0.3.0. A focused Sol re-check confirmed six fixes and found the paste byte count and long-word caret incomplete; both were then fixed as above.

## 2026-10-28 · Neutral figures in the tests
**Decision.** Test fixtures use a 40 h / 1.600 € package at 50 €/h with a 10 h weekly guide (a second period 50 h / 2.100 €, hourly 50 and 100 €/h); every expected value was recomputed by hand from those terms, with the arithmetic in a comment where it is not obvious. Code comments quote the same figures.
**Why.** Kike: the old fixtures were a real contract and a real rate, in a public repo.
**Alternative rejected.** Scaling the old numbers: they would still read as the real contract.

## 2026-10-28 · Forms regrouped, render check
**Decision.** The contract form has three titled groups (period and billing with the currency; the package: hours, fee, extra hour rate; rates and tax: standard rate, VAT, weekly guide) and one line saying what the standard rate and the guide are for. The session form shows the session's day in its Time header, "+N days" after an end on a later day (`rowEndDays`), the pause reason and a later row's day in the duration caption instead of a chip, and keeps the remove button's place with one row. `tests/render/run.sh` renders the session form and the chart under `qs` at 280 and 400 px in a dark and a light palette with long text, and fails when anything spills past the edges or a text is wider than its box without eliding or wrapping. It found the editor's company chips overflowing (now capped like the panel's) and the totals line overflowing at 280 px (now wraps).
**Why.** Astra's items 5 and 8, asked by Kike. Panel.qml needs the whole shell, so the contract form is checked live, not in the render check.
**Alternative rejected.** Extracting shared components into their own files: the panel's and the editor's chips differ in their palette source; one copy each with the same rules was cheaper than a shared API.

## 2026-10-28 · 0.3.1 replaces 0.3.0 in #13095
**Decision.** 0.3.0 was never approved, so #13095 was retitled to 0.3.1 and pointed at its commit instead of publishing 0.3.0 first. Tag `v0.3.0` stays where it was.
**Why.** Kike chose it, as for Power Saving 1.6.0 replacing 1.5.0.

## 2026-10-28 · Cycle and week lines name their scope
**Decision.** Under the cycle meter the line reads "behind 2h 32m · 38h 09m left in 24 days" (`cycleLeftLine`); the week line reads "Week guide: 9h 50m of 12h, 2h 10m to go" (`weekGuideLine`), without a per-day figure.
**Why.** Kike: "This week … · 25m a day" sat under the cycle meter and read as what the cycle needed a day, which was four times more. Weeks are a guide; only the cycle total is owed.

## 2026-10-28 · Retarget an open `[Verify]` issue instead of queueing releases
**Decision.** While a `[Verify]` issue is open, a newer release retargets it (title and target commit) rather than waiting for approval and filing a second issue. 0.3.2 replaced 0.3.1 in #13095.
**Why.** Kike: queueing means two validations and disturbing the maintainer twice.

## 2026-10-28 · The pace line names the cycle
**Decision.** The track page's pace row reads "Cycle: 2h 18m behind pace, 37h 54m left in 23 days" over "Week guide: 10h 06m of 12h, 1h 54m to go"; `paceLine` says "behind pace" / "ahead of pace" everywhere; the meter's tooltip says the tick is the owed hours spread over the cycle's days. Replaces the bare "behind 2h 18m" of the entry "Cycle and week lines name their scope".
**Why.** Kike read "behind 2h 18m" as the shortfall against the 12 h week, next to the week guide's "1h 54m to go"; both numbers were near each other and only one said what it measured.

## 2026-10-28 · KeyField: dead keys and clicks
**Decision.** KeyField joins a dead key (´ ` ^ ¨ ~ and the rest, `deadMarks`) to the next letter with Unicode composition (´ then a: á, ´ then Shift+E: É; ´ then space: ´; ´ then x: ´x); modifier keys keep a pending dead key. A click places the caret on the character under the pointer (`positionAt`): the line by binary search over where positions wrap (the text up to a position and the rest of its word, as word wrap lays it), then the character by measured widths; the caret glyph in the shown text is accounted for.
**Why.** Kike: accents could not be typed in the summary and a click always sent the caret to the end. Without an editable Qt text control there is no input method, so dead keys arrive as key presses of their own, and a plain Text has no positionAt.
**Alternative rejected.** An input method or a Qt text control: the marketplace review blocks editable Qt text controls.

## 2026-10-28 · KeyField lays out its own lines; the caret is a bar
**Decision.** KeyField wraps its text itself (`wrapLines`: greedy word wrap measured with `FontMetrics.advanceWidth`, a word wider than the box cut anywhere, spaces kept at the end of the line they end) and shows the lines joined by newlines with Qt's wrapping off. The caret is a 2 px bar drawn over the text at the measured place; clicks (`positionAt`) and the scrolling that keeps the caret in view read the same line table. Replaces the caret character drawn into the text, the two caret probes and the click probe of the entries "KeyField scrolls to the caret", "Fixes from the 0.3.0 review" (caret) and "KeyField: dead keys and clicks" (clicks).
**Why.** Kike: placing the caret inside a word showed a space ("Audit oría"), because the caret was a character as wide as any other. With Qt's own wrapping the field could only estimate where a character was (no positionAt on a Text, breaks inside URLs at `/`); with its own layout every position is known. A test clicks where the caret is drawn at every position of a text with a URL and gets the same position back.
**Alternative rejected.** A narrower caret character: still shifts the text; and Qt text controls stay out (marketplace review).

## 2026-10-30 · KeyField selects, copies and pastes
**Decision.** KeyField keeps a selection anchor (`selectionAnchor`, -1 for none): a press places the caret, a drag past the system drag distance selects, Shift+click and Shift+arrows extend, a double click takes the word, Ctrl+arrows move by word, Up/Down by line, Home/End to the line's ends (Ctrl for the text's). Ctrl+C or Ctrl+Insert copies through `wl-copy --type text/plain;charset=utf-8` with the text on stdin; Ctrl+X or Shift+Delete cuts. Paste asks `wl-paste --list-types` first and reads the first of the UTF-8 text type, `text/plain`, `UTF8_STRING`, `STRING`, `TEXT`, each step under the 4096-byte cap. An anchor at the caret (left by a click) is dropped on release and before any edit. Failures to create the clipboard Process are logged, no longer swallowed.
**Why.** Kike: no copy, no drag selection, paste unreliable in the forms. A live key log showed paste and copy working once wired, and a click leaving an anchor at the caret, so Enter selected the new line and the paste replaced it ("the paste goes there"). Omarchy's Super+C/V send Ctrl+Insert and Shift+Insert when a terminal is the active window. `wl-paste --type text` was rejected: it takes text/html when offered first.
**Alternative rejected.** The shell's `Ui.TextField` (a Qt Quick Controls TextField): an editable Qt text control, a marketplace blocker (`KeyField instead of Qt text controls`). Text on `wl-copy`'s command line, as the shell's own panels do: data on argv.

## 2026-10-30 · Theme accent on controls
**Decision.** Primary buttons (Start, Save, Add, Confirm) and the run toggle when on get the accent as their foreground, so fill, border and label are accent; the pace reads in the accent when 15 min or more ahead; past chart bars are the accent at 0.45 (today, this week and met weeks full accent); Recent icons, the "All sessions" link and the footer key caps are accent.
**Why.** Kike found the panel grey ("so boring"). The shell's selected color token defaults to the foreground, so `active` buttons and `ToggleSwitch` render grey on most themes. On/off still differs by alpha, not by hue alone.
**Alternative rejected.** Restyling through the theme's `selected-color` token: a user setting, not the plugin's.

## 2026-10-30 · Time boxes: a click selects, the keypad always types
**Decision.** KeyField has `selectOnFocus` (on in TimeField): a click that brings focus selects the whole text, so typing replaces it; a second click places the caret. Keypad keys that arrive as navigation (`KeypadModifier` with End, Down, PageDown, Left, Clear, Right, Home, Up, PageUp, Insert, Delete) type their digit or "."; with Shift or Ctrl they stay navigation.
**Why.** Kike: digits did nothing in a time box until NumLock was pressed twice. A click left the caret after a full "17:00" (5 of 5 characters), so every digit was refused; and the panel can be told NumLock is off while the keyboard has it on (fcitx5 runs here), which turns keypad 1 into End. Pressing NumLock twice resynced it.
**Alternative rejected.** Asking Hyprland for the real NumLock state (`hyprctl devices`) on focus: a process per focus for a key that, in these fields, is always meant as a digit.

## 2026-10-30 · Time boxes place the colon
**Decision.** While digits are typed or deleted at the end of a time box, `Model.autoColon` puts the ":" after the hour ("17" to "17:", "35" to "3:5") and drops it when a deletion leaves it last ("17:3", Backspace: "17"); a separator typed right after it is dropped. Edits elsewhere in the box are left alone.
**Why.** Kike asked for it. Tests: `tests/model.test.js` ("time boxes place and drop the colon"), `tests/qml/tst_timefield.qml`.
**Alternative rejected.** A fixed `__:__` mask: the caret would jump over the colon and "9" alone could not mean 09:00.

## 2026-10-30 · A start ahead of now on today began the day before
**Decision.** `Model.rowStartDate`: a row on today's page whose start would be ahead of now starts the day before, when the row ends now or past midnight (20:25 to now at 05:00 runs from yesterday 20:25). The row's caption says "started <day>". A row that ends later today still gets "in the future".
**Why.** Kike: "20:25 to now" at 05:00 was refused as in the future although only the day had changed. Mirrors the end before the start ending the next day.
**Alternative rejected.** Moving any future start to yesterday: 20:00 to 22:00 at 05:00 more likely means another day picked with the arrows.

## 2026-10-30 · Fixes from the 0.3.6 review
**Decision.** Reviewed blind and in parallel by gpt-6-astra (medium) and a Claude Fable agent; every finding was reproduced on the unpushed 0.3.6 before fixing. Fixed, each with a test that failed before:
- Cut removes the selection only after `wl-copy` exits 0 and if the text is unchanged (Astra). A failed copy is logged.
- "17" then Tab gave an empty box: `parseClock` reads a trailing separator as the full hour ("17:", "17h"), and a box left with no time goes back to the time it had on focus, the row with it (both). Enter leaves the caret at the end of the formatted time (Fable).
- End on a word cut by the wrap stays on its line (`caretUpstream`, also for clicks and Up/Down), and Up/Down keep the column across short lines (`preferredX`) (Astra).
- `rowStartDate` moves a start to the day before only when the segment from there is at most 16 h (05:02 to now at 05:00 is a typo, not 24 h), and an open row starting within the minute's tolerance counts 0 (Fable).
- Keypad digits only in time boxes (`keypadDigits`); the summary keeps keypad navigation with NumLock off (Fable). This narrows "Time boxes: a click selects, the keypad always types".
- Text set from outside the field (a form reload) drops the selection (`setText` marks the field's own edits) (Fable).
- A paste over a selected time is formatted at once: a deletion is a shorter text that starts the old one (Fable).
- The started day shows in the totals line under the segments, which wraps, as well as in the row's caption, which elides at 280 px (Astra).
- Week charts (`pastMuted`) show weeks under the target in the foreground at 0.45 again, apart from the current week; past days are the accent at 0.55 for contrast on light themes (Astra). This narrows "Theme accent on controls".
**Why.** Both reviews found the "17:" regression; the rest came from one each.
**Alternative rejected.** Kept as decided: the accent on the footer key caps and the Recent icons (Astra suggested neutral, as the siblings have; Kike asked for more accent: his call). `preventStealing` on the field stops a drag that starts on a text field from scrolling the panel (Fable, not checked live); selecting by drag needs it, the wheel still scrolls.
