# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-11-02

| Thing | State |
|---|---|
| Version | 0.3.11 (carries 0.3.7 to 0.3.10) for `[Verify]` #13941 on omacom/omarchy-plugin-marketplace, answering HANCORE's four prerequisites of 2026-11-10. 0.3.6 is the last verified (#13348) |
| Tests | 104 helper (`tests/test_worklog.py`, `tests/test_companies.py`), 40 Model.js, 33 QML (KeyField, TimeField), clipboard (`tests/paste/run.sh`), helper runner (`tests/helper/run.sh`), render check (`tests/render/run.sh`), all passing; `omarchy plugin validate` clean |
| Review | 0.3.8: first-look design pass, gpt-6-astra, medium, and a Claude Fable agent, blind and in parallel, before the code (findings reproduced, built in; see decisions). The code itself is not reviewed. 0.3.6: gpt-6-astra, medium, and a Claude Fable agent, blind and in parallel (4 + 7 findings, all reproduced, 9 fixed with tests; see decisions). Codex gpt-6.1-sol, medium: v1 (13 findings) and v2 (13 findings), all confirmed and fixed with tests (`docs/decisions.md`). Design: gpt-6-astra, medium, 2026-10-28 (2 defects, 8 improvements). 0.3.0: gpt-6.1-sol, medium (8 defects, all reproduced, fixed with tests; see decisions) |

## Pending

1. 0.3.11 `[Verify]` #13941 open. Nothing goes to GitHub main while it is open or after it is approved; a new release retargets the open issue.
2. Not yet checked live: the edit form on the live session (Enter, the pencil, Save, a pause while the form is open), the reminder toast, the light theme, chart clicks with a pointer. `Panel.qml` has no automated test.
3. Paste decodes each `wl-paste` read on its own, so an accented character cut between two reads arrives as two U+FFFD (since 0.3.0, rare: needs a clipboard owner writing in pieces). Fixing it means a byte-level reader; left alone in 0.3.11 to keep the paste path unchanged.
4. Later: a cycle trend chart, per-week guide overrides, billing the hours over a package in mixed cycles.

## Standing facts

- QML changes need `omarchy restart shell`, also after `omarchy plugin update` (its plugin reload kept the old panel; checked on 4.0.6, 2026-10-28).
- IPC functions take every declared argument: `start` has none, `startWith <note>` has one.
- `SUPER+ALT+CTRL+W` is Omarchy's weather toggle; the README suggests `SUPER+ALT+W` and `SUPER+ALT+SHIFT+W`.

## Done

- **2026-11-11.** 0.3.11: HANCORE's four prerequisites and the checklist built from his past reviews. `HelperRunner.qml` runs each helper call in its own process, settled once on exit, failed start, deadline or output cap, with a bounded queue (view and heartbeat merge, drafts merge at the end, one parse per answer) and a stopped process drained first; a failed or stopped write says it may have been saved and the panel re-reads. The helper reads and writes at most 64 MB (`WORKLOG_MAX_LEDGER_MB`), refuses FIFOs at its data and lock paths, prints ASCII JSON, scans only the weeks and cycles a view shows, caps companies and periods at 100. Paste, copy and the lock probe settle when their process cannot start. Data watchers no longer load the files; toasts run under `timeout`. `CLAUDE.md` and `AGENTS.md` are git-ignored. Reviewed by a blind Claude agent (8 findings, 7 fixed, the paste UTF-8 split left as pending 3); the Codex pass was cancelled (usage limit).
- **2026-11-10.** 0.3.10: a paste lands only in the edit it was asked for. A late clipboard answer is dropped when the field's text, caret or selection changed, its text was replaced from outside (a form reloaded) or it was hidden, and hiding the field stops the read. HANCORE's Low finding on #13941, reproduced by `tests/paste/stale.qml` on 0.3.9.
- **2026-11-04.** 0.3.9: the week guide's hours to go are capped by what keeps the package cycle on pace to Sunday. The guide's figure is then left out. A lead that covers the week reads "This week 8h 17m, nothing more needed to keep pace", a smaller one "1h 47m more keeps the cycle on pace". Behind pace and hourly cycles keep the guide's own figure.
- **2026-11-02.** 0.3.8: the running or paused session can be edited (Enter or the pencil on the track page): times, summary, tags, company, in one write. A form opened before the session changed is refused. A start moved past its stored end is an error in every form (it used to drop the segment). Add segment starts on the first free minute. Pause reasons survive an edited start.
- **2026-10-30.** 0.3.7: chart bars are one shape, so a translucent bar has one tone; the render check compares two pixels of a bar.
- **2026-10-30.** 0.3.6: text fields select (drag, Shift+keys, double click on a word), copy, cut and paste with Ctrl or Omarchy's Super keys, move by word and by line; paste asks for the UTF-8 text type. A click into a time box selects it; keypad keys type digits in time boxes; the ":" comes and goes as digits are typed or deleted. On today's page a start later than now is the day before when the segment ends now or past midnight. Accent on the primary buttons, the run toggle when on, the chart bars, the pace when ahead, the Recent icons and the key caps. Checked live by Kike; reviewed by gpt-6-astra and Fable, fixes in decisions.
- **2026-10-28.** 0.3.5: text fields draw the caret as a bar over the text (it used to be a character that pushed the text apart) and lay out their lines themselves.
- **2026-10-28.** 0.3.4: text fields take accents typed with dead keys (´ then a: á) and place the caret where clicked.
- **2026-10-28.** 0.3.3: the pace line starts with "Cycle:" and says "behind pace", matching "Week guide:" under it.
- **2026-10-28.** 0.3.2: the cycle line says what the cycle still owes and in how many days; the week line is named the week guide, without a per-day figure.
- **2026-10-28.** 0.3.1: neutral figures in the tests and examples; contract form in three groups, session form shows its day, +N days and pause reasons; render check of the form and the chart.
- **2026-10-28.** 0.3.0: panel in the siblings' design language. Fixed hero and key-cap footer with the page scrolling between; Track is the live card, a compact cycle card (pace, this week, one money line), three recent sessions and an activity chart (week or 8 weeks); Month has the package, one chart by day or week with a legend, then the day list with accent day rows and its actions above it. KeyField keeps the caret in view; History scrolls the selected row into view. New fanned preview. Review fixes: paste read in chunks under the cap, half cents round up, live hours split at a terms change, resume checks overlaps, fractional VAT in reports, sessions listed on every day they have work on, DST day rows.
- **2026-10-28.** 0.2.1: helper arguments go as JSON on stdin; refusals and toasts carry no company names, tags or report file names.
- **2026-10-28.** 0.2.0: companies, contract periods from any date (prorated), billing cycles from any day, month page (every day and session, chart clicks), companies page, extra hours billed or waived per cycle, reports in MD/CSV/HTML, KeyField instead of Qt text controls, neutral default terms. Display name Freelance Worklog.
- **2026-10-27.** 0.1.0: timer, automatic pauses with a prompt on return, review with summary, add time, history, week and month figures, reports.
