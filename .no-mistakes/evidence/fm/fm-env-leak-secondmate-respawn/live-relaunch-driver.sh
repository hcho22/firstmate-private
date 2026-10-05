#!/usr/bin/env bash
# Live E2E driver: runs the real bin/fm-session-start.sh against a REAL tmux
# server on a private socket (-L, -f /dev/null), with a dead secondmate whose
# recorded endpoint is missing. Session start's deferred network stage relaunches
# that secondmate through fm-spawn.sh. Records what the real tmux server and the
# relaunched secondmate process actually carry.
#
# usage: live-relaunch-driver.sh <product-root> <mode> <out-dir>
#   product-root  a Firstmate tree whose bin/ is the product under test
#   mode          fresh   - no tmux server running (tmux home after a reboot)
#                 polluted - an older tmux server already runs `firstmate` and
#                            hands every window Firstmate's internal settings
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M44BRNARCVGWAD2D76BQE4P0
PRODUCT=$1 MODE=$2 OUT=$3
mkdir -p "$OUT"
PRE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-prelude.XXXXXX")
# The suite's own fixture helpers (everything before its test dispatch list).
awk '/^test_context_digest_absent_empty_present$/{exit} {print}' "$WT/tests/fm-session-start.test.sh" \
  | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$WT/tests#g" > "$PRE_DIR/prelude.sh"
# shellcheck source=/dev/null
. "$PRE_DIR/prelude.sh"
SESSION_START="$PRODUCT/bin/fm-session-start.sh"

rec=$(prepare_session_start_secondmate "live-$MODE")
IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF
w=${root%/root}
rm -f "$root/bin"; ln -s "$PRODUCT/bin" "$root/bin"

SOCK="fm-live-relaunch-$MODE-$$"
REAL_TMUX=/usr/local/bin/tmux
SOCK_PATH="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
live_cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  [ ! -S "$SOCK_PATH" ] || rm -f "$SOCK_PATH"
  rm -rf "$PRE_DIR"
  fm_test_cleanup
}
trap live_cleanup EXIT

# Real tmux on a private socket with no user config.
rm -f "$fakebin/tmux"
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
SH
chmod +x "$fakebin/tmux"
# The secondmate's agent CLI: records the environment the real pane launched it
# with, then stays alive like an agent would.
rm -f "$fakebin/pi"
cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
# Version and capability probes from startup/bootstrap return at once; only the
# agent launch typed into a real tmux pane records its environment and stays up.
[ -n "\${TMUX:-}" ] || exit 0
env | sort > "$OUT/secondmate-process.env"
printf 'secondmate pi stub up, FM_HOME=%s\n' "\${FM_HOME:-}"
exec sleep 600
SH
chmod +x "$fakebin/pi"

# The pane login shell. LIVE_SLOW_SHELL=<secs> stands in for a shell whose
# profile (conda, nvm, oh-my-zsh) takes that long before its line editor reads
# input; anything typed before then sits in the tty's canonical line buffer.
PANE_SHELL=/bin/bash
if [ -n "${LIVE_SLOW_SHELL:-}" ]; then
  PANE_SHELL="$fakebin/slowsh"
  printf '#!/bin/bash\nsleep %s\nexec /bin/bash --noprofile --norc -i\n' "$LIVE_SLOW_SHELL" > "$PANE_SHELL"
  chmod +x "$PANE_SHELL"
fi

stale="$w/stale"
mkdir -p "$stale"
INHERITED=(
  FM_SESSION_START_STAGE_FILE="$stale/stage"
  FM_CREW_STATE_META_OVERRIDE="$stale/alpha.meta"
  FM_CREW_STATE_STATUS_OVERRIDE="$stale/alpha.status"
  FM_HOME_SUMMARY_IF_IDLE=0
  FM_HOME_SUMMARY_WORKER_BEST_EFFORT=1
  FM_TASKS_AXI_COMPATIBLE=1
  FM_BOOTSTRAP_NETWORK=only
  FM_BOOTSTRAP_NETWORK_LOCK_PID=1
  FM_BOOTSTRAP_LOCKED=1
  FM_BOOTSTRAP_VERBOSE_FACTS=1
  FM_BOOTSTRAP_PARALLEL_DIR="$stale/parallel"
  FM_SPAWN_NO_GUARD=1
  FM_TIMING_LOG="$stale/timings"
  FM_TIMING_EPOCH_MS=1
)

if [ "$MODE" = polluted ]; then
  # An older server, started before this fix, whose global environment hands
  # every window the internal settings plus a foreign home pin.
  env -u TMUX "${INHERITED[@]}" FM_HOME=/tmp/foreign-home FM_STATE_OVERRIDE=/tmp/foreign-state \
    CLAUDECODE=1 SHELL="$PANE_SHELL" PATH="$fakebin:$BASE_PATH" \
    "$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s firstmate -n captain
fi
printf '== tmux server before session start (%s)\n' "$MODE" > "$OUT/transcript.txt"
"$REAL_TMUX" -L "$SOCK" list-sessions >> "$OUT/transcript.txt" 2>&1 || printf '(no tmux server running)\n' >> "$OUT/transcript.txt"

# Session start itself inherits every internal setting, the Claude marker, and
# an ordinary variable.
SHELL="$PANE_SHELL" run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" no-server \
  "${INHERITED[@]}" CLAUDECODE=1 RELAUNCH_ORDINARY_SENTINEL=kept > "$OUT/session-start.out" 2>&1
printf 'session start exit=%s\n' "$?" >> "$OUT/transcript.txt"
wait_for_network_stage "$home" "$root" 60 >/dev/null 2>&1
printf '== deferred network stage report\n' >> "$OUT/transcript.txt"
network_stage_report "$home" "$root" >> "$OUT/transcript.txt" 2>&1

deadline=$((SECONDS + 60))
while [ ! -s "$OUT/secondmate-process.env" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done

{
  printf '== tmux windows after relaunch\n'
  "$REAL_TMUX" -L "$SOCK" list-windows -a -F '#{session_name}:#{window_name} pid=#{pane_pid} cmd=#{pane_current_command}' 2>&1
  printf '== tmux calls made by the product\n'
  cat "$log"
  printf '== secondmate pane capture\n'
  "$REAL_TMUX" -L "$SOCK" capture-pane -p -t "firstmate:fm-$SESSION_START_SECOND_MATE_ID" 2>&1 | grep -v '^$' | tail -5
} >> "$OUT/transcript.txt"
"$REAL_TMUX" -L "$SOCK" show-environment -g 2>/dev/null | sort > "$OUT/tmux-server-global.env"

check() {  # <file> <label>
  local file=$1 label=$2 name found=0
  printf '== %s: internal settings / launcher identity present?\n' "$label"
  for name in FM_SESSION_START_STAGE_FILE FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE \
    FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT FM_TASKS_AXI_COMPATIBLE FM_BOOTSTRAP_NETWORK \
    FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_LOCKED FM_BOOTSTRAP_VERBOSE_FACTS FM_BOOTSTRAP_PARALLEL_DIR \
    FM_SPAWN_NO_GUARD FM_TIMING_LOG FM_TIMING_EPOCH_MS FM_HOME FM_STATE_OVERRIDE FM_ROOT_OVERRIDE CLAUDECODE \
    RELAUNCH_ORDINARY_SENTINEL FM_BACKEND; do
    if grep -q "^$name=" "$file" 2>/dev/null; then
      printf '  PRESENT %s\n' "$(grep "^$name=" "$file" | head -1)"
    else
      printf '  absent  %s\n' "$name"
    fi
  done
  [ -s "$file" ] || printf '  (file missing or empty: %s)\n' "$file"
}
{
  check "$OUT/tmux-server-global.env" "real tmux server global environment"
  check "$OUT/secondmate-process.env" "relaunched secondmate process environment"
  printf '== expected secondmate home: %s\n' "$mate"
} >> "$OUT/transcript.txt"
cat "$OUT/transcript.txt"
