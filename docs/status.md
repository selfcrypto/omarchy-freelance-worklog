# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-30

| Thing | State |
|---|---|
| Version | 0.3.6 on `main`, tag v0.3.6, new `[Verify]` issue opened 2026-10-30; 0.3.5 is the published, verified version (#13095 closed) |
| Tests | 82 helper (`tests/test_worklog.py`, `tests/test_companies.py`), 34 Model.js, 33 QML (KeyField, TimeField), clipboard (`tests/paste/run.sh`), render check (`tests/render/run.sh`), all passing; `omarchy plugin validate` clean |
| Review | 0.3.6: gpt-6-astra, medium, and a Claude Fable agent, blind and in parallel (4 + 7 findings, all reproduced, 9 fixed with tests; see decisions). Codex gpt-6.1-sol, medium: v1 (13 findings) and v2 (13 findings), all confirmed and fixed with tests (`docs/decisions.md`). Design: gpt-6-astra, medium, 2026-10-28 (2 defects, 8 improvements). 0.3.0: gpt-6.1-sol, medium (8 defects, all reproduced, fixed with tests; see decisions) |

## Pending

1. 0.3.6 `[Verify]` issue open: push nothing but a release that retargets it (the target commit must stay last on main). The installed copy is already at 0.3.6.
2. Not yet checked live: the reminder toast, the light theme, chart clicks with a pointer.
3. Later: a cycle trend chart, per-week guide overrides, billing the hours over a package in mixed cycles.

## Standing facts

- QML changes need `omarchy restart shell`, also after `omarchy plugin update` (its plugin reload kept the old panel; checked on 4.0.6, 2026-10-28).
- IPC functions take every declared argument: `start` has none, `startWith <note>` has one.
- `SUPER+ALT+CTRL+W` is Omarchy's weather toggle; the README suggests `SUPER+ALT+W` and `SUPER+ALT+SHIFT+W`.

## Done

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
