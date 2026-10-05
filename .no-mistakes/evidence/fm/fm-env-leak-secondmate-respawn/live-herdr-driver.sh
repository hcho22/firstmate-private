#!/usr/bin/env bash
# Live Herdr check: start a REAL Herdr server for an isolated lab session through
# fm_backend_herdr_server_ensure from a launcher environment that carries every
# Firstmate internal setting plus a home pin and harness marker, then read what
# a pane created by that server actually inherits.
# usage: live-herdr-driver.sh <product-root> <out-file>
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M44BRNARCVGWAD2D76BQE4P0
PRODUCT=$1 OUT=$2
# shellcheck source=/dev/null
. "$WT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-live-env-$$"
export HERDR_SESSION="$SESSION"
trap 'herdr_safe_stop_and_delete "$SESSION"' EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }

NAMES="FM_SESSION_START_STAGE_FILE FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE
FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT FM_TASKS_AXI_COMPATIBLE FM_BOOTSTRAP_NETWORK
FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_DETECT_ONLY FM_BOOTSTRAP_LOCKED FM_BOOTSTRAP_VERBOSE_FACTS
FM_BOOTSTRAP_PARALLEL_DIR FM_SPAWN_NO_GUARD FM_TIMING_LOG FM_TIMING_EPOCH_MS FM_HOME FM_STATE_OVERRIDE
CLAUDECODE HERDR_LIVE_SENTINEL"

{
  printf '== product: %s\n== herdr %s, isolated session %s\n' "$PRODUCT" "$(herdr --version 2>&1)" "$SESSION"
  env FM_SESSION_START_STAGE_FILE=/tmp/stale-stage FM_CREW_STATE_META_OVERRIDE=/tmp/stale.meta \
    FM_CREW_STATE_STATUS_OVERRIDE=/tmp/stale.status FM_HOME_SUMMARY_IF_IDLE=0 FM_HOME_SUMMARY_WORKER_BEST_EFFORT=1 \
    FM_TASKS_AXI_COMPATIBLE=1 FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=1 FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_BOOTSTRAP_PARALLEL_DIR=/tmp/stale-par FM_SPAWN_NO_GUARD=1 \
    FM_TIMING_LOG=/tmp/stale-timings FM_TIMING_EPOCH_MS=1 FM_HOME=/tmp/launcher-home \
    FM_STATE_OVERRIDE=/tmp/launcher-state CLAUDECODE=1 HERDR_LIVE_SENTINEL=kept \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$1"' "$PRODUCT" "$SESSION"
  printf 'server_ensure exit=%s\n' "$?"
  printf '== server status\n'
  herdr status --json --session "$SESSION" 2>&1 | jq -c '.server' 2>&1
  # A pane the server creates, from a client that carries none of the names, shows
  # exactly what the server itself hands on.
  probe=$(mktemp "${TMPDIR:-/tmp}/fm-live-herdr-pane.XXXXXX")
  unset_args=()
  for n in $NAMES; do unset_args+=(-u "$n"); done
  ws=$(env "${unset_args[@]}" herdr workspace create --cwd /tmp --session "$SESSION" 2>&1)
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  printf '== workspace created by a clean client, root pane: %s\n' "$pane"
  env "${unset_args[@]}" herdr pane run "$pane" "env | sort > $probe" --session "$SESSION" >/dev/null 2>&1
  deadline=$((SECONDS + 30))
  while [ ! -s "$probe" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  printf '== pane environment handed on by the real Herdr server\n'
  for n in $NAMES; do
    if grep -q "^$n=" "$probe" 2>/dev/null; then printf '  PRESENT %s\n' "$(grep "^$n=" "$probe")"; else printf '  absent  %s\n' "$n"; fi
  done
  [ -s "$probe" ] || printf '  (pane never recorded its environment)\n'
  rm -f "$probe"
} > "$OUT" 2>&1
cat "$OUT"
