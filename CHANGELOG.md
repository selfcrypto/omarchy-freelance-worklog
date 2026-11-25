# Changelog

Newest first. Dates are release dates.

## 0.3.13 · 2026-11-25

- A session can be billed in another cycle: "Bill in a different cycle" in the session form shows the cycle before, its own and the next. Its hours count in that cycle's package or extra hours; days, weeks and charts keep the true dates. The month page marks these sessions and lists the carried ones first; reports keep the true date and say how many hours are carried
- A form left open (add or edit a session, the review, the running session, a company, terms) is still there as typed when the panel opens again, with the keyboard in the field it was in
- A save over a session, review or company changed elsewhere since the form loaded (another monitor's panel, the command line) is refused and nothing is written. IPC `target` is covered too
- A cycle can bill its extra hours at its own rate (Rate on the month page), the terms unchanged
- Report totals are a table: Package and Extra hours with hours, rate, value at the standard rate, discount and amount before VAT, then Subtotal, VAT and Total
- Reports keep a summary's line breaks

## 0.3.12 · 2026-11-22

- The run switch has an accent track when on (`AccentSwitch.qml`)

## 0.3.11 · 2026-11-11

- Every helper call runs through `HelperRunner.qml`: one process per call, settled once on exit, failed start, deadline or output cap, with a bounded queue
- The helper reads and writes at most 64 MB of ledger (`WORKLOG_MAX_LEDGER_MB`), refuses FIFOs at its data paths and scans only the weeks and cycles a view shows
- `CLAUDE.md` and `AGENTS.md` are no longer in the repository

## 0.3.10 · 2026-11-10

- A paste lands only in the edit it was asked for: a late clipboard answer is dropped when the field changed, was reloaded or was hidden

## 0.3.9 · 2026-11-04

- The week guide's hours to go are capped by what keeps the package cycle on pace to Sunday

## 0.3.8 · 2026-11-02

- The running or paused session can be edited (Enter or the pencil on the track page): times, summary, tags and company in one write

## 0.3.7 · 2026-10-30

- Chart bars are one shape with one tone

## 0.3.6 · 2026-10-30

- Text fields select, copy, cut and paste, and move by word and line; time boxes take keypad digits and add the colon as you type

## 0.3.5 · 2026-10-28

- Text fields draw the caret as a bar over the text

## 0.3.4 · 2026-10-28

- Text fields take accents typed with dead keys and place the caret where clicked

## 0.3.1 to 0.3.3 · 2026-10-28

- Cycle and week lines say what they measure; the session form shows its day, +N days and pause reasons

## 0.3.0 · 2026-10-28

- Panel redesign in the language of the Power Saving and WireGuard panels: fixed header and key hints, track, month, history and companies pages

## 0.2.1 · 2026-10-28

- Helper arguments go as JSON on stdin; refusals and notifications carry no company names, tags or file names

## 0.2.0 · 2026-10-28

- Companies, contract terms from any date (prorated), billing cycles from any day, a month page, extra hours billed or waived, reports in Markdown, CSV and HTML

## 0.1.0 · 2026-10-27

- Timer with automatic pauses and a prompt on return, end-of-session review, untracked time added afterwards, history, week and month figures
