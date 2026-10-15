#!/usr/bin/env bash
# drive-wedged-nested-runner.sh <worktree> <test-file-rev> <watchdog-secs>
# v2: only remote job workers under this case's own fm-test-run-worker-leak.* temp
# root count, so another test run on the same host does not block or skew it.
#
# Runs tests/fm-test-run.test.sh's "TERM stops the run and leaves no remote job
# worker" case (test_terminated_run_leaves_no_remote_job_worker), taken from
# <test-file-rev>, with its nested bin/fm-test-run.sh wedged: the nested runner
# is SIGSTOPped as soon as it has launched the fixture script, so the case's TERM
# can never end it. This is a runner that never ends after it is terminated, the
# hang that cancelled CI run 38652324711. Each output line is prefixed with the
# seconds since the file started. The watchdog kills the file if it is still
# running after <watchdog-secs>.
#
# The driver touches nothing the test owns until the end: it records the
# fixture script's process group and every remote job worker that appears, and
# after the file ends reports which of them are still alive at +1s, +5s, +15s
# and +30s, before stopping any survivors itself.
set -u
wt=$1 rev=$2 watchdog=$3 variant=${4:-as-is}
# variant delay-cleanup: the file's EXIT trap pauses 3s between
# stop_worker_leak_case and fm_test_cleanup (diagnostic only), to tell whether
# the nested run's sentinel can reap the run when its run root still exists.
case_file="$wt/tests/zz-nm-wedge-$$.test.sh"
trap 'rm -f "$case_file"' EXIT
git -C "$wt" show "$rev:tests/fm-test-run.test.sh" \
  | awk -v variant="$variant" '
      variant == "delay-cleanup" && /^trap .stop_worker_leak_case; fm_test_cleanup. EXIT$/ { print "trap '"'"'stop_worker_leak_case; sleep 3; fm_test_cleanup'"'"' EXIT"; next }
      /^fm_test_run_cases \\$/ { print "fm_test_run_cases test_terminated_run_leaves_no_remote_job_worker"; exit }
      { print }' >"$case_file"
grep -n '^trap .*EXIT$' "$case_file" | tail -1
chmod +x "$case_file"
# A remote job worker is a shell running bin/fm-remote-job-worker.sh (other
# processes, such as agents, can merely mention the name in their arguments).
worker_pids() {
  local w
  for w in $(pgrep -f 'bin/fm-remote-job-worker\.sh'); do
    case "$(ps -o command= -p "$w" 2>/dev/null)" in *bash\ *fm-test-run-worker-leak.*bin/fm-remote-job-worker.sh*) printf '%s\n' "$w" ;; esac
  done
}
pre_workers=$(worker_pids | tr '\n' ' ')
pre_fixtures=$(pgrep -f 'bash tests/fm-worker-leak-fixture' | tr '\n' ' ')
[ -z "$pre_fixtures$pre_workers" ] || { echo "driver: refusing to start, leftovers already running: fixtures=[$pre_fixtures] workers=[$pre_workers]"; exit 2; }
start=$SECONDS
ts() { echo "[$((SECONDS - start))s] $*"; }
ts "running test_terminated_run_leaves_no_remote_job_worker from tests/fm-test-run.test.sh@$rev (lanes=1, variant $variant), watchdog ${watchdog}s"
(cd "$wt" && FM_TEST_CASE_LANES=1 exec perl -e 'setpgrp(0, 0); exec @ARGV' bash "$case_file") \
  > >(while IFS= read -r line; do echo "[$((SECONDS - start))s] $line"; done) 2>&1 &
file_pid=$!

is_descendant() { # <pid> <ancestor>
  local p=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$2" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

nested=
tracked=   # "pid:command-prefix" entries
track() { # <pid>
  local cmd
  cmd=$(ps -o command= -p "$1" 2>/dev/null | cut -c1-60)
  [ -n "$cmd" ] || return 0
  case " $tracked " in *" $1:"*) return 0 ;; esac
  tracked="$tracked $1:$(printf '%s' "$cmd" | tr ' ' '_')"
}
fixture_pgids=
while kill -0 "$file_pid" 2>/dev/null; do
  if [ -z "$nested" ]; then
    for p in $(pgrep -f 'bin/fm-test-run.sh --jobs 1 tests/fm-worker-leak-fixture.test.sh'); do
      # The runner itself, not one of its forked subshells (same command line).
      case "$(ps -o command= -p "$(ps -o ppid= -p "$p" | tr -d ' ')")" in *'bin/fm-test-run.sh --jobs 1 tests/fm-worker-leak-fixture'*) continue ;; esac
      for f in $(pgrep -f 'bash tests/fm-worker-leak-fixture.test.sh'); do
        if is_descendant "$f" "$p"; then
          kill -STOP "$p" && nested=$p
          ts "driver: SIGSTOPped the nested runner $p (state $(ps -o stat= -p "$p")) once its fixture script $f was running"
          break 2
        fi
      done
    done
  fi
  for f in $(pgrep -f 'fm-worker-leak-fixture.test.sh'); do
    # The fixture script itself (the runner, its subshells and the guard only
    # name it in their arguments).
    case "$(ps -o command= -p "$f")" in 'bash tests/fm-worker-leak-fixture.test.sh'*) ;; *) continue ;; esac
    g=$(ps -o pgid= -p "$f" 2>/dev/null | tr -d ' ')
    [ -n "$g" ] || continue
    case " $fixture_pgids " in *" $g "*) ;; *) fixture_pgids="$fixture_pgids $g" ;; esac
  done
  for g in $fixture_pgids; do for m in $(pgrep -g "$g"); do track "$m"; done; done
  for w in $(worker_pids); do track "$w"; done
  if [ "$((SECONDS - start))" -ge "$watchdog" ]; then
    ts "driver: WATCHDOG - the test file is still running ${watchdog}s in; nested runner state: $(ps -o stat= -p "$nested" 2>/dev/null || echo gone)"
    kill -KILL -- "-$file_pid" 2>/dev/null
    [ -z "$nested" ] || { kill -CONT "$nested"; kill -KILL -- "-$nested" 2>/dev/null; }
    break
  fi
  sleep 0.5
done
wait "$file_pid" 2>/dev/null
rc=$?
ts "driver: test file ended rc=$rc; nested runner now: $(ps -o stat= -p "$nested" 2>/dev/null || echo gone)"
ts "driver: tracked fixture/worker processes: $tracked"
alive() {
  local e pid cmd out=
  for e in $tracked; do
    pid=${e%%:*} cmd=${e#*:}
    [ "$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-60 | tr ' ' '_')" = "$cmd" ] && out="$out $pid:$cmd"
  done
  printf '%s' "$out"
}
t_end=$SECONDS
for at in 1 5 15 30; do
  while [ "$((SECONDS - t_end))" -lt "$at" ]; do sleep 0.2; done
  ts "driver: +${at}s after the file ended, still alive:$(a=$(alive); printf '%s' "${a:- none}")"
done
for e in $(alive); do kill -KILL "${e%%:*}" 2>/dev/null; done
