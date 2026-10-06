#!/usr/bin/env bash
# drive-runner-interrupt.sh <mode> <label> <test-script> [runner args...]
#
# Live driver for the no-mistakes test phase of branch fm/fm-remote-e2e-worker-leak.
# Runs the real bin/fm-test-run.sh, the way a developer does from a terminal, on
# <test-script> with a private TMPDIR, waits until that test has a remote job
# worker SERVING, then ends the run the way <mode> says:
#   int        Ctrl-C: SIGINT to the runner's whole foreground process group
#   term       SIGTERM to the runner process only
#   hup        SIGHUP to the runner process only (terminal closed)
#   abort      SIGKILL to the runner's whole process group (no trap runs)
#   hangguard  nothing; the runner's own per-script bound must kill the script
# It also starts two FOREIGN workers whose state roots lie outside the run (one
# before the run starts, one while it is running) that must survive.
#
# A worker counts as "tied to the run" when its code root is inside the run's
# TMPDIR OR its stdout/stderr is open on a file inside it (lsof), so a worker
# run from the real checkout with its state in the sandbox is caught too.
set -u
ROOT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M49AQW5W6RW2APH2FT58PM8B
EV=/Users/hcho/.no-mistakes/evidence/01M49AQW5W6RW2APH2FT58PM8B
mode=$1 label=$2 script=$3
shift 3
WAIT_SECS=${WAIT_SECS:-600}

base=$(mktemp -d "${TMPDIR:-/tmp}/fmlive.XXXXXX")
base=$(cd "$base" && pwd -P)
caller="$base/caller-tmp"
foreign="$base/foreign"
mkdir -p "$caller" "$foreign/before-home" "$foreign/during-home"
T="$EV/$label.transcript.txt"
: >"$T"
say() { printf '[%s +%ss] %s\n' "$(date +%H:%M:%S)" "$((SECONDS - t0))" "$*" | tee -a "$T"; }
t0=$SECONDS

all_workers() { # pid per line, every remote job worker of this user
  ps -u "$(id -u)" -o pid=,command= | awk '{
    c = $0; sub(/^ *[0-9]+ +/, "", c)
    if ($2 !~ /(awk|grep|sed)$/ && c ~ /\/bin\/fm-remote-job-worker\.sh( --serve| --lane .*)?$/) print $1
  }'
}
tied_to() { # <dir>: workers whose code root or stdout/stderr is under <dir>
  local dir=$1 pid cmd out
  for pid in $(all_workers); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *"$dir"/*) echo "$pid"; continue ;; esac
    out=$(lsof -a -p "$pid" -d 1,2 -Fn 2>/dev/null | sed -n 's/^n//p')
    case "$out" in *"$dir"/*) echo "$pid" ;; esac
  done | sort -u
}
snapshot() { # <title> <pids...>
  local title=$1 pid
  shift
  say "$title"
  if [ "$#" -eq 0 ]; then echo "    (none)" | tee -a "$T"; return; fi
  for pid in "$@"; do
    ps -o pid=,ppid=,pgid=,etime=,command= -p "$pid" 2>/dev/null | sed 's/^/    /' | tee -a "$T"
    lsof -a -p "$pid" -d 1 -Fn 2>/dev/null | sed -n 's/^n/      stdout -> /p' | tee -a "$T"
  done
}
start_foreign() { # <name>
  (cd "$ROOT" && export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$foreign/$1-state" &&
    . bin/fm-remote-job-lib.sh && fm_remote_job_start_linux_worker "$ROOT" "$foreign/$1-home") >/dev/null 2>&1
  local d=$((SECONDS + 60))
  until [ -s "$foreign/$1-state/worker.pid" ]; do [ "$SECONDS" -lt "$d" ] || break; sleep 0.1; done
  cat "$foreign/$1-state/worker.pid" 2>/dev/null
}
stop_tree() { (cd "$ROOT" && . bin/fm-remote-job-lib.sh && fm_remote_job_stop_worker_tree "$1") || true; }

say "mode=$mode script=$script runner-args=[$*] host=$(uname -sr)"
say "run TMPDIR (caller) = $caller"
say "foreign state roots = $foreign/{before,during}-state (outside the run)"
foreign_before=$(start_foreign before)
say "foreign worker started BEFORE the run: serving pid ${foreign_before:-<none>}"

(cd "$ROOT" && TMPDIR="$caller" exec perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' \
  bin/fm-test-run.sh --jobs 1 "$@" "$script") >"$base/out" 2>"$base/err" &
runner=$!
say "started: bin/fm-test-run.sh --jobs 1 $* $script  (runner pid/pgid $runner)"

deadline=$((SECONDS + WAIT_SECS))
serving=
MIN_SERVING=${MIN_SERVING:-1}
while :; do
  n=0
  for pid in $(tied_to "$caller"); do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in *' --serve') serving=$pid; n=$((n + 1)) ;; esac
  done
  [ "$n" -lt "$MIN_SERVING" ] || break
  kill -0 "$runner" 2>/dev/null || { say "FAIL: run ended before a worker was serving"; break; }
  [ "$SECONDS" -lt "$deadline" ] || { say "FAIL: no serving worker within ${WAIT_SECS}s"; break; }
  sleep 0.2
done
foreign_during=$(start_foreign during)
say "foreign worker started DURING the run: serving pid ${foreign_during:-<none>}"
# shellcheck disable=SC2046
snapshot "workers tied to the run while it is live:" $(tied_to "$caller")
say "runner pgid=$(ps -o pgid= -p "$runner" | tr -d ' ')  (workers above sit in their own isolated group)"

case "$mode" in
  int) say "ACTION: kill -INT -$runner   (Ctrl-C to the foreground group)"; kill -INT -- "-$runner" ;;
  term) say "ACTION: kill -TERM $runner  (runner only)"; kill -TERM "$runner" ;;
  hup) say "ACTION: kill -HUP $runner   (runner only, terminal closed)"; kill -HUP "$runner" ;;
  abort) say "ACTION: kill -KILL -$runner  (whole group killed outright, no trap runs)"; kill -KILL -- "-$runner" ;;
  hangguard) say "ACTION: none - waiting for the runner's per-script bound to kill the script" ;;
  scriptkill)
    sp=$(cat "$caller"/fm-test-run.*/s0/script.pgid 2>/dev/null)
    say "ACTION: kill -KILL -$sp  (the test script's own group, recorded in s0/script.pgid; its traps never run - what a hang-guard KILL leaves when the script's TERM cleanup loses the race)"
    kill -KILL -- "-$sp" ;;
esac
rc=0
wait "$runner" 2>/dev/null || rc=$?
say "runner exited rc=$rc"
if [ "$mode" = abort ]; then
  d=$((SECONDS + 120))
  while [ -n "$(tied_to "$caller")" ] || [ -n "$(find "$caller" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; do
    [ "$SECONDS" -lt "$d" ] || break
    sleep 0.2
  done
  say "sentinel cleanup observed after waiting"
fi
sleep 5
say "5s later (any restart supervisor would have respawned a --serve child by now):"
# shellcheck disable=SC2046
snapshot "workers tied to the run after it ended:" $(tied_to "$caller")
left=$(find "$caller" -mindepth 1 2>/dev/null | head -20)
say "contents of run TMPDIR after the run: ${left:-(empty)}"
procs=$(ps -u "$(id -u)" -o pid=,command= | grep -F "$caller" | grep -v grep)
say "any process naming the run TMPDIR: ${procs:-(none)}"
for name in before during; do
  pid=$(cat "$foreign/$name-state/worker.pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then say "foreign $name worker $pid: ALIVE (correct)"
  else say "foreign $name worker ${pid:-?}: DEAD (wrong - the reaper touched a worker outside the run)"; fi
done

{
  echo "----- runner stdout lines reporting what the reaper stopped -----"; grep -F 'after the script ended' "$base/out" || echo "(none)"
  echo "----- runner stdout (tail) -----"; tail -25 "$base/out"
  echo "----- runner stderr (tail) -----"; tail -25 "$base/err"
} | tee -a "$T"

verdict=PASS
[ "${n:-0}" -ge "$MIN_SERVING" ] || { verdict=FAIL; say "never saw $MIN_SERVING serving worker(s) before acting, so this run proves nothing"; }
[ -z "$(tied_to "$caller")" ] || verdict=FAIL
[ -z "$left" ] || verdict=FAIL
[ -n "$foreign_before" ] && kill -0 "$foreign_before" 2>/dev/null || verdict=FAIL
[ -n "$foreign_during" ] && kill -0 "$(cat "$foreign/during-state/worker.pid" 2>/dev/null)" 2>/dev/null || verdict=FAIL
say "VERDICT: $verdict"

# Teardown: never leave anything behind on the host.
for pid in $(tied_to "$caller") $(tied_to "$foreign"); do stop_tree "$pid"; done
sleep 1
say "teardown: workers left tied to this driver's dirs: $(tied_to "$base" | tr '\n' ' ')"
rm -rf "$base"
[ "$verdict" = PASS ]
