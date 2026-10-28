# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-28

| Thing | State |
|---|---|
| Version | 0.2.1 on `main`, pushed to GitHub and installed, submitted to the Omarchy plugin marketplace |
| Tests | 78 helper (`tests/test_worklog.py`, `tests/test_companies.py`), 23 Model.js, 13 QML (KeyField, TimeField), all passing; `omarchy plugin validate` clean |
| Review | Codex gpt-6.1-sol, medium: v1 (13 findings) and v2 (13 findings), all confirmed and fixed with tests (`docs/decisions.md`) |

## Pending

1. Marketplace review (#13084): the reviewer found summaries and tags on the helper's command line at 0.2.0. Fixed in 0.2.1 (96845a8), live-checked; the issue reply and body edit are pending. Docs commits stay local until the next release.
2. Not yet checked live: the reminder toast, the light theme, chart clicks with a pointer.
3. Later: a cycle trend chart, per-week guide overrides, billing the hours over a package in mixed cycles.

## Standing facts

- QML edits need `omarchy restart shell`; the keepLoaded service is not replaced by the hot reload.
- IPC functions take every declared argument: `start` has none, `startWith <note>` has one.
- `SUPER+ALT+CTRL+W` is Omarchy's weather toggle; the README suggests `SUPER+ALT+W` and `SUPER+ALT+SHIFT+W`.

## Done

- **2026-10-28.** 0.2.1: helper arguments go as JSON on stdin; refusals and toasts carry no company names, tags or report file names.
- **2026-10-28.** 0.2.0: companies, contract periods from any date (prorated), billing cycles from any day, month page (every day and session, chart clicks), companies page, extra hours billed or waived per cycle, reports in MD/CSV/HTML, KeyField instead of Qt text controls, neutral default terms. Display name Freelance Worklog.
- **2026-10-27.** 0.1.0: timer, automatic pauses with a prompt on return, review with summary, add time, history, week and month figures, reports.
