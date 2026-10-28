# Reports

Monthly and weekly reports go to `exportDir` (default `~/Documents/Worklog/`), never overwriting:
a second export of the same period gets `-2`, `-3`.

| Format | Use |
|---|---|
| `.md` | Readable as text, pastes into mail |
| `.csv` | One row per session: `date,company,start,end,worked_minutes,paused_minutes,tags,summary` |
| `.html` | The same report as a self-contained page (no scripts, no external files); setting `reportHtml` |

## A PDF for the client

Open the `.html` in a browser and print to PDF, or:

```bash
chromium --headless --print-to-pdf=worklog-2026-10.pdf worklog-2026-10.html
```

## Before sending

1. Month page (`m`), the cycle: every session has a summary; extra hours billed or waived as agreed.
2. `x` on the month page exports that cycle for that company (`All` exports one set per company).
3. Spanish: `omarchy bar set io.github.selfcrypto.worklog reportLanguage es`.
