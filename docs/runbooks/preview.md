# Marketplace preview

`preview.png` is 1920×960: the name, a tagline and three bullets on the left in the sibling
plugins' palette (JetBrains Mono), three real panel captures fanned on the right: Track with a
running session in front, Month (one company) behind on the left, the end-of-session review behind
on the right. Only demo data: never Kike's companies or figures.

Scripts (maintainer copy, outside the repo): `~/.local/share/freelance-worklog-preview/`
(`compose_preview.py`, `demo-sessions.tsv`, `launch.sh.example`).

1. Scratch data: `WORKLOG_DATA_DIR=<scratch>/data python3 -I worklog.py ... --config '{}'`:
   `company --action rename --id c_0001 --name "Acme Studio" --tag AS --cycle-day 1`, `contract
   --action set` with a 40 h / 2.000 / 70 package from the 1st, then one `add` per demo session.
2. Test shell on it (`docs/runbooks/testing.md`, "Test shell on scratch data"), with the working
   files copied into the installed copy. For the captures only, add to the installed
   `Service.qml` IPC `function openPage(page: string): string { root.openRequested(page); return "ok" }`
   and in the installed `Panel.qml` `onRequestedPageChanged` route `month` to
   `openMonth("this", "")`. Do not restart the shell after starting the session: the shutdown
   recovery pauses it.
3. Start a session an hour or so back (`start --segments` with an open segment, `draft --summary
   ... --tags ...`, then `omarchy-shell worklog refresh`), `openPage track`, `grim -o <monitor>`;
   `openPage month`, grab; `omarchy-shell worklog stop`, grab the review.
4. Crop each grab to the panel's border, save as `panel-track.png`, `panel-month.png`,
   `panel-review.png`, run `python3 -I compose_preview.py <capture dir> <out dir>`, check the
   result at full and half size, copy `preview-fan.png` to `preview.png`.
5. Put the installed copy back: `git -C ~/.config/omarchy/plugins/io.github.selfcrypto.worklog
   checkout -- . && git -C ... clean -fd`, `omarchy restart shell`.
