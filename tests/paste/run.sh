#!/bin/bash
# KeyField paste cap under Quickshell: bash tests/paste/run.sh
# A fake wl-paste (bin/) offers 8 MB with no newline. The field must stop the
# copy early (the producer gets out well under 1 MB) and keep 4096 bytes of
# UTF-8, cut at a whole character.
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cp "$here/../../KeyField.qml" "$here/paste.qml" "$scratch/"
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
[ "$fail" -eq 0 ] && echo ok || { echo FAIL; exit 1; }
