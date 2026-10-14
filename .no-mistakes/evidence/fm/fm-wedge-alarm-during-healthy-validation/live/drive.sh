#!/usr/bin/env bash
# Live driver: one crew in a real (private) tmux server, supervised by the real
# bin/fm-watch.sh of <code-root> in a temporary firstmate home. Every wake the
# watcher queues is recorded, drained and acknowledged exactly as firstmate's
# handling turn does, and the watcher is re-armed, until <duration> elapses.
#   drive.sh <code-root> <scenario> <label> <duration-secs>
# Scenarios: sync-wait ci-wait ci-red stalled-step fg-tests fg-hung-harness
#            parked-writes parked-hung
set -u
CODE=$1 SCEN=$2 LABEL=$3 DUR=$4
WINDOW_SECS=${WINDOW_SECS:-30}
EV=/Users/hcho/.no-mistakes/evidence/01M4Y260DSWRYVXH3GWGCQCN7S/live
OUT="$EV/$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"
T=$(mktemp -d /tmp/fmlv.XXXXXX); T=$(cd "$T" && pwd -P)
unset TMUX TMUX_PANE NO_MISTAKES_GATE
export TMUX_TMPDIR="$T/tx"; mkdir -p "$TMUX_TMPDIR"
export FMLV_NM="$T/nm"; mkdir -p "$FMLV_NM"
FB="$T/fakebin"; mkdir -p "$FB"
cp "$EV/nm-standin.sh" "$FB/no-mistakes"; chmod +x "$FB/no-mistakes"
H="$T/home"; STATE="$H/state"; mkdir -p "$STATE" "$H/config"
WT="$T/wt"; ID=lv; SESSION="fmlv"; WIN="$SESSION:fm-$ID"
BG_PIDS=()
log() { printf '[t+%3ss] %s\n' "$(( $(date +%s) - START ))" "$*" | tee -a "$OUT/transcript.txt"; }

# --- crew worktree ---------------------------------------------------------
case "$SCEN" in
  fg-tests)
    mkdir -p "$WT"
    (cd /Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Y260DSWRYVXH3GWGCQCN7S && tar --exclude ./.git -cf - .) | (cd "$WT" && tar -xf -)
    ;;
  *) mkdir -p "$WT"; printf 'seed\n' > "$WT/README" ;;
esac
git -C "$WT" init -q -b "fm/$ID"
git -C "$WT" -c user.name=t -c user.email=t@t add -A
git -C "$WT" -c user.name=t -c user.email=t@t commit -qm seed

# --- pane command ----------------------------------------------------------
case "$SCEN" in
  sync-wait|ci-wait|ci-red|stalled-step)
    PANE_CMD="printf '%s\n' '> no-mistakes axi run (synchronous, waiting on the validation response)'; exec sleep 100000" ;;
  fg-tests)
    PANE_CMD="unset TMUX TMUX_PANE; while :; do bin/fm-test-run.sh ${FG_TESTS:-tests/fm-crew-state.test.sh tests/fm-bearings-snapshot.test.sh tests/fm-procevent.test.sh tests/fm-public-followup.test.sh}; done" ;;
  fg-hung-harness)
    # The crew's harness lives in the worktree: its foreground tool command hangs
    # and starts nothing, while it keeps restarting one lone housekeeping child,
    # a real `caffeinate`, as Claude Code does for the whole of a blocked call.
    PANE_CMD="exec bash -c 'sleep 100000 & while :; do caffeinate -i -t 8 & wait \$!; done'" ;;
  parked-writes)
    PANE_CMD="exec bash -c 'while :; do date >> notes.txt; sleep 3; done'" ;;
  parked-hung)
    PANE_CMD="exec sleep 100000" ;;
esac
tmux new-session -d -s "$SESSION" -n "fm-$ID" -x 160 -y 40 -c "$WT" "$PANE_CMD"

# --- task record, status log, busy state --------------------------------------
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\nworktree=%s\n' "$WIN" "$WT" > "$STATE/$ID.meta"
case "$SCEN" in
  sync-wait) printf 'paused: waiting on the validation response (no-mistakes axi run)\n' > "$STATE/$ID.status" ;;
  *) printf 'working: validating\n' > "$STATE/$ID.status" ;;
esac
gen=$("$CODE/bin/fm-busy-event.sh" arm "$STATE" "$ID")
case "$SCEN" in
  sync-wait|ci-wait|ci-red|stalled-step)
    # Idle pane: the harness reported its turn settled.
    "$CODE/bin/fm-busy-event.sh" apply "$STATE" "$ID" idle --gen "$gen" --source claude-hook --event Stop >/dev/null ;;
  *)
    # Busy pane inside one long turn that started long ago (the spawn record is
    # past FM_BUSY_TURN_MAX_SECS and no turn has completed).
    touch -t "$(date -r $(( $(date +%s) - 4000 )) +%Y%m%d%H%M.%S)" "$STATE/$ID.meta" ;;
esac

# --- pipeline stand-in state -----------------------------------------------
case "$SCEN" in
  sync-wait)
    echo fixing > "$FMLV_NM/mode"; touch "$FMLV_NM/activity"
    ACTIVE_SECS=${ACTIVE_SECS:-$(( DUR - 80 ))}
    # The pipeline's own agent producing output every 5s, then falling silent.
    ( end=$(( $(date +%s) + ACTIVE_SECS )); while [ "$(date +%s)" -lt "$end" ]; do touch "$FMLV_NM/activity"; sleep 5; done; date +%s > "$FMLV_NM/activity-stopped" ) &
    BG_PIDS+=($!) ;;
  stalled-step)
    echo fixing > "$FMLV_NM/mode"; touch -t "$(date -r $(( $(date +%s) - 900 )) +%Y%m%d%H%M.%S)" "$FMLV_NM/activity"
    # The crew keeps writing its worktree while the pipeline step is silent.
    ( while :; do date >> "$WT/scratch.txt"; sleep 3; done ) &
    BG_PIDS+=($!) ;;
  ci-wait|ci-red)
    echo ci > "$FMLV_NM/mode"; echo $(( $(date +%s) - 1790 )) > "$FMLV_NM/ci-epoch"
    { echo 'monitoring CI for PR #2 (timeout: 4h0m0s)...'; echo 'CI checks running, waiting for results...'; } > "$FMLV_NM/ci.log"
    [ "$SCEN" = ci-red ] && echo 'issues detected: merge conflict - auto-fixing (attempt 2/10)...' >> "$FMLV_NM/ci.log" ;;
  parked-writes|parked-hung) echo parked > "$FMLV_NM/mode" ;;
  *) echo none > "$FMLV_NM/mode" ;;
esac

cleanup() {
  [ -n "${WPID:-}" ] && { kill "$WPID" 2>/dev/null; sleep 1; kill -KILL "$WPID" 2>/dev/null; }
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  tmux kill-server 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

START=$(date +%s)
{
  echo "scenario=$SCEN code=$CODE ($(git -C "$CODE" rev-parse --short HEAD 2>/dev/null || cat "$CODE/.fmlv-rev" 2>/dev/null))"
  echo "window FM_STALE_ESCALATE_SECS=$WINDOW_SECS, duration ${DUR}s, tmux target $WIN, worktree $WT"
  echo "fm-crew-state.sh at start: $(PATH="$FB:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" "$CODE/bin/fm-crew-state.sh" "$ID" 2>&1)"
} | tee "$OUT/transcript.txt"
round=0 stale=0
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
  round=$((round + 1))
  PATH="$FB:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$H/config" \
    FM_STALE_ESCALATE_SECS="$WINDOW_SECS" FM_BUSY_TURN_MAX_SECS=20 FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$CODE/bin/fm-watch.sh" > "$OUT/watch-$round.out" 2> "$OUT/watch-$round.err" &
  WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    [ "$round" -eq 1 ] && [ $(( $(date +%s) - START )) -ge $(( DUR / 2 )) ] && [ ! -e "$OUT/mid.done" ] && {
      tmux capture-pane -p -t "$WIN" > "$OUT/pane-mid.txt" 2>/dev/null
      pane_pid=$(tmux display-message -p -t "$WIN" '#{pane_pid}')
      ps -A -o pid=,ppid=,etime=,command= | awk -v r="$pane_pid" '{p[$1]=$2; l[$1]=$0} END {for (x in l) {y=x; while (y in p && y!=r && y>1) y=p[y]; if (y==r) print l[x]}}' | sort -n > "$OUT/crew-processes-mid.txt"
      : > "$OUT/mid.done"
    }
    sleep 0.5
  done
  if kill -0 "$WPID" 2>/dev/null; then
    kill "$WPID" 2>/dev/null; sleep 1; kill -KILL "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
    log "watcher still blocking at the end of the run: no wake queued in the last round"
    WPID=; break
  fi
  wait "$WPID" 2>/dev/null; WPID=
  reason=$(tr '\n' ' ' < "$OUT/watch-$round.out")
  case "$reason" in stale:*) stale=$((stale + 1)); log "WAKE (stale #$stale): $reason" ;; *) log "WAKE: $reason" ;; esac
  err="$OUT/drain-$round.err"
  FM_STATE_OVERRIDE="$STATE" "$CODE/bin/fm-wake-drain.sh" > "$OUT/drain-$round.out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$STATE" "$CODE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
done
[ -e "$FMLV_NM/activity-stopped" ] && log "pipeline stand-in agent stopped producing output at t+$(( $(cat "$FMLV_NM/activity-stopped") - START ))s"
log "summary: $stale possible-wedge/stale wake(s) in ${DUR}s"
echo "fm-crew-state.sh at end: $(PATH="$FB:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" "$CODE/bin/fm-crew-state.sh" "$ID" 2>&1)" | tee -a "$OUT/transcript.txt"
tmux capture-pane -p -t "$WIN" > "$OUT/pane-end.txt" 2>/dev/null
grep -E 'absorbed|stale|wedge' "$STATE/.watch-triage.log" > "$OUT/triage.log" 2>/dev/null || true
rm -f "$OUT/mid.done"
