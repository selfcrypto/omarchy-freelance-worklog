# omarchy-freelance-worklog · Freelance Worklog, an Omarchy bar plugin for paid hours per company

Timer pill and panel for the Omarchy shell (Quickshell, QML) plus a Python helper that owns the
data. The plugin times sessions per company, asks for a summary at the end of each, shows each
billing cycle against the company's contract terms (a monthly package with extra hours billed or
waived, or hourly) and the package against the standard rate, and writes MD/CSV/HTML reports.
Plugin id `io.github.selfcrypto.worklog`; public at github.com/selfcrypto/omarchy-freelance-worklog.
The data in `~/.local/share/omarchy-worklog/` is real billing data: never delete or rewrite it in a test.

Where every file and function is: `MAP.md` (by topic) and `SYMBOLS.md` (every symbol, grep it).
Current state: `docs/status.md`. Why things are the way they are: `docs/decisions.md` (grep its
index). Procedures: `docs/runbooks/`. Reader-facing: `README.md`. Maintainer-only notes, when
present: `.private/` (git-ignored, never published).

## Parts

| Path | Role |
|---|---|
| `Service.qml` | The one owner of state: runs the helper, ticks the clock, lock/idle/suspend pauses, IPC `worklog`, toasts |
| `Panel.qml`, `SessionEditor.qml`, `TimeField.qml`, `KeyField.qml`, `WeekChart.qml` | Bar pill and the panel pages; the session form; text fields without Qt text controls; the bar chart |
| `Model.js` | Formatting, live totals, cycles, money, chart series, editor checks (shared by the QML, tested under node) |
| `worklog.py` | Single writer of the data files; every command prints one JSON line |
| `tests/` | `test_worklog.py`, `test_companies.py` (helper), `model.test.js` (Model.js), `qml/` (KeyField, TimeField under qmltestrunner), `paste/` (paste cap under `qs`), `render/` (form and chart layout under `qs`) |

## Where things run

| Thing | Where |
|---|---|
| Installed copy | `~/.config/omarchy/plugins/io.github.selfcrypto.worklog`, a clone of the GitHub repo |
| Shell | `omarchy-shell`; log in `journalctl --user` (grep `worklog`) |
| Data | `~/.local/share/omarchy-worklog/` (worklog.json, active.json, backups/) |
| Settings | This widget's entry in `~/.config/omarchy/shell.json` (`omarchy bar set io.github.selfcrypto.worklog <key> <value>`): UI and reports only |
| Reports | `~/Documents/Worklog/` (setting `exportDir`) |

## Rules that apply everywhere

- `worklog.py` is the only writer of the data files; QML calls it under `timeout`, one call at a time, with the arguments as JSON on stdin (`--stdin`), never on argv.
- No data-file text on any command line, notifications included: toasts carry counts and times, refusals name no company or tag.
- Timestamps are stored UTC; days, weeks (Monday first) and months are local. Durations and amounts are never stored.
- Terms belong to the data (companies, contract periods from a date), never to the widget settings; a cycle uses the terms of each of its days, prorated. Past cycles never change when new terms are added.
- One currency per cycle; money is rounded half up to the cent, the same in `worklog.py` (`cents`) and `Model.js` (`round2`).
- No editable Qt text control (TextInput, TextEdit, TextField): every field is a `KeyField`; the clipboard is read only on Ctrl+V, capped at 4096 bytes.
- Nothing resumes on its own after an automatic pause: the panel asks on return.
- Every string from the data file is plain text, clipped before display; reports escape it (HTML, Markdown).
- Colors and sizes come from `qs.Commons` (`Commons.Color`, `Style`); the panel follows the power-saving and wireguard panels.
- No client names or real contract figures in the repo: they go in `.private/`.
- No em dashes and no filler in code, docs, manifest or commits. No AI attribution.

## Session protocol

1. Read this file and `docs/status.md`. Open `MAP.md` before grepping; grep `SYMBOLS.md` for a name. Read `docs/decisions.md` before changing the lifecycle, the schema or billing.
2. Work in this repo, never in the installed copy. Symbols through the LSP (pyright, qmlls, typescript).
3. Verify: `docs/runbooks/testing.md` (unit tests, qmllint, `omarchy plugin validate`, the live check in a test shell).
4. Install: commit, push, `omarchy plugin update io.github.selfcrypto.worklog`, `omarchy restart shell`.

After any change, before the work is called done:

- `docs/status.md`: what is now true and what is pending; move stale Done entries to
  `docs/history/status-journal.md`.
- `docs/decisions.md`: append what a future session would otherwise re-litigate.
- `MAP.md`: a new file gets its role line; a moved responsibility moves its row.
- `repo-docs map && repo-docs check`, clean. Commit the docs with the code.

## Keeping these files small

`CLAUDE.md`, `MAP.md` and `docs/status.md` are read at the start of every session, so every line
costs every session. A rule is one line; its story goes to `docs/decisions.md`. A fact that stops
being current is removed, not annotated. Budgets: this file 15 KB, `MAP.md` 12 KB,
`docs/status.md` 15 KB. `SYMBOLS.md` is generated: never edit it, regenerate it.
