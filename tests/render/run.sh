#!/bin/bash
# Render check of the session form and the chart under Quickshell:
#   bash tests/render/run.sh [png dir]
# Needs the Omarchy shell's Commons and Ui (/usr/share/omarchy/shell).
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo="$here/../.."
shell=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/root" && mkdir -m 700 "$scratch/runtime"
ln -s "$shell/Commons" "$scratch/root/Commons"
ln -s "$shell/Ui" "$scratch/root/Ui"
cp "$repo"/{SessionEditor,KeyField,TimeField,WeekChart}.qml "$repo/Model.js" "$scratch/root/"
cp "$here/render.qml" "$scratch/root/shell.qml"
out=${1:-$scratch/png}
mkdir -p "$out"
RENDER_OUT="$out" QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$scratch/runtime" \
  timeout 30 qs -p "$scratch/root" --no-color > "$scratch/log" 2>&1 || true
grep -E 'RENDER|QML.*(rror|TypeError|ReferenceError)' "$scratch/log" | sed 's/^.*qml: //' || true
grep -q 'RENDER done cases=8 failures=0' "$scratch/log" || { echo FAIL; exit 1; }
# A bar reads the same near its baseline and higher up.
bars=$(grep -c 'RENDER bar ' "$scratch/log" || true)
[ "$bars" -eq 8 ] || { echo "FAIL: $bars bars probed"; exit 1; }
grep -o 'RENDER bar .*' "$scratch/log" | while read -r _ _ name x low high; do
  a=$(magick "$out/$name.png" -format "%[pixel:p{$x,$low}]" info:)
  b=$(magick "$out/$name.png" -format "%[pixel:p{$x,$high}]" info:)
  [ "$a" = "$b" ] || { echo "FAIL: $name bar has two tones: $a, $b"; exit 1; }
done
echo ok
