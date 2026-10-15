#!/usr/bin/env bash
# Round 3 live drive (target 6273c67) against the real no-mistakes daemon's live
# run 01M4Z2NDNVFJXVP6PM2K4SF305, whose own copy is this worktree.
# usage: drive.sh <fixture-root from setup.sh> probe|A|BCD
# Every watcher phase uses a fresh crew fixture (own state dir, own private tmux
# server with one static idle worker pane) and the real bin/fm-watch.sh in its
# normal blocking mode, re-armed after every wake by watch-loop.sh.
# `axi status` goes through forwarder-quiet.sh: the real CLI answer for the live
# run, with only the active step's last_activity/agent_pid cells rewritten to how
# the daemon renders a step running its own configured command
# ("quiet <m>m<s>s ago: running tests",""). This agent-driven test step's real
# last_activity is refreshed by its agent, which a configured-command phase never does.
#   probe  the crew-state read, this change vs base, unmodified and quiet answers
#   A      real bin/fm-test-run.sh in the run's own copy, 60s window, this change
#          and base fbd3c9b side by side
#   BCD    20s window, this change: B nothing new anywhere; C the crew's own
#          worktree starts work; D another run's copy starts work
set -u
L=$1 PHASES=$2
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
OTHER=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4YJKR5WFZJMRQYGKGBZH4FV
RUN=01M4Z2NDNVFJXVP6PM2K4SF305
OUT=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round3
FWDQ=$OUT/drivers/forwarder-quiet.sh
FWD=$OUT/drivers/forwarder.sh
NM=/usr/local/bin/no-mistakes
cd "$L" || exit 1
set -m
export FM_QUIET_SINCE=${FM_QUIET_SINCE:-$(( $(date +%s) - 180 ))}
LONGPAT="bin/fm-test-run.sh --jobs 1 tests/fm-crew-state"

mkfix() {  # <name> [forwarder]
  local d="$L/$1"
  rm -rf "$d"; mkdir -p "$d/state" "$d/fakebin" "$d/tmux"
  cp "${2:-$FWDQ}" "$d/fakebin/no-mistakes"; chmod +x "$d/fakebin/no-mistakes"
  printf 'window=fm:fm-wedgelive\nkind=ship\nworktree=%s\n' "$L/wt2" > "$d/state/wedgelive.meta"
  printf 'paused: waiting on the validation response\n' > "$d/state/wedgelive.status"
  TMUX_TMPDIR="$d/tmux" tmux -f /dev/null new-session -d -s fm -n fm-wedgelive -x 120 -y 30 "$L/pane.sh"
}
killfix() { TMUX_TMPDIR="$L/$1/tmux" tmux kill-server 2>/dev/null || true; }
sample() {  # <fixture> <label> <file>
  local row lc
  row=$(cd /tmp && PATH="$L/$1/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN no-mistakes axi status 2>/dev/null | sed -n '/active_steps/{n;p;}' | sed 's/^ *//')
  lc=$(pgrep -f "$LONGPAT" | head -1)
  printf '[%s] %s | load %s | axi active step as the watcher reads it: %s | long command: %s\n' "$(date +%T)" "$2" \
    "$(sysctl -n vm.loadavg | awk '{print $2}')" "$row" \
    "${lc:+pid $lc etime $(ps -o etime= -p "$lc" | tr -d ' ') cwd $(lsof -a -d cwd -p "$lc" -Fn 2>/dev/null | sed -n 's/^n//p')}" >> "$3"
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
crew_read() {  # <fixture> <bin-root>
  PATH="$L/$1/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/$1/state" TMUX_TMPDIR="$L/$1/tmux" "$2/bin/fm-crew-state.sh" wedgelive
}
# The quiet window opens after this driver started, so the driver itself (cwd
# outside the run's copy) is the pre-window ancestor of its own reads, and the
# step agent's own tool calls (cwd: the run's copy) are not running meanwhile.
evidence_probe() {  # <fixture> <window>: crew_progress_evidence over the real helper, anchor 15s old
  local a="$L/anchor-$1"
  : > "$a"; sleep 15
  echo "\$ crew_progress_evidence wedgelive <state> <anchor 15s old> $2   # this change, $(date +%T)"
  PATH="$L/$1/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/$1/state" TMUX_TMPDIR="$L/$1/tmux" \
    bash -c '. "$1/bin/fm-classify-lib.sh"; crew_progress_evidence wedgelive "$2" "$3" "$4"; echo " (rc=$?)"' _ "$WT" "$L/$1/state" "$a" "$2"
}

S="$OUT/live-samples.log"
case "$PHASES" in
  probe)
    mkfix pU "$FWD"; mkfix pQ "$FWDQ"
    {
      echo "\$ no-mistakes axi status --run $RUN   # real daemon, $(date +%T)"
      (cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null | sed -n '/^run:/,/^  head:/p;/active_steps/,/^branch_sync/p')
      echo
      echo "# unmodified daemon answer"
      echo "\$ bin/fm-crew-state.sh wedgelive   # this change (6273c67)"; crew_read pU "$WT"
      echo "\$ bin/fm-crew-state.sh wedgelive   # base fbd3c9b"; crew_read pU "$L/base"
      echo
      echo "# configured-command rendering (forwarder-quiet.sh)"
      echo "\$ no-mistakes axi status   # active_steps as the watcher reads it"
      (cd /tmp && PATH="$L/pQ/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN no-mistakes axi status 2>/dev/null | sed -n '/active_steps/,/^branch_sync/p')
      echo "\$ bin/fm-crew-state.sh wedgelive   # this change (6273c67)"; crew_read pQ "$WT"
      echo "\$ bin/fm-crew-state.sh wedgelive   # base fbd3c9b"; crew_read pQ "$L/base"
      echo
      echo "\$ fm_nm_run_worktree $RUN   # NM_HOME=${NM_HOME:-unset}"
      bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_worktree "$2"' _ "$WT" "$RUN"
      echo "\$ fm_nm_run_worktree 01NOSUCHRUN"
      bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_worktree "$2"; echo "(printed nothing above: rc=$?)"' _ "$WT" 01NOSUCHRUN
      echo
      echo "# no long command in the run's copy yet"
      evidence_probe pQ 60
    } > "$OUT/live-crew-state-read.txt" 2>&1
    killfix pU; killfix pQ
    ;;
  A)
    : > "$S"
    ( cd "$WT" && exec bin/fm-test-run.sh --jobs 1 tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh tests/fm-wake-queue.test.sh ) > "$OUT/long-command-fm-test-run.log" 2>&1 &
    LONG=$!
    echo "[$(date +%T)] long command started (pid $LONG)" >> "$S"
    sleep 12
    mkfix qAf; mkfix qAb
    drive_one qAf "$WT" fixed "${A_SECS:-330}" 60; f=$!
    drive_one qAb "$L/base" base "${A_SECS:-330}" 60; b=$!
    sleep 30
    { evidence_probe qAf 60; echo; echo "# base fbd3c9b, same moment"
      PATH="$L/qAf/fakebin:$PATH" FM_LIVE_RUN_ID=$RUN FM_STATE_OVERRIDE="$L/qAf/state" TMUX_TMPDIR="$L/qAf/tmux" \
        bash -c '. "$1/bin/fm-classify-lib.sh"; crew_progress_evidence wedgelive "$2" "$3" 60; echo " (rc=$?)"' _ "$L/base" "$L/qAf/state" "$L/anchor-qAf"
    } > "$OUT/live-A-progress-evidence-probe.txt" 2>&1
    while kill -0 $f 2>/dev/null || kill -0 $b 2>/dev/null; do sample qAf A "$S"; sleep 20; done
    wait $f $b
    if kill -0 "$LONG" 2>/dev/null; then
      echo "[$(date +%T)] phase A over, long command still running; stopping it" >> "$S"
      stop_group "$LONG"
    else
      echo "[$(date +%T)] phase A over, long command had already ended" >> "$S"
    fi
    { echo "# Scenario A (60s window): real bin/fm-test-run.sh running in the run's own copy ($WT); both watchers concurrently; axi status via forwarder-quiet.sh"
      grep -E 'long command|FM_TEST_(BEGIN|END)' "$S" "$OUT/long-command-fm-test-run.log" | sed 's|^[^:]*/||'
      echo
      report qAf fixed "this change (6273c67)"; report qAb base "base (fbd3c9b)"; } > "$OUT/live-A-60s-window-fixed-vs-base.txt"
    killfix qAf; killfix qAb
    ;;
  A6)
    # Unmodified daemon answers (forwarder.sh), 6s window: while the step agent
    # sits blocked on this drive its real last_activity ages past 6s, so the
    # run-step process branch is reached with nothing rewritten.
    ( cd "$WT" && exec bin/fm-test-run.sh --jobs 1 tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh tests/fm-wake-queue.test.sh ) > "$L/long-command-a6.log" 2>&1 &
    LONG=$!
    S6="$OUT/live-A6-samples.log"; : > "$S6"
    echo "[$(date +%T)] long command started (pid $LONG)" >> "$S6"
    sleep 12
    mkfix uAf "$FWD"; mkfix uAb "$FWD"
    drive_one uAf "$WT" fixed "${A6_SECS:-150}" 6; f=$!
    drive_one uAb "$L/base" base "${A6_SECS:-150}" 6; b=$!
    while kill -0 $f 2>/dev/null || kill -0 $b 2>/dev/null; do sample uAf A6 "$S6"; sleep 15; done
    wait $f $b
    stop_group "$LONG"
    { echo "# Scenario A6 (6s window): real bin/fm-test-run.sh in the run's own copy ($WT); both watchers concurrently; axi status answers unmodified (forwarder.sh pins --run only)"
      cat "$S6"; echo
      report uAf fixed "this change (6273c67)"; report uAb base "base (fbd3c9b)"; } > "$OUT/live-A6-6s-window-unmodified-fixed-vs-base.txt"
    killfix uAf; killfix uAb
    ;;
  BCD)
    mkfix qB
    drive_one qB "$WT" fixed "${X_SECS:-80}" 20; f=$!
    sleep 25; evidence_probe qB 20 > "$OUT/live-B-progress-evidence-probe.txt" 2>&1
    while kill -0 $f 2>/dev/null; do sample qB B "$S"; sleep 20; done
    wait $f
    { echo "# Scenario B (20s window): run working, step quiet, nothing new in the run's copy (its long command is gone)"
      report qB fixed "this change (6273c67)"; } > "$OUT/live-B-step-command-stopped.txt"
    killfix qB
    shard_runner "$L/wt2"; C=$!
    sleep 5
    mkfix qC
    drive_one qC "$WT" fixed "${X_SECS:-80}" 20; f=$!
    sleep 25; evidence_probe qC 20 > "$OUT/live-C-progress-evidence-probe.txt" 2>&1
    while kill -0 $f 2>/dev/null; do sample qC C "$S"; sleep 20; done
    wait $f
    stop_group "$C"
    { echo "# Scenario C (20s window): run working, step quiet, the crew's OWN worktree ($L/wt2) starts a new process tree every second"
      report qC fixed "this change (6273c67)"; } > "$OUT/live-C-crew-own-work-does-not-outvote-run.txt"
    killfix qC
    shard_runner "$OTHER"; D=$!
    sleep 5
    mkfix qD
    drive_one qD "$WT" fixed "${X_SECS:-80}" 20; f=$!
    sleep 25; evidence_probe qD 20 > "$OUT/live-D-progress-evidence-probe.txt" 2>&1
    while kill -0 $f 2>/dev/null; do sample qD D "$S"; sleep 20; done
    wait $f
    stop_group "$D"
    { echo "# Scenario D (20s window): run working, step quiet, ANOTHER run's copy ($OTHER) starts a new process tree every second"
      report qD fixed "this change (6273c67)"; } > "$OUT/live-D-other-run-copy-does-not-count.txt"
    killfix qD
    ;;
esac
echo "drive $PHASES done $(date +%T)"
