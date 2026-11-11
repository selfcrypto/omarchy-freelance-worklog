#!/bin/bash
# HelperRunner under Quickshell: bash tests/helper/run.sh
# Fake helpers (sh one-liners) for a command that cannot start, one past the
# deadline, exit codes (timeout, signal, unknown, refusal), a full queue,
# merged reads, heartbeats and drafts handled once, output past the cap and a
# large answer that must arrive whole.
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cp "$here/../../HelperRunner.qml" "$here/runner.qml" "$scratch/"
mkdir -m 700 "$scratch/runtime"
QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$scratch/runtime" timeout 30 qs -p "$scratch/runner.qml" --no-color > "$scratch/out" 2>&1 || true
grep -o 'CASE .*' "$scratch/out" || { cat "$scratch/out"; echo FAIL; exit 1; }
cases=$(grep -c 'CASE .* ok$' "$scratch/out" || true)
if [ "$cases" -eq 7 ] && ! grep -q 'CASE .*FAIL' "$scratch/out"; then echo ok; else echo FAIL; exit 1; fi
