#!/usr/bin/env bash
# Round 2 live drive (target 267c59f) against the real no-mistakes daemon's live
# run 01M4Z2NDNVFJXVP6PM2K4SF305, whose own copy is this worktree.
# usage: drive.sh <fixture-root from setup.sh>
# Every phase uses a fresh crew fixture (own state dir, own private tmux server
# with one static idle worker pane) and the real bin/fm-watch.sh in its normal
# blocking mode, re-armed after every wake by watch-loop.sh.
#   A  long command (real bin/fm-test-run.sh) running in the run's copy:
#      this change and base fbd3c9b side by side
#   B  long command killed, run still working: this change
#   C  the crew's own worktree starts a new process tree every second: this change
#   D  another run's copy starts a new process tree every second: this change
set -u
L=$1
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
OTHER=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4YJKR5WFZJMRQYGKGBZH4FV
RUN=01M4Z2NDNVFJXVP6PM2K4SF305
OUT=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round2
NM=/usr/local/bin/no-mistakes
WINDOW=${WINDOW:-6}
cd "$L" || exit 1
set -m

mkfix() {  # <name>
  local d="$L/$1"
  mkdir -p "$d/state" "$d/fakebin" "$d/tmux"
  cp "$L/forwarder.sh" "$d/fakebin/no-mistakes"; chmod +x "$d/fakebin/no-mistakes"
  printf 'window=fm:fm-wedgelive\nkind=ship\nworktree=%s\n' "$L/wt2" > "$d/state/wedgelive.meta"
  printf 'paused: waiting on the validation response\n' > "$d/state/wedgelive.status"
  TMUX_TMPDIR="$d/tmux" tmux -f /dev/null new-session -d -s fm -n fm-wedgelive -x 120 -y 30 "$L/pane.sh"
}
killfix() {  # <name>
  TMUX_TMPDIR="$L/$1/tmux" tmux kill-server 2>/dev/null || true
}
sample() {  # <label> <file>
  local row lc
  row=$(cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null | sed -n '/active_steps/{n;p;}' | sed 's/^ *//')
  lc=$(pgrep -f "bin/fm-test-run.sh tests/fm-crew-state" | head -1)
  printf '[%s] %s | axi active step: %s | long command: %s\n' "$(date +%T)" "$1" "$row" \
    "${lc:+pid $lc etime $(ps -o etime= -p "$lc" | tr -d ' ') cwd $(lsof -a -d cwd -p "$lc" -Fn 2>/dev/null | sed -n 's/^n//p')}" >> "$2"
}
report() {  # <name> <label> <title>
  local d="$L/$1"
  echo "## $3"
  echo "### wakes delivered to firstmate"; cat "$d/wakes-$2.log"
  echo "### watcher triage log (deferrals and timer resets; per-poll absorbs omitted)"
  grep -v "absorbed non-terminal stale (provably working): " "$d/state/.watch-triage.log" 2>/dev/null
  echo
}
shard_runner() {  # <dir>: a long command that starts a fresh process tree every second
  ( cd "$1" && exec bash -c 'while :; do bash -c "sleep 2 & wait" & sleep 1; done' ) &
}
stop_group() {  # <pid>
  kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
  sleep 3
  kill -KILL -- "-$1" 2>/dev/null || true
}

S="$L/samples.log"; : > "$S"

# Crew-state read, live: the new `active <secs>s in run <id>` segment.
mkfix probe
{
  echo "\$ no-mistakes axi status --run $RUN   # real daemon, $(date +%T)"
  (cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null | sed -n '/^run:/,/^  head:/p;/active_steps/,/^branch_sync/p')
  echo
  echo "\$ bin/fm-crew-state.sh wedgelive   # this change (267c59f)"
  PATH="$L/probe/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/probe/state" TMUX_TMPDIR="$L/probe/tmux" "$WT/bin/fm-crew-state.sh" wedgelive
  echo "\$ bin/fm-crew-state.sh wedgelive   # base fbd3c9b"
  PATH="$L/probe/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/probe/state" TMUX_TMPDIR="$L/probe/tmux" "$L/base/bin/fm-crew-state.sh" wedgelive
  echo "\$ fm_nm_run_worktree $RUN   # NM_HOME=$NM_HOME"
  bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_worktree "$2"' _ "$WT" "$RUN"
} > "$OUT/live-crew-state-read.txt" 2>&1
killfix probe

# Phase A: the run's step runs a real long command in the run's own copy.
( cd "$WT" && exec bin/fm-test-run.sh tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh ) > "$L/long-command.log" 2>&1 &
LONG=$!
sleep 12
mkfix rAf; mkfix rAb
END=$(( $(date +%s) + ${A_SECS:-180} ))
( cd "$L/rAf" && WINDOW=$WINDOW ./../watch-loop.sh "$WT" "$END" "$L/rAf" fixed ) &
f=$!
( cd "$L/rAb" && WINDOW=$WINDOW ./../watch-loop.sh "$L/base" "$END" "$L/rAb" base ) &
b=$!
# The probe from inside the drive too: crew_progress_evidence over the real helper.
sleep 20
{
  echo "\$ crew_progress_evidence wedgelive <state> <anchor 10s old> $WINDOW   # this change, $(date +%T)"
  a="$L/anchor"; : > "$a"; touch -t "$(date -v-10S +%Y%m%d%H%M.%S)" "$a"
  PATH="$L/rAf/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/rAf/state" TMUX_TMPDIR="$L/rAf/tmux" \
    bash -c '. "$1/bin/fm-classify-lib.sh"; crew_progress_evidence wedgelive "$2" "$3" "$4"; echo " (rc=$?)"' _ "$WT" "$L/rAf/state" "$a" "$WINDOW"
} > "$OUT/live-progress-evidence-probe.txt" 2>&1
while kill -0 $f 2>/dev/null || kill -0 $b 2>/dev/null; do sample A "$S"; sleep 15; done
wait $f $b
{ echo "# Scenario A: real bin/fm-test-run.sh running in the run's own copy ($WT); watcher window ${WINDOW}s; both watchers concurrently"
  report rAf fixed "this change (267c59f)"; report rAb base "base (fbd3c9b)"; } > "$OUT/live-A-long-command-fixed-vs-base.txt"
killfix rAf; killfix rAb

# Phase B: the long command is gone, the run still working.
stop_group "$LONG"
mkfix rB
END=$(( $(date +%s) + ${B_SECS:-70} ))
( cd "$L/rB" && WINDOW=$WINDOW ./../watch-loop.sh "$WT" "$END" "$L/rB" fixed ) &
f=$!
while kill -0 $f 2>/dev/null; do sample B "$S"; sleep 15; done
wait $f
{ echo "# Scenario B: run still working, its step's long command killed (nothing new in the run's copy); watcher window ${WINDOW}s"
  report rB fixed "this change (267c59f)"; } > "$OUT/live-B-step-command-stopped.txt"
killfix rB

# Phase C: the crew's own worktree keeps starting work; the working run outvotes it.
shard_runner "$L/wt2"; C=$!
sleep 10
mkfix rC
END=$(( $(date +%s) + ${C_SECS:-70} ))
( cd "$L/rC" && WINDOW=$WINDOW ./../watch-loop.sh "$WT" "$END" "$L/rC" fixed ) &
f=$!
while kill -0 $f 2>/dev/null; do sample C "$S"; sleep 15; done
wait $f
stop_group "$C"
{ echo "# Scenario C: run still working, nothing new in its copy, the crew's OWN worktree ($L/wt2) starts a new process tree every second; watcher window ${WINDOW}s"
  report rC fixed "this change (267c59f)"; } > "$OUT/live-C-crew-own-work-does-not-outvote-run.txt"
killfix rC

# Phase D: another run's copy keeps starting work; it never counts for this run.
shard_runner "$OTHER"; D=$!
sleep 10
mkfix rD
END=$(( $(date +%s) + ${D_SECS:-70} ))
( cd "$L/rD" && WINDOW=$WINDOW ./../watch-loop.sh "$WT" "$END" "$L/rD" fixed ) &
f=$!
while kill -0 $f 2>/dev/null; do sample D "$S"; sleep 15; done
wait $f
stop_group "$D"
{ echo "# Scenario D: run still working, nothing new in its copy, ANOTHER run's copy ($OTHER) starts a new process tree every second; watcher window ${WINDOW}s"
  report rD fixed "this change (267c59f)"; } > "$OUT/live-D-other-run-copy-does-not-count.txt"
killfix rD

cp "$S" "$OUT/live-samples.log"
tail -12 "$L/long-command.log" > "$OUT/live-A-long-command-tail.log"
echo "drive done $(date +%T)"
