# Freelance Worklog

Omarchy bar plugin for freelance hours: one client or several, packages or hourly. Agents: read `CLAUDE.md`.

- Start, pause and resume from the pill or the panel; the session pauses itself on lock, idle and suspend and asks what to do when you are back.
- Ending a session opens a review: what you did, tags, the company, the times (editable), confirm.
- Add time you did not track, including a session that is still running ("11:00-16:00, 17:00-now").
- Companies with contract terms that change from any date: a monthly package (hours, fee, VAT, standard rate, extra hour rate) or hourly billing. A change in the middle of a cycle is prorated by days.
- Billing cycles per company: the calendar month, or a month from any day (the 21st to the 20th).
- The cycle against its terms with its pace and this week's hours, the price against the standard rate, extra hours billed or waived per cycle; an activity chart of this week by day or the last 8 weeks.
- A month page with the package, one chart by day or by week, and every day with its sessions (hover for details, click to edit, + to add time on a day); history by week.
- Reports for the client, weekly or monthly, in English or Spanish: Markdown, CSV and an HTML page that prints to PDF.

## Requirements

Omarchy 4.0.5 or later (Quickshell 0.3, Qt 6.12), `python3` (standard library only) and `wl-paste` (wl-clipboard, for Ctrl+V in the text fields). All ship with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/selfcrypto/omarchy-freelance-worklog
omarchy restart shell
```

Run in a terminal, `plugin add` asks whether to enable it and in which bar section (left, center or right; right is preselected). `--yes` skips both questions and places it on the right. To move it later: `omarchy bar move io.github.selfcrypto.worklog --section left|center|right`.

## Use

| Where | What |
|---|---|
| Pill, left click | Panel |
| Pill, right click | Start, pause, resume |
| Pill, middle click | End the session |
| Panel | `space` start/pause, `e` end, `d` discard, `n` add time, `m` month, `h` history, `a` activity week or 8 weeks, `c` next company, `C` (or the gear) companies and terms, `esc` close |

Hyprland keys, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + W", "Worklog start/pause", "omarchy-shell worklog toggle")
o.bind("SUPER + ALT + SHIFT + W", "Worklog end session", "omarchy-shell worklog stop")
```

Companies and their terms: the companies page (the gear, or `C`). The first run creates one company, "Company" (40 h a month for 2.000 + VAT 21 %, 50 an hour); rename it and set its billing cycle and terms there. Terms start on a date, so past months keep the terms they had.

Settings (UI and reports only): `omarchy bar set io.github.selfcrypto.worklog <key> <value>`. Keys and defaults are in `manifest.json`.

PDF: open the HTML report in a browser and print, or `chromium --headless --print-to-pdf=report.pdf report.html`.

Data: `~/.local/share/omarchy-worklog/` (a copy of `worklog.json` is kept in `backups/` before the first change of each day). Reports: `~/Documents/Worklog/`.

## Update

```bash
omarchy plugin update io.github.selfcrypto.worklog
omarchy restart shell
```

## Remove

```bash
omarchy plugin remove io.github.selfcrypto.worklog
omarchy restart shell
```

Removing the plugin keeps your data and reports. Delete `~/.local/share/omarchy-worklog/` and `~/Documents/Worklog/` by hand if you want them gone.

## What it runs

`python3 -I worklog.py --stdin` (the data helper, under `timeout`; its arguments go as JSON on stdin, so summaries, tags and terms never show in the process list), `omarchy-hyprland-session-locked` (lock detection), `omarchy-notification-send` (toasts), `omarchy-shell shell summon` (opens its own panel), and `wl-paste` only on Ctrl+V. No network access, no sudo, no other files written than the data folder and the reports.

## License

MIT, see `LICENSE`.
