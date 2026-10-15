#!/usr/bin/env bash
# Does the revised run-step test (6273c67) still fail when the behavior it
# proves is missing, and does a failing case still let the runner return?
# Runs tests/fm-crew-state.test.sh through the tree's own bin/fm-test-run.sh in
# a private TMPDIR, in two fixture trees from setup.sh that both carry base
# fbd3c9b's bin/fm-classify-lib.sh (no run-step process evidence), plus a control:
#   tt-ctl   HEAD unchanged (the control: the suite must pass here)
#   tt-head  HEAD's test file (retrying positives, runner bound to its fixtures)
#   tt-r2    the test file as of 267c59f (single reads, `while :` runner)
# Each tree is a throwaway git repo (the remote-mate cases need one).
# Each run gets <cap> seconds after its first "not ok" line, then is stopped.
# usage: test-discriminates.sh <fixture-root> [cap-secs]
set -u
L=$1 CAP=${2:-90}
run_one() {  # <tree>
  local t="$L/$1" tmp="$L/tmp-$1" log="$L/$1.log" start pid rc=running first='' now
  rm -rf "$tmp"; mkdir -p "$tmp"
  start=$(date +%s)
  ( cd "$t" && TMPDIR="$tmp/" exec bin/fm-test-run.sh tests/fm-crew-state.test.sh ) > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ -z "$first" ] && grep -q '^not ok' "$log"; then first=$now; fi
    if [ -n "$first" ] && [ $(( now - first )) -ge "$CAP" ]; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    rc="still running ${CAP}s after its failure; stopped"
    kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null
  else
    wait "$pid"; rc="exit $?"
  fi
  echo "## $1: bin/fm-test-run.sh tests/fm-crew-state.test.sh -> $rc after $(( $(date +%s) - start ))s${first:+ (first not ok at +$(( first - start ))s)}"
  grep -E '^(not ok|FM_TEST_(BEGIN|END)|fm-test-run)' "$log"
  echo "last ok before it: $(grep '^ok - ' "$log" | tail -1)"
  echo "test runner processes still alive with a cwd under this run's TMPDIR:"
  local p found=0
  for p in $(pgrep -f 'sleep 2 & wait'); do
    if lsof -a -d cwd -p "$p" -Fn 2>/dev/null | grep -q "^n$tmp"; then
      found=1; echo "  $(ps -o pid=,ppid=,etime=,command= -p "$p" | cut -c1-140)"
      kill "$p" 2>/dev/null
    fi
  done
  [ "$found" = 1 ] || echo "  none"
  echo "every 'sleep 2 & wait' runner on the host at this moment (pid ppid etime cwd):"
  for p in $(pgrep -f 'sleep 2 & wait'); do
    echo "  $(ps -o pid=,ppid=,etime= -p "$p" | tr -s ' ') $(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p')"
  done
  echo
}
run_one tt-ctl > "$L/tt-ctl.report" &
c=$!
run_one tt-head > "$L/tt-head.report" &
a=$!
run_one tt-r2 > "$L/tt-r2.report" &
b=$!
wait "$c" "$a" "$b"
cat "$L/tt-ctl.report" "$L/tt-head.report" "$L/tt-r2.report"
