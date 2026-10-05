#!/usr/bin/env bash
# live-herdr-server-env.sh <repo-dir-containing-bin> <label>
# Starts a REAL Herdr server through the adapter's fm_backend_herdr_server_ensure
# on a private, throwaway lab session (bin/fm-herdr-lab.sh isolation and
# teardown, never the default session) from an environment carrying
# Firstmate's internal handoff settings, a launcher home, and the Claude marker.
# A pane is then created and populated from a client environment that carries
# none of them, so what the pane records is exactly what the server hands on.
set -u
R=$1 LABEL=$2
export FM_GATE_REFUSE_BYPASS=1
unset NO_MISTAKES_GATE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
# shellcheck source=/dev/null
. "$R/bin/fm-herdr-lab.sh"
SESSION="fm-lab-envlive-$$"
export HERDR_SESSION="$SESSION"
W=$(mktemp -d /tmp/fmhl.XXXXXX)
trap 'fm_herdr_lab_teardown "$SESSION"; rm -rf "$W"' EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 2; }
# shellcheck source=/dev/null
. "$R/bin/fm-backend.sh"
fm_backend_source herdr || exit 2
echo "=== live herdr server env: $LABEL ($(herdr --version 2>/dev/null), lab session $SESSION) ==="
polluted=(FM_HOME=/tmp/wrong-home FM_STATE_OVERRIDE=/tmp/wrong-state CLAUDECODE=1
  FM_SESSION_START_STAGE_FILE=/tmp/stale-stage FM_CREW_STATE_META_OVERRIDE=/tmp/stale.meta
  FM_CREW_STATE_STATUS_OVERRIDE=/tmp/stale.status FM_HOME_SUMMARY_IF_IDLE=0 FM_TASKS_AXI_COMPATIBLE=1
  FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_PARALLEL_DIR=/tmp/stale-par FM_SPAWN_NO_GUARD=1
  FM_TIMING_LOG=/tmp/stale-timings HERDR_LIVE_SENTINEL=kept)
( export "${polluted[@]}"; fm_backend_herdr_server_ensure "$SESSION" ) || { echo "FAIL: server_ensure"; exit 1; }
echo "server started by fm_backend_herdr_server_ensure from the polluted environment"
raw=$(fm_backend_herdr_container_ensure /tmp) || { echo "FAIL: container_ensure"; exit 1; }
container=${raw%%$'\t'*}; seeded=${raw#*$'\t'}
ids=$(fm_backend_herdr_create_task "$container" fm-envprobe /tmp "$seeded") || { echo "FAIL: create_task"; exit 1; }
read -r tab pane <<<"$ids"
target="$SESSION:$pane"
deadline=$((SECONDS + 30))
until fm_backend_herdr_send_literal "$target" "env | sort > '$W/pane.env'" || [ "$SECONDS" -ge "$deadline" ]; do sleep 0.5; done
sleep 0.5
fm_backend_herdr_send_key "$target" Enter
deadline=$((SECONDS + 60))
while [ ! -s "$W/pane.env" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
echo "pane $pane environment (Firstmate-relevant names):"
grep -E '^(FM_[A-Za-z0-9_]*|CLAUDECODE|HERDR_LIVE_SENTINEL)=' "$W/pane.env" | sed 's/^/  /'
fails=0
[ -s "$W/pane.env" ] || { echo "FAIL: the pane never recorded its environment"; exit 1; }
for kv in "${polluted[@]}"; do
  n=${kv%%=*}
  [ "$n" = HERDR_LIVE_SENTINEL ] && continue
  if grep -q "^$n=" "$W/pane.env"; then echo "FAIL: pane inherited $n from the server"; fails=$((fails+1)); else echo "PASS: pane has no $n"; fi
done
if grep -qx HERDR_LIVE_SENTINEL=kept "$W/pane.env"; then echo "PASS: pane keeps ordinary HERDR_LIVE_SENTINEL=kept"; else echo "FAIL: pane lost the ordinary variable"; fails=$((fails+1)); fi
echo "RESULT ($LABEL): $fails failed check(s)"
exit "$fails"
