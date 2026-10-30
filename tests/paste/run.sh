#!/bin/bash
# KeyField paste cap under Quickshell: bash tests/paste/run.sh
# A fake wl-paste (bin/) offers 8 MB with no newline. The field must ask for
# the UTF-8 text type, stop the copy early (the producer gets out well under
# 1 MB) and keep 4096 bytes of UTF-8, cut at a whole character. A fake
# wl-copy checks a copy sends the selection on stdin, never as an argument,
# and that a cut whose copy fails keeps the text.
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cp "$here/../../KeyField.qml" "$here/paste.qml" "$here/copy.qml" "$scratch/"
mkdir -m 700 "$scratch/runtime"
fail=0
check() {  # character, expected characters kept
  : > "$scratch/progress"
  WLPASTE_CHAR="$1" WLPASTE_PROGRESS="$scratch/progress" PATH="$here/bin:$PATH" QT_QPA_PLATFORM=offscreen \
    XDG_RUNTIME_DIR="$scratch/runtime" timeout 10 qs -p "$scratch/paste.qml" --no-color > "$scratch/out" 2>&1 || true
  local line peak final sent
  line=$(grep -o 'PASTE peak=[0-9]* final=[0-9]*' "$scratch/out" || true)
  peak=${line#*peak=}; peak=${peak%% *}; final=${line##*final=}; sent=$(cat "$scratch/progress")
  echo "char=$1 ${line:-no result} producer_sent=${sent:-0}"
  if [ -z "$line" ] || [ "$peak" -gt "$2" ] || [ "$final" -ne "$2" ] || [ "${sent:-0}" -ge 1048576 ]; then fail=1; fi
}
check x 4096
check é 2048
copycheck() {  # WLCOPY_FAIL value, text the cut must leave
  WLCOPY_FAIL="$1" WLCOPY_ARGS="$scratch/copy-args" WLCOPY_OUT="$scratch/copy-out" PATH="$here/bin:$PATH" QT_QPA_PLATFORM=offscreen \
    XDG_RUNTIME_DIR="$scratch/runtime" timeout 10 qs -p "$scratch/copy.qml" --no-color > "$scratch/out" 2>&1 || true
  local kept
  kept=$(grep -o 'CUT kept=.*' "$scratch/out" || true)
  echo "copy fail=${1:-no} last stdin=[$(cat "$scratch/copy-out" 2>/dev/null)] args=[$(cat "$scratch/copy-args" 2>/dev/null)] $kept"
  if [ "$kept" != "CUT kept=\"$2\"" ] || grep -q -e Auditor -e unsaved "$scratch/copy-args"; then fail=1; fi
}
copycheck "" ""
copycheck 1 "unsaved note"
[ "$fail" -eq 0 ] && echo ok || { echo FAIL; exit 1; }
