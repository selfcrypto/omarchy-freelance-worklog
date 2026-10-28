# Testing

## Unit tests

```bash
cd ~/Work/omarchy-freelance-worklog
python3 -m unittest discover -s tests      # helper, 82 tests, ~20 s
node --test tests/                         # Model.js, 27 tests (sets TZ=Europe/Madrid itself)
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml   # KeyField, TimeField: 16 tests
bash tests/paste/run.sh                    # KeyField paste: copy stopped early, 4096 bytes of UTF-8 kept (fake 8 MB clipboard, runs qs)
```

## Static

```bash
/usr/lib/qt6/bin/qmllint -I ~/.local/share/qml-imports -I /usr/lib/qt6/qml *.qml
omarchy plugin validate ~/Work/omarchy-freelance-worklog
```

`unqualified` and `missing-property` on `QObject` (Style.font) are the baseline the other plugins have.

## Install and live check

```bash
git commit -am "…"
git -C ~/.config/omarchy/plugins/io.github.selfcrypto.worklog pull --ff-only
omarchy restart shell
journalctl --user --since -20s | grep -iE 'worklog.*(Error|TypeError)'   # nothing
omarchy-shell worklog status
```

Never test against the real data with confirm: use `discard`, or set `WORKLOG_DATA_DIR` for helper runs.

Cycle: `omarchy-shell worklog start`, `pause`, `resume`, `stop` (review page opens), `discard`; `status` after each.

Ask the user before these, they take the screen or keyboard:

1. Lock (`omarchy-shell lock lock`) while running: paused with `lock`, pill pulses; unlock: away page opens.
2. Idle: `omarchy bar set io.github.selfcrypto.worklog idlePauseMinutes 1`, hands off 70 s: paused back-dated; touch the mouse: away page. Set it back to 15.
3. Suspend and wake: paused at the last tick, away page after unlock.
4. Forms: Tab walks the fields, Ctrl+Enter submits, Esc leaves a field then the page.
5. Theme switch and the second monitor (`grim -o DP-2`).

Screenshot of the panel: `grim -o "$(hyprctl -j monitors | jq -r '.[]|select(.focused).name')" shot.png`.

## Test shell on scratch data

Runs the whole plugin on a scratch data folder; the real data is never opened.

1. Write `launch.sh`: `export WORKLOG_DATA_DIR=<scratch>/data`, `export PATH=<scratch>/bin:$PATH`, `exec omarchy-launch-shell`. A fake `<scratch>/bin/omarchy-hyprland-session-locked` that exits 0 while `<scratch>/locked` exists (else execs the real one) tests the lock pause without locking.
2. `while timeout 30 quickshell kill -p /usr/share/omarchy/shell/ --any-display; do :; done`, then `hyprctl dispatch 'hl.dsp.exec_cmd("<scratch>/launch.sh")'`.
3. Idle: `omarchy bar set io.github.selfcrypto.worklog idlePauseMinutes 1`, no input for 70 s; restore 15. Suspend: `kill -STOP` the shell for 95 s, then `kill -CONT`.
4. `omarchy restart shell` brings back the normal shell.
