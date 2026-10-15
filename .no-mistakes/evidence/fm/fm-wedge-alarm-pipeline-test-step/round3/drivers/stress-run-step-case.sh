#!/usr/bin/env bash
# The revised run-step case under host load: <n> concurrent copies of
# tests/fm-crew-state.test.sh, each through its own HEAD tree's bin/fm-test-run.sh
# in a private TMPDIR (temp homes only), so the copies load the host for each
# other. Reports each copy's exit, the run-step case's result, and the host load.
# usage: stress-run-step-case.sh <fixture-root> [n]
set -u
L=$1 N=${2:-8}
CASE='ok - progress evidence over the real helper: new work under the active step in the run'
for i in $(seq 1 "$N"); do
  rm -rf "$L/st-$i" "$L/tmp-st-$i"; cp -R "$L/tt-ctl" "$L/st-$i"; mkdir -p "$L/tmp-st-$i"
done
( while :; do printf '[%s] load %s\n' "$(date +%T)" "$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')"; sleep 10; done ) > "$L/st-load.log" &
mon=$!
start=$(date +%s)
for i in $(seq 1 "$N"); do
  ( cd "$L/st-$i" && TMPDIR="$L/tmp-st-$i/" exec bin/fm-test-run.sh tests/fm-crew-state.test.sh ) > "$L/st-$i.log" 2>&1 &
done
wait $(jobs -p | grep -v "^$mon$") 2>/dev/null
kill "$mon" 2>/dev/null
echo "# $N concurrent tests/fm-crew-state.test.sh runs at HEAD (6273c67), $(( $(date +%s) - start ))s wall"
for i in $(seq 1 "$N"); do
  printf 'copy %s: %s | run-step case: %s\n' "$i" \
    "$(sed -n 's/^FM_TEST_END .* exit=\([0-9]*\) duration_ms=\([0-9]*\).*/exit=\1 duration=\2ms/p' "$L/st-$i.log")" \
    "$(grep -q "^$CASE" "$L/st-$i.log" && echo ok || { grep '^not ok' "$L/st-$i.log" || echo 'not reached'; })"
done
echo "# host load (1m 5m 15m) while they ran"
awk 'NR % 3 == 1' "$L/st-load.log"
echo "# leftover 'sleep 2 & wait' runners: $(pgrep -f 'sleep 2 & wait' | wc -l | tr -d ' ')"
