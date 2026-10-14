#!/usr/bin/env bash
# Live driver, real-harness variant: the crew task's recorded worktree is the
# directory where THIS session's real Claude Code harness lives, while that
# harness sits blocked on the single tool call running this script (started
# from /tmp so the tool call itself does not live in the worktree). The busy
# pane is a tmux window in a scratch directory; nothing in the worktree writes
# or starts new work for the whole window. The real watcher must escalate it as
# a possible wedge: the harness's own processes are not crew progress.
#   drive-self-harness.sh <code-root> <worktree> <label> <window-secs> <duration-secs>
set -u
CODE=$1 WT=$2 LABEL=$3 WINDOW_SECS=$4 DUR=$5
EV=/Users/hcho/.no-mistakes/evidence/01M4Y260DSWRYVXH3GWGCQCN7S/live
OUT="$EV/$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"
T=$(mktemp -d /tmp/fmlv.XXXXXX); T=$(cd "$T" && pwd -P)
cd "$T" || exit 1
unset TMUX TMUX_PANE NO_MISTAKES_GATE
export TMUX_TMPDIR="$T/tx"; mkdir -p "$TMUX_TMPDIR"
export FMLV_NM="$T/nm"; mkdir -p "$FMLV_NM"; echo none > "$FMLV_NM/mode"
FB="$T/fakebin"; mkdir -p "$FB"
cp "$EV/nm-standin.sh" "$FB/no-mistakes"; chmod +x "$FB/no-mistakes"
H="$T/home"; STATE="$H/state"; mkdir -p "$STATE" "$H/config" "$T/pane"
ID=lv; SESSION=fmlv; WIN="$SESSION:fm-$ID"
log() { printf '[t+%3ss] %s\n' "$(( $(date +%s) - START ))" "$*" | tee -a "$OUT/transcript.txt"; }
tmux new-session -d -s "$SESSION" -n "fm-$ID" -x 160 -y 40 -c "$T/pane" "printf '%s\n' 'Bash(long foreground command)  Running...'; exec sleep 100000"
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\nworktree=%s\n' "$WIN" "$WT" > "$STATE/$ID.meta"
printf 'working: validating\n' > "$STATE/$ID.status"
"$CODE/bin/fm-busy-event.sh" arm "$STATE" "$ID" >/dev/null
touch -t "$(date -r $(( $(date +%s) - 4000 )) +%Y%m%d%H%M.%S)" "$STATE/$ID.meta"
cleanup() {
  [ -n "${WPID:-}" ] && { kill "$WPID" 2>/dev/null; sleep 1; kill -KILL "$WPID" 2>/dev/null; }
  tmux kill-server 2>/dev/null
  cd /tmp && rm -rf "$T"
}
trap cleanup EXIT
harness=$(ps -o ppid= -p "$PPID" | tr -d ' ')
START=$(date +%s)
{
  echo "scenario=self-harness code=$CODE ($(git -C "$CODE" rev-parse --short HEAD))"
  echo "window FM_STALE_ESCALATE_SECS=$WINDOW_SECS, duration ${DUR}s, recorded worktree $WT"
  echo "tool-call shell $PPID (cwd $(lsof -a -d cwd -p "$PPID" -Fn 2>/dev/null | sed -n 's/^n//p')), its parent harness $harness: $(ps -o command= -p "$harness" | cut -c1-60)"
  echo "fm-crew-state.sh at start: $(PATH="$FB:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" "$CODE/bin/fm-crew-state.sh" "$ID" 2>&1)"
} | tee "$OUT/transcript.txt"
# Every process whose working directory is in the recorded worktree, sampled
# through the run, so the transcript shows what lived there.
( while :; do
    echo "== $(date +%H:%M:%S)"
    lsof -d cwd -Fpn 2>/dev/null | awk -v wt="$WT" '/^p/ { p = substr($0, 2) } /^n/ { n = substr($0, 2); if (n == wt || index(n, wt "/") == 1) print p }' \
      | while read -r pid; do ps -o pid=,ppid=,etime=,command= -p "$pid" | cut -c1-140; done
    echo "-- children of harness $harness:"
    ps -A -o pid=,ppid=,etime=,command= | awk -v h="$harness" '$2==h' | cut -c1-140
    sleep 60
  done ) > "$OUT/worktree-processes.txt" 2>&1 &
SAMPLER=$!
round=0 stale=0
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
  round=$((round + 1))
  PATH="$FB:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$H/config" \
    FM_STALE_ESCALATE_SECS="$WINDOW_SECS" FM_BUSY_TURN_MAX_SECS=20 FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$CODE/bin/fm-watch.sh" > "$OUT/watch-$round.out" 2> "$OUT/watch-$round.err" &
  WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - START )) -lt "$DUR" ]; do sleep 0.5; done
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
kill "$SAMPLER" 2>/dev/null
log "summary: $stale possible-wedge/stale wake(s) in ${DUR}s"
grep -E 'absorbed|stale|wedge' "$STATE/.watch-triage.log" > "$OUT/triage.log" 2>/dev/null || true
