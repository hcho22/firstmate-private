#!/usr/bin/env bash
# Scenario A at a 60s window again, with an instrumented temp copy of this
# change's bin/ (DIAG lines only, logic unchanged) to see each escalation-time
# decision. usage: drive-quiet-diag.sh <fixture-root> <secs>
set -u
L=$1 SECS=$2
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
OUT=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round2
cd "$L" || exit 1
set -m
export FM_QUIET_SINCE=$(( $(date +%s) - 180 )) FM_DIAG_LOG="$L/diag.log"
: > "$FM_DIAG_LOG"
d="$L/qDiag"; rm -rf "$d"; mkdir -p "$d/state" "$d/fakebin" "$d/tmux"
cp "$OUT/drivers/forwarder-quiet.sh" "$d/fakebin/no-mistakes"; chmod +x "$d/fakebin/no-mistakes"
printf 'window=fm:fm-wedgelive\nkind=ship\nworktree=%s\n' "$L/wt2" > "$d/state/wedgelive.meta"
printf 'paused: waiting on the validation response\n' > "$d/state/wedgelive.status"
( cd "$WT" && exec bin/fm-test-run.sh tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh ) > "$L/long-command-diag.log" 2>&1 &
LONG=$!
sleep 12
TMUX_TMPDIR="$d/tmux" tmux -f /dev/null new-session -d -s fm -n fm-wedgelive -x 120 -y 30 "$L/pane.sh"
end=$(( $(date +%s) + SECS ))
b="$L/qDiagBase"; rm -rf "$b"; mkdir -p "$b/state" "$b/fakebin" "$b/tmux"; cp "$d/fakebin/no-mistakes" "$b/fakebin/"; cp "$d/state/wedgelive.meta" "$d/state/wedgelive.status" "$b/state/"
TMUX_TMPDIR="$b/tmux" tmux -f /dev/null new-session -d -s fm -n fm-wedgelive -x 120 -y 30 "$L/pane.sh"
( cd "$d" && WINDOW=60 ../watch-loop.sh "$L/instr" "$end" "$d" fixed ) &
f=$!
( cd "$b" && WINDOW=60 ../watch-loop.sh "$L/base" "$end" "$b" base ) &
bb=$!
wait $f $bb
TMUX_TMPDIR="$b/tmux" tmux kill-server 2>/dev/null
kill -TERM -- "-$LONG" 2>/dev/null; sleep 3; kill -KILL -- "-$LONG" 2>/dev/null
TMUX_TMPDIR="$d/tmux" tmux kill-server 2>/dev/null
{ echo "# Scenario A rerun (60s window), instrumented copy of this change's bin/"
  echo "## wakes"; cat "$d/wakes-fixed.log"
  echo "## triage"; grep -v "absorbed non-terminal stale (provably working): " "$d/state/.watch-triage.log"
  echo "## long command"; grep -E "FM_TEST_(BEGIN|END)|interrupted" "$L/long-command-diag.log"
  echo "## base fbd3c9b, same time: wakes"; cat "$b/wakes-base.log"
  echo "## DIAG (evidence reads and process probes in the run's copy; cwd lines filtered to the run copy)"
  grep -E "DIAG evidence read|DIAG probe dir=$WT|DIAG cwd .*$WT" "$FM_DIAG_LOG"
} > "$OUT/diag-quiet-A-60s-instrumented.txt"
