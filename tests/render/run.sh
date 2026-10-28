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
out=${1:-}
[ -n "$out" ] && mkdir -p "$out"
RENDER_OUT="$out" QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$scratch/runtime" \
  timeout 30 qs -p "$scratch/root" --no-color > "$scratch/log" 2>&1 || true
grep -E 'RENDER|QML.*(rror|TypeError|ReferenceError)' "$scratch/log" | sed 's/^.*qml: //' || true
grep -q 'RENDER done cases=4 failures=0' "$scratch/log" && echo ok || { echo FAIL; exit 1; }
