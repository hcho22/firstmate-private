#!/usr/bin/env bash
# live-herdr-client-env.sh <repo-dir-containing-bin> <label>
# Adversarial companion to live-herdr-server-env.sh: the REAL Herdr server is
# started cleanly (the captain's own server, already running), and then a task
# pane is created and populated by the adapter from a client environment that
# DOES carry Firstmate's internal handoff settings and the Claude marker - what
# a session start launched from a polluted pane hands its relaunch. The pane
# must still come out free of them, i.e. Herdr panes take the server's
# environment, not the creating client's. Private lab session only.
set -u
R=$1 LABEL=$2
export FM_GATE_REFUSE_BYPASS=1
unset NO_MISTAKES_GATE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
# shellcheck source=/dev/null
. "$R/bin/fm-herdr-lab.sh"
SESSION="fm-lab-envcli-$$"
export HERDR_SESSION="$SESSION"
W=$(mktemp -d /tmp/fmhc.XXXXXX)
trap 'fm_herdr_lab_teardown "$SESSION"; rm -rf "$W"' EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 2; }
# shellcheck source=/dev/null
. "$R/bin/fm-backend.sh"
fm_backend_source herdr || exit 2
echo "=== live herdr client env: $LABEL ($(herdr --version 2>/dev/null), lab session $SESSION) ==="
HERDR_LIVE_SENTINEL=kept fm_backend_herdr_server_ensure "$SESSION" || { echo "FAIL: server_ensure"; exit 1; }
echo "server started cleanly (ordinary HERDR_LIVE_SENTINEL=kept only)"
polluted=(CLAUDECODE=1
  FM_SESSION_START_STAGE_FILE=/tmp/stale-stage FM_CREW_STATE_META_OVERRIDE=/tmp/stale.meta
  FM_CREW_STATE_STATUS_OVERRIDE=/tmp/stale.status FM_HOME_SUMMARY_IF_IDLE=0 FM_TASKS_AXI_COMPATIBLE=1
  FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_PARALLEL_DIR=/tmp/stale-par FM_SPAWN_NO_GUARD=1
  FM_TIMING_LOG=/tmp/stale-timings)
(
  export "${polluted[@]}"
  raw=$(fm_backend_herdr_container_ensure /tmp) || { echo "FAIL: container_ensure"; exit 1; }
  container=${raw%%$'\t'*}; seeded=${raw#*$'\t'}
  ids=$(fm_backend_herdr_create_task "$container" fm-envprobe /tmp "$seeded") || { echo "FAIL: create_task"; exit 1; }
  read -r tab pane <<<"$ids"
  target="$SESSION:$pane"
  deadline=$((SECONDS + 30))
  until fm_backend_herdr_send_literal "$target" "env | sort > '$W/pane.env'" || [ "$SECONDS" -ge "$deadline" ]; do sleep 0.5; done
  sleep 0.5
  fm_backend_herdr_send_key "$target" Enter
  echo "pane $pane created and driven by a client carrying: ${polluted[*]%%=*}"
) || exit 1
deadline=$((SECONDS + 60))
while [ ! -s "$W/pane.env" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
echo "pane environment (Firstmate-relevant names):"
grep -E '^(FM_[A-Za-z0-9_]*|CLAUDECODE|HERDR_LIVE_SENTINEL)=' "$W/pane.env" | sed 's/^/  /'
fails=0
[ -s "$W/pane.env" ] || { echo "FAIL: the pane never recorded its environment"; exit 1; }
for kv in "${polluted[@]}"; do
  n=${kv%%=*}
  if grep -q "^$n=" "$W/pane.env"; then echo "FAIL: pane inherited $n from the creating client"; fails=$((fails+1)); else echo "PASS: pane has no $n"; fi
done
if grep -qx HERDR_LIVE_SENTINEL=kept "$W/pane.env"; then echo "PASS: pane keeps the server's ordinary HERDR_LIVE_SENTINEL=kept"; else echo "FAIL: pane lost the ordinary variable"; fails=$((fails+1)); fi
echo "RESULT ($LABEL): $fails failed check(s)"
exit "$fails"
