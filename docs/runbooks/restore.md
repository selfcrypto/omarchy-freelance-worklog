# Restore

Data: `~/.local/share/omarchy-worklog/`.

## A bad edit or a lost session

```bash
ls ~/.local/share/omarchy-worklog/backups/          # worklog-YYYY-MM-DD.json, the state before that day's first write
cp ~/.local/share/omarchy-worklog/worklog.json ~/worklog-now.json
cp ~/.local/share/omarchy-worklog/backups/worklog-2026-10-27.json ~/.local/share/omarchy-worklog/worklog.json
omarchy-shell worklog refresh
```

## A stuck live session

`active.json` holds the running, paused or waiting session. `omarchy-shell worklog discard` drops it.
To keep it, edit its `segments` (UTC) with jq, then `omarchy-shell worklog refresh`.

## An unreadable or malformed file

Not JSON: the helper moves it aside as `worklog.json.corrupt-<epoch>` and starts empty, with a toast. Restore from `backups/` as above.

JSON with a bad session (missing id, segments, an end before its start): every helper call refuses with `worklog.json session N: …` and the file is left as it is. Fix that session by hand or restore from `backups/`.
