# Map

## I want to change…

| What | Where | Also moves |
|---|---|---|
| A state transition (start, pause, stop, confirm…) | `worklog.py` (`cmd_*`, `MUTATING`) | `Service.qml` action function, `tests/test_worklog.py` |
| What pauses automatically, and the return prompt | `Service.qml` (lock probe, `armIdle`, `idleChanged`, tick, `checkReturn`) | `Panel.qml` away page |
| Week, cycle, trend or money figures | `worklog.py` (`build_view`, `week_figures`, `cycle_figures`, `cycle_parts`, `money`) | `Model.js` (`weekLive`, `cycleLive`, `money`), the three test files |
| Billing cycles (anchor day, keys, labels) | `worklog.py` (`cycle_bounds`, `cycle_of`, `cycle_label`) | `Model.js` (`cycleBounds`, `cycleOf`, `cycleLabel`) must agree, both tested |
| Companies, contract periods, extra hours | `worklog.py` (`cmd_company`, `cmd_contract`, `cmd_overage`, `clean_terms`, `terms_on`) | `Model.js` (`checkTerms`), `Panel.qml` companies page, `tests/test_companies.py` |
| The month page | `worklog.py` (`cmd_month`), `Panel.qml` (`openMonth`, `loadMonth`, `monthRows`, month column) | `Model.js` (`cycleDaySeries`, `cycleWeekSeries`, `sessionTip`) |
| A line of text in the panel | `Panel.qml`, formatting in `Model.js` (`weekLine`, `paceLine`, `moneySummary`, `fmt*`) | `tests/model.test.js` |
| A chart | `WeekChart.qml` (`markers`, `thinning`); series in `Model.js` (`daySeries`, `weekSeries`, `cycleDaySeries`, `cycleWeekSeries`) | |
| The review or add/edit form | `SessionEditor.qml`, `TimeField.qml`; checks in `Model.js` (`checkRows`, `rowsFromSegments`) | `worklog.py` (`clean_segments`) must agree |
| A panel page or key | `Panel.qml` (`go`, `keyCatcher` `Keys.onPressed`, page columns) | `footerKeys` (the fixed footer), `hero` |
| The bar pill | `Panel.qml` (`WidgetButton`, `pillLabel`) | |
| An IPC call | `Service.qml` (`IpcHandler`, target `worklog`) | `README.md` |
| A setting (UI preferences only; terms live in the data) | `Service.qml` (properties under settings, `configJson`), `manifest.json` (defaults, schema) | `worklog.py` (`DEFAULT_CONFIG`, `config_from`) when the helper uses it |
| Report format or language | `worklog.py` (`TEXT`, `month_report`, `week_report`, `render_markdown`, `render_html`, `write_csv`) | export tests in `tests/test_worklog.py` and `tests/test_companies.py` |
| The data schema | `worklog.py` (`Store`, `company_problem`, `session_problem`, `_migrate`) | `docs/decisions.md` (v2 entries), a migration in `Store._migrate` |

## Files

| File | What it is for |
|---|---|
| `manifest.json` | Plugin manifest: service + bar widget, defaults, settings schema |
| `Service.qml` | Owner of state, helper queue, automatic pauses, IPC, toasts |
| `Panel.qml` | Bar pill and the panel: track, away, review, editor, history, month and companies pages; `MoneyBlock`, `CompanyChips` |
| `SessionEditor.qml` | Summary, tags, segment rows with live totals; review, edit and new modes |
| `TimeField.qml` | HH:MM field whose text is not bound to its minutes, so typing is never rewritten |
| `KeyField.qml` | Text field without an editable Qt text control: plain Text, keys one by one, paste on Ctrl+V capped at 4096 bytes |
| `WeekChart.qml` | Column chart of Rectangles with an optional dashed target line and dashed markers |
| `Model.js` | Pure helpers shared by the QML |
| `worklog.py` | Data helper: storage, lifecycle, aggregation, exports |
| `preview.png` | Marketplace image, 1920×960: name and three lines left, three real panel captures fanned right (`docs/runbooks/preview.md`) |

## IPC (`omarchy-shell worklog <call>`)

| Call | Does |
|---|---|
| `start`, `startWith <note>` | Start (or resume when paused) |
| `pause`, `resume`, `toggle`, `stop` | Session control; `stop` opens the review page |
| `confirm`, `discard` | Only while a session waits for review; `confirm` uses the saved draft |
| `startFor <company>`, `useCompany <company>` | Start for, or switch to, a company by id, name or tag |
| `company`, `companies` | The current company; all of them as JSON |
| `status`, `week`, `month` | JSON status (with company and cycle); one-line week and cycle summaries |
| `target <hours>` | Weekly guide of the current company's terms in force today |
| `exportWeek`, `exportMonth`, `exportPeriod <week\|month> <key>`, `exportFor <kind> <key> <company\|all>` | Reports to `exportDir` |
| `refresh`, `probe` | Re-read the data; lock and idle detection state |

## Helper commands (`python3 -I worklog.py <cmd>`)

`view`, `start`, `pause`, `resume`, `unpause`, `stop`, `back`, `draft`, `edit-active`, `confirm`,
`discard`, `heartbeat`, `recover`, `announce`, `add`, `update`, `delete`, `company`, `contract`,
`overage`, `sessions`, `month`, `export`. Every call takes `--config <json>` (report settings and the
v1 terms under `legacy`). The shell sends the whole list as JSON on stdin (`worklog.py --stdin`, `stdin_argv`); test hooks `WORKLOG_DATA_DIR`, `WORKLOG_NOW`, `WORKLOG_TZ`.

## Tests

| File | Covers |
|---|---|
| `tests/test_worklog.py` | Lifecycle, recovery, midnight/DST, week/month/money, validation, overlaps, history, backups, corrupt or malformed files, concurrency, exports clipped to the period |
| `tests/test_companies.py` | v1 migration, cycles (anchor days, short months), terms in force, mid-cycle proration, past cycles unchanged by new terms, hourly and mixed, company scoping, archive rules, validation, extra hours billed or waived, reports (MD, CSV, HTML, es) |
| `tests/model.test.js` | Formatting, live totals, pace and money (prorated, hourly, mixed, extra hours), cycles (same cases as the helper), month page series, terms check, chart series, clock parsing, editor rows |
| `tests/qml/tst_timefield.qml`, `tests/qml/tst_keyfield.qml` | Typing over a time keeps what is typed; KeyField typing, editing, limits, keys passed on, caret kept in view |
| `tests/paste/` | `run.sh` runs KeyField under `qs` against a fake 8 MB `wl-paste` (`bin/`): the copy stops early, 4096 bytes of UTF-8 kept |
