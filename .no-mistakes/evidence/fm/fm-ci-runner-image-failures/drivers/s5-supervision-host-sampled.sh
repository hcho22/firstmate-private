#!/usr/bin/env bash
# S5: run tests/fm-supervision-host.test.sh through the repo runner and, every
# 15 s, count live processes whose command line or environment names the
# suite's temp root (FM_HOME=.../fm-supervision-host.XXXXXX/<case-home>), plus
# the number of "ok -" lines so far, to show whether case processes pile up.
set -u
root=$1 out=$2
( cd "$root" && bin/fm-test-run.sh tests/fm-supervision-host.test.sh ) > "$out.log" 2>&1 &
runner=$!
count() { ps -axwwE -o pid=,command= 2>/dev/null | grep -F '/fm-supervision-host.' | grep -vcE 'grep|s5-supervision-host-sampled' ; }
echo "elapsed_s cases_passed live_case_processes" > "$out.samples"
t0=$SECONDS
while kill -0 "$runner" 2>/dev/null; do
  printf '%s %s %s\n' "$((SECONDS - t0))" "$(grep -c '^ok - ' "$out.log")" "$(count)" >> "$out.samples"
  sleep 15
done
wait "$runner"; rc=$?
sleep 3
printf 'runner exit=%s\nlive case processes 3 s after the suite exited: %s\n' "$rc" "$(count)" >> "$out.samples"
ps -axwwE -o pid=,ppid=,command= 2>/dev/null | grep -F '/fm-supervision-host.' | grep -vE 'grep|s5-supervision-host-sampled' | cut -c1-300 > "$out.leftover" || true
