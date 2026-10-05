#!/usr/bin/env bash
# pty-two-line-check.sh - does the same content survive when the internal unsets
# are typed as their own line before a base-length launch line? Fresh tmux
# window, the captain's login shell, fm-spawn's 0.3 s pacing.
set -u
unset TMUX
W=$(mktemp -d /tmp/fmtl.XXXXXX); export TMUX_TMPDIR="$W/t"; mkdir -p "$TMUX_TMPDIR"
tmux new-session -d -s probe -x 200 -y 50
names="FM_SESSION_START_STAGE_FILE FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT FM_TASKS_AXI_COMPATIBLE FM_BOOTSTRAP_NETWORK FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_DETECT_ONLY FM_BOOTSTRAP_LOCKED FM_BOOTSTRAP_VERBOSE_FACTS FM_BOOTSTRAP_PARALLEL_DIR FM_SPAWN_NO_GUARD FM_TIMING_LOG FM_TIMING_EPOCH_MS"
for trial in 1 2 3; do
  out="$W/out.$trial"
  line1="unset $names"
  pad=$(( 717 - 2 - ${#out} - 60 ))
  line2=": $(printf 'x%.0s' $(seq 1 "$pad")); env | grep -c '^FM_CREW_STATE' > '$out' || true"
  w=$(env FM_CREW_STATE_META_OVERRIDE=/stale FM_CREW_STATE_STATUS_OVERRIDE=/stale tmux new-window -d -P -F '#{window_id}' -e FM_CREW_STATE_META_OVERRIDE=/stale -e FM_CREW_STATE_STATUS_OVERRIDE=/stale -t probe:)
  sleep 0.3
  tmux send-keys -t "$w" -l "$line1"; tmux send-keys -t "$w" Enter
  sleep 0.3
  tmux send-keys -t "$w" -l "$line2"; sleep 0.3; tmux send-keys -t "$w" Enter
  for _ in $(seq 1 100); do [ -s "$out" ] && break; sleep 0.1; done
  printf 'trial %s: unset line %s bytes + launch line %s bytes -> %s\n' "$trial" "${#line1}" "${#line2}" \
    "$([ -s "$out" ] && echo "ran intact, FM_CREW_STATE_* left in the launched command: $(cat "$out")" || echo BROKEN)"
done
tmux kill-server; rm -rf "$W"
