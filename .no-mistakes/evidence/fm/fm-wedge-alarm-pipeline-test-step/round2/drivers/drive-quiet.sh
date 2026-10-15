#!/usr/bin/env bash
# Round 2 live drive at realistic windows, with the live run's `axi status`
# answer passed through forwarder-quiet.sh (real CLI answer; only the active
# step's last_activity/agent_pid rewritten to the configured-command phase's
# quiet rendering). Real bin/fm-watch.sh, real bin/fm-crew-state.sh, real
# private tmux pane, real process table, real run copy.
# usage: drive-quiet.sh <fixture-root> A|BCD
#   A    real bin/fm-test-run.sh in the run's own copy, 60s window, this change
#        and base fbd3c9b side by side
#   BCD  20s window, this change: B nothing new anywhere; C the crew's own
#        worktree starts work; D another run's copy starts work
set -u
L=$1 PHASES=$2
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
OTHER=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4YJKR5WFZJMRQYGKGBZH4FV
RUN=01M4Z2NDNVFJXVP6PM2K4SF305
OUT=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round2
FWD=$OUT/drivers/forwarder-quiet.sh
cd "$L" || exit 1
set -m
export FM_QUIET_SINCE=${FM_QUIET_SINCE:-$(( $(date +%s) - 180 ))}

mkfix() {  # <name>
  local d="$L/$1"
  rm -rf "$d"; mkdir -p "$d/state" "$d/fakebin" "$d/tmux"
  cp "$FWD" "$d/fakebin/no-mistakes"; chmod +x "$d/fakebin/no-mistakes"
  printf 'window=fm:fm-wedgelive\nkind=ship\nworktree=%s\n' "$L/wt2" > "$d/state/wedgelive.meta"
  printf 'paused: waiting on the validation response\n' > "$d/state/wedgelive.status"
  TMUX_TMPDIR="$d/tmux" tmux -f /dev/null new-session -d -s fm -n fm-wedgelive -x 120 -y 30 "$L/pane.sh"
}
killfix() { TMUX_TMPDIR="$L/$1/tmux" tmux kill-server 2>/dev/null || true; }
sample() {  # <label> <file>
  local row lc
  row=$(cd /tmp && PATH="$L/$1/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN no-mistakes axi status 2>/dev/null | sed -n '/active_steps/{n;p;}' | sed 's/^ *//')
  lc=$(pgrep -f "bin/fm-test-run.sh tests/fm-crew-state" | head -1)
  printf '[%s] %s | axi active step as the watcher reads it: %s | long command: %s\n' "$(date +%T)" "$1" "$row" \
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
shard_runner() { ( cd "$1" && exec bash -c 'while :; do bash -c "sleep 2 & wait" & sleep 1; done' ) & }
stop_group() {
  kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
  sleep 3
  kill -KILL -- "-$1" 2>/dev/null || true
}
drive_one() {  # <fixture> <bin-root> <label> <secs> <window>
  local end=$(( $(date +%s) + $4 ))
  ( cd "$L/$1" && WINDOW=$5 ../watch-loop.sh "$2" "$end" "$L/$1" "$3" ) &
}

S="$OUT/live-quiet-samples.log"
case "$PHASES" in
  A)
    : > "$S"
    ( cd "$WT" && exec bin/fm-test-run.sh tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh ) > "$L/long-command-quiet.log" 2>&1 &
    LONG=$!
    sleep 12
    mkfix qAf; mkfix qAb
    drive_one qAf "$WT" fixed "${A_SECS:-270}" 60; f=$!
    drive_one qAb "$L/base" base "${A_SECS:-270}" 60; b=$!
    while kill -0 $f 2>/dev/null || kill -0 $b 2>/dev/null; do sample qAf "$S"; sleep 20; done
    wait $f $b
    stop_group "$LONG"
    { echo "# Scenario A (60s window): real bin/fm-test-run.sh running in the run's own copy ($WT) the whole time; both watchers concurrently; axi status via forwarder-quiet.sh"
      report qAf fixed "this change (267c59f)"; report qAb base "base (fbd3c9b)"; } > "$OUT/live-quiet-A-60s-window-fixed-vs-base.txt"
    killfix qAf; killfix qAb
    tail -6 "$L/long-command-quiet.log" > "$OUT/live-quiet-A-long-command-tail.log"
    ;;
  BCD)
    mkfix qB
    drive_one qB "$WT" fixed "${X_SECS:-80}" 20; f=$!
    while kill -0 $f 2>/dev/null; do sample qB "$S"; sleep 20; done
    wait $f
    { echo "# Scenario B (20s window): run working, step quiet, nothing new in the run's copy (its long command is gone)"
      report qB fixed "this change (267c59f)"; } > "$OUT/live-quiet-B-step-command-stopped.txt"
    killfix qB
    shard_runner "$L/wt2"; C=$!
    sleep 5
    mkfix qC
    drive_one qC "$WT" fixed "${X_SECS:-80}" 20; f=$!
    while kill -0 $f 2>/dev/null; do sample qC "$S"; sleep 20; done
    wait $f
    stop_group "$C"
    { echo "# Scenario C (20s window): run working, step quiet, the crew's OWN worktree ($L/wt2) starts a new process tree every second"
      report qC fixed "this change (267c59f)"; } > "$OUT/live-quiet-C-crew-own-work-does-not-outvote-run.txt"
    killfix qC
    shard_runner "$OTHER"; D=$!
    sleep 5
    mkfix qD
    drive_one qD "$WT" fixed "${X_SECS:-80}" 20; f=$!
    while kill -0 $f 2>/dev/null; do sample qD "$S"; sleep 20; done
    wait $f
    stop_group "$D"
    { echo "# Scenario D (20s window): run working, step quiet, ANOTHER run's copy ($OTHER) starts a new process tree every second"
      report qD fixed "this change (267c59f)"; } > "$OUT/live-quiet-D-other-run-copy-does-not-count.txt"
    killfix qD
    ;;
esac
echo "drive-quiet $PHASES done $(date +%T)"
