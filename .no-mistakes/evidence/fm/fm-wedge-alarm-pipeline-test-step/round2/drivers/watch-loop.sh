#!/usr/bin/env bash
# Live driver: run the real firstmate watcher (from <bin-root>) in its normal
# blocking mode against a real private tmux pane, restarting it after every
# actionable wake the way firstmate re-arms it, until <end-epoch>.
# usage: watch-loop.sh <bin-root> <end-epoch> <fixture-dir> <label>
set -u
ROOTDIR=$1 END=$2 L=$3 LABEL=$4
cd "$L" || exit 1
export TMUX_TMPDIR="$L/tmux"
export PATH="$L/fakebin:$PATH"
export FM_LIVE_RUN_ID=${FM_LIVE_RUN_ID:-01M4Z2NDNVFJXVP6PM2K4SF305}
export FM_LIVE_NM_LOG="$L/nm-calls-$LABEL.log"
export FM_HOME="$L/home" FM_CONFIG_OVERRIDE="$L/config" FM_STATE_OVERRIDE="$L/state"
export FM_STALE_ESCALATE_SECS=${WINDOW:-60} FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=2 \
  FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
unset FM_CREW_STATE_BIN
mkdir -p "$FM_HOME" "$FM_CONFIG_OVERRIDE"
WAKES="$L/wakes-$LABEL.log"
: > "$WAKES"
DRAIN="$ROOTDIR/bin/fm-wake-drain.sh"
while [ "$(date +%s)" -lt "$END" ]; do
  "$ROOTDIR/bin/fm-watch.sh" > "$L/cycle.out" 2> "$L/cycle.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$END" ]; do sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '[%s] window closed with the watcher still blocking (no wake)\n' "$(date +%T)" >> "$WAKES"
    break
  fi
  wait "$pid"; rc=$?
  printf '[%s] watcher woke firstmate (rc=%s): %s\n' "$(date +%T)" "$rc" "$(tr '\n' ' ' < "$L/cycle.out")" >> "$WAKES"
  err="$L/drain.err"
  "$DRAIN" > /dev/null 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
done
