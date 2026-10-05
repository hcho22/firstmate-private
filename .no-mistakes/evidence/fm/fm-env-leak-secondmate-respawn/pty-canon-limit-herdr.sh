#!/usr/bin/env bash
# pty-canon-limit-herdr.sh <repo-dir> - the same typing boundary on a real Herdr
# lab session: a fresh task pane (the captain's login shell), N bytes typed
# through the adapter's send_literal 0.3 s after creation, then Enter.
set -u
R=$1
export FM_GATE_REFUSE_BYPASS=1
unset NO_MISTAKES_GATE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
. "$R/bin/fm-herdr-lab.sh"
SESSION="fm-lab-canon-$$"; export HERDR_SESSION="$SESSION"
W=$(mktemp -d /tmp/fmhc.XXXXXX)
trap 'fm_herdr_lab_teardown "$SESSION"; rm -rf "$W"' EXIT
fm_herdr_lab_prepare "$SESSION" || exit 2
. "$R/bin/fm-backend.sh"; fm_backend_source herdr || exit 2
raw=$(fm_backend_herdr_container_ensure /tmp) || exit 2
container=${raw%%$'\t'*}; seeded=${raw#*$'\t'}
k=0
run() {  # <bytes>
  local n=$1 out="$W/out.$1" cmd pad ids tab pane t
  k=$((k + 1))
  cmd=": "; pad=$(( n - ${#cmd} - ${#out} - 22 ))
  cmd="$cmd$(printf 'x%.0s' $(seq 1 "$pad")); printf ok > '$out'"
  ids=$(fm_backend_herdr_create_task "$container" "fm-canon$k" /tmp "$seeded") || { echo "create_task failed"; return; }
  seeded=
  read -r tab pane <<<"$ids"; t="$SESSION:$pane"
  sleep 0.3
  fm_backend_herdr_send_literal "$t" "$cmd"; sleep 0.3; fm_backend_herdr_send_key "$t" Enter
  for _ in $(seq 1 100); do [ -s "$out" ] && break; sleep 0.1; done
  if [ "$(cat "$out" 2>/dev/null)" = ok ]; then r=intact; else r=BROKEN; fi
  printf 'herdr: typed %4s bytes 0.3 s after pane creation: %s\n' "${#cmd}" "$r"
}
for n in 900 1014 1135; do run "$n"; done
