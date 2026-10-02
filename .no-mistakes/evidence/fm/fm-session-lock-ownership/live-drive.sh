#!/usr/bin/env bash
# Live end-to-end driver for the session-lock ownership change.
#
# Stands up an isolated firstmate home from a real checkout of <rev> (HEAD or
# the base commit), then reproduces the reported incident with real processes:
#   - an idle "codex app-server --listen unix:// --managed-daemon" process that
#     took the fleet lock and then stopped supervising (lock 90 minutes old),
#   - two tasks in flight and a watcher beat that went stale,
#   - a later Claude firstmate session that starts up and keeps ending turns.
# Every firstmate command runs INSIDE a long-lived process named like its
# harness, so the real ancestry walk ties it to that session exactly as in a
# real session. Prints a transcript to stdout.
#
# Usage: live-drive.sh head|base
set -u
REV=${1:?usage: live-drive.sh head|base}
WT=$(cd "$(dirname "$0")/.." && pwd)
case "$REV" in
  head) COMMIT=HEAD ;;
  base) COMMIT=22abe786ea8dd547b08af5da72d44afe78cd6175 ;;
  *) echo "usage: live-drive.sh head|base" >&2; exit 2 ;;
esac
L="$WT/scratchpad-test/live-$REV"
rm -rf "$L"
mkdir -p "$L/tmp" "$L/harness"
export TMPDIR="$L/tmp"

SESSION_PIDS=()
cleanup() {
  local pid
  for pid in "${SESSION_PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

hr() { printf '\n==================== %s ====================\n' "$1"; }
say() { printf '$ %s\n' "$1"; }

# --- an isolated firstmate home from a real checkout ------------------------
make_home() {  # <dir>
  local home=$1
  mkdir -p "$home"
  git -C "$WT" archive "$COMMIT" | tar -x -C "$home"
  git -C "$home" init -q -b main
  git -C "$home" add -A
  git -C "$home" -c user.name=live -c user.email=live@example.invalid commit -q -m "firstmate @ $REV"
  mkdir -p "$home/state" "$home/data" "$home/config"
}

# --- fake harness processes --------------------------------------------------
# Each "session" is /bin/bash started under its harness's name with a script
# argument, so `ps` shows e.g. exactly "codex app-server --listen unix://
# --managed-daemon". The script loops on a fifo and runs each command line it
# receives inside this very process, so one pid acts on the home repeatedly.
ln -sf /bin/bash "$L/harness/codex"
ln -sf /bin/bash "$L/harness/claude"
LOOP='while :; do
  IFS= read -r cmd < "$SESSION_FIFO" || exit 0
  [ "$cmd" != exit ] || exit 0
  rm -f "${SESSION_BASE:?}.done"
  eval "$cmd" > "$SESSION_BASE.out" 2>&1
  echo "$?" > "$SESSION_BASE.rc"
  : > "$SESSION_BASE.done"
done'
printf '%s\n' "$LOOP" > "$L/harness/app-server"
printf '%s\n' "$LOOP" > "$L/harness/firstmate-session"

session_start() {  # <home> <name> <harness> <script> [args...]; sets SESSION_PID
  local home=$1 name=$2 harness=$3 script=$4
  shift 4
  mkfifo "$L/$name.fifo"
  ( cd "$L/harness" && FM_HOME="$home" SESSION_FIFO="$L/$name.fifo" SESSION_BASE="$L/$name" \
      PATH="$L/harness:$PATH" exec "$harness" "$script" "$@" >/dev/null 2>&1 ) &
  SESSION_PID=$!
  SESSION_PIDS+=("$SESSION_PID")
}

session_run() {  # <name> <command>; sets OUT and RC
  local name=$1 cmd=$2 i=0
  rm -f "$L/$name.done"
  printf '%s\n' "$cmd" > "$L/$name.fifo"
  while [ "$i" -lt 3600 ] && [ ! -e "$L/$name.done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  OUT=$(cat "$L/$name.out" 2>/dev/null)
  RC=$(tr -d '[:space:]' < "$L/$name.rc" 2>/dev/null)
}

show() {  # <label> : print the last session_run result
  printf '%s\n' "$OUT"
  printf '[exit %s]\n' "$RC"
}

claude_stop_payload() {  # <session-id> <stop_hook_active>
  printf '{"session_id":"%s","transcript_path":"/dev/null","cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "$HOME_DIR" "$2"
}

# =============================================================================
HOME_DIR="$L/home"
make_home "$HOME_DIR"
printf 'project=alpha\nwindow=fixture-alpha\nbackend=tmux\n' > "$HOME_DIR/state/alpha.meta"
printf 'project=beta\nwindow=fixture-beta\nbackend=tmux\n' > "$HOME_DIR/state/beta.meta"

hr "SETUP ($REV = $(git -C "$WT" rev-parse --short "$COMMIT"))"
session_start "$HOME_DIR" daemon codex app-server --listen unix:// --managed-daemon
DAEMON_PID=$SESSION_PID
sleep 0.3
say "ps -o pid=,args= -p $DAEMON_PID   # the idle Codex app-server daemon"
ps -o pid=,args= -p "$DAEMON_PID"
say "(inside the daemon's Codex conversation) bin/fm-lock.sh"
session_run daemon '"$FM_HOME/bin/fm-lock.sh"'
show
# The conversation stopped supervising 90 minutes ago: the lock is that old and
# the watcher beat went stale at the same time.
OLD=$(date -v-90M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-90 min' '+%Y%m%d%H%M.%S')
touch -t "$OLD" "$HOME_DIR/state/.lock"
: > "$HOME_DIR/state/.last-watcher-beat"
touch -t "$OLD" "$HOME_DIR/state/.last-watcher-beat"
say "cat state/.lock ; ls state/*.meta"
cat "$HOME_DIR/state/.lock"
ls "$HOME_DIR/state/"*.meta | sed "s|$HOME_DIR/||"

session_start "$HOME_DIR" claude-b claude firstmate-session
CLAUDE_B=$SESSION_PID
sleep 0.3
say "ps -o pid=,args= -p $CLAUDE_B   # a later Claude firstmate session"
ps -o pid=,args= -p "$CLAUDE_B"

# --- S1: the later session starts up ------------------------------------------
hr "S1: later Claude session runs bin/fm-session-start.sh"
session_run claude-b 'FM_SESSION_START_TIMEOUT=100 "$FM_HOME/bin/fm-session-start.sh"'
printf '%s\n' "$OUT" | sed -n '/LOCK/,/BOOTSTRAP/p' | sed '$d'
printf '[exit %s]\n' "$RC"
say "cat state/.lock   # still the daemon? (never taken over automatically)"
cat "$HOME_DIR/state/.lock"
kill -0 "$DAEMON_PID" 2>/dev/null && echo "daemon pid $DAEMON_PID still alive"

# --- S2: the read-only session keeps ending turns -------------------------------
hr "S2: 30 consecutive Stop events in the read-only Claude session (bin/fm-turnend-guard.sh --claude)"
blocks=0 notices=0 silent=0
for n in $(seq 1 30); do
  active=true
  [ "$n" -eq 1 ] && active=false
  PAY=$(claude_stop_payload sess-readonly-b "$active")
  session_run claude-b "printf '%s' '$PAY' | \"\$FM_HOME/bin/fm-turnend-guard.sh\" --claude"
  if [ "$RC" = 2 ]; then
    blocks=$((blocks + 1))
  elif [ -n "$OUT" ]; then
    notices=$((notices + 1))
  else
    silent=$((silent + 1))
  fi
  if [ "$n" -le 2 ] || [ "$n" -eq 30 ]; then
    printf -- '--- stop %s (stop_hook_active=%s) ---\n' "$n" "$active"
    if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$OUT" | jq -r '.systemMessage // .'
    else
      printf '%s\n' "$OUT"
    fi
    printf '[exit %s]\n' "$RC"
  fi
done
printf 'SUMMARY: %s stops blocked (exit 2), %s ended with a notice, %s ended silently\n' "$blocks" "$notices" "$silent"
say "cat state/.turnend-claude-blocks"
cat "$HOME_DIR/state/.turnend-claude-blocks" 2>/dev/null || echo "(absent)"
say "ls -a state/"
ls -a "$HOME_DIR/state" | tr '\n' ' '; echo

say "(the paired Stop hook) bin/fm-claude-stop-autoarm.sh in the read-only session"
PAY=$(claude_stop_payload sess-readonly-b false)
session_run claude-b "printf '%s' '$PAY' | \"\$FM_HOME/bin/fm-claude-stop-autoarm.sh\""
show
ls "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null || echo "no auto-arm epoch written (the read-only session armed nothing)"

if [ "$REV" = base ]; then
  hr "base: no takeover command exists"
  say "bin/fm-lock.sh takeover --confirm-holder $DAEMON_PID"
  session_run claude-b "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  show
  cat "$HOME_DIR/state/.lock"
  exit 0
fi

# --- S3: adversarial takeover attempts ----------------------------------------------
hr "S3: takeover attempts that must be refused"
say "bin/fm-lock.sh status"
session_run claude-b '"$FM_HOME/bin/fm-lock.sh" status'
show
say "bin/fm-lock.sh takeover            # no confirmation"
session_run claude-b '"$FM_HOME/bin/fm-lock.sh" takeover'
show
say "bin/fm-lock.sh takeover --confirm-holder=$DAEMON_PID   # undocumented spelling"
session_run claude-b "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder=$DAEMON_PID"
show
say "bin/fm-lock.sh takeover --confirm-holder 4242   # stale/wrong pid"
session_run claude-b '"$FM_HOME/bin/fm-lock.sh" takeover --confirm-holder 4242'
show
say "touch state/.last-watcher-beat ; bin/fm-lock.sh takeover --confirm-holder $DAEMON_PID   # a watcher beat is fresh"
touch "$HOME_DIR/state/.last-watcher-beat"
session_run claude-b "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
show
touch -t "$OLD" "$HOME_DIR/state/.last-watcher-beat"
say "(from a separate terminal, not inside any firstmate session) bin/fm-lock.sh takeover --confirm-holder $DAEMON_PID"
# Double fork so this process is orphaned to launchd and its ancestry contains
# no harness at all - a plain terminal shell.
rm -f "$L/orphan.out" "$L/orphan.rc"
FM_HOME="$HOME_DIR" perl -e '
  my ($out, $rc, @cmd) = @ARGV;
  exit 0 if fork;
  if (fork) { exit 0 }
  sleep 1;
  open(STDOUT, ">", $out); open(STDERR, ">&STDOUT");
  system(@cmd);
  open(my $f, ">", $rc); print $f ($? >> 8); close $f;
' "$L/orphan.out" "$L/orphan.rc" "$HOME_DIR/bin/fm-lock.sh" takeover --confirm-holder "$DAEMON_PID"
i=0; while [ "$i" -lt 200 ] && [ ! -s "$L/orphan.rc" ]; do sleep 0.05; i=$((i + 1)); done
cat "$L/orphan.out"; printf '[exit %s]\n' "$(cat "$L/orphan.rc" 2>/dev/null)"
say "cat state/.lock ; ls state/.lock-takeovers"
cat "$HOME_DIR/state/.lock"
ls "$HOME_DIR/state/.lock-takeovers" 2>/dev/null || echo "(no takeover record)"

# --- S4: the captain-confirmed takeover ------------------------------------------------
hr "S4: captain confirms; firstmate in the Claude session runs the takeover"
say "bin/fm-lock.sh takeover --confirm-holder $DAEMON_PID"
session_run claude-b "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
show
say "cat state/.lock"
cat "$HOME_DIR/state/.lock"
say "cat state/.lock-takeovers"
tr '\t' '\n' < "$HOME_DIR/state/.lock-takeovers"
kill -0 "$DAEMON_PID" 2>/dev/null && echo "daemon pid $DAEMON_PID still alive (not signalled)"
say "bin/fm-lock.sh   # the new holder re-verifies"
session_run claude-b '"$FM_HOME/bin/fm-lock.sh"'
show
say "bin/fm-lock.sh status"
session_run claude-b '"$FM_HOME/bin/fm-lock.sh" status'
show

# --- S5: the holder is still held to repair ----------------------------------------------
hr "S5: the new lock holder's turn-end guard still demands repair"
PAY=$(claude_stop_payload sess-holder-b false)
session_run claude-b "printf '%s' '$PAY' | \"\$FM_HOME/bin/fm-turnend-guard.sh\" --claude"
show
say "cat state/.turnend-claude-blocks"
cat "$HOME_DIR/state/.turnend-claude-blocks" 2>/dev/null || echo "(absent)"
rm -f "$HOME_DIR/state/.turnend-claude-blocks"

# --- S6: the displaced previous holder learns it once ----------------------------------------
hr "S6: the displaced previous holder's Stop hook (Codex native, then follow-up adapter shape)"
for n in 1 2; do
  say "(inside pid $DAEMON_PID) printf '{\"session_id\":\"codex-old\",\"stop_hook_active\":false}' | bin/fm-turnend-guard.sh   # stop $n"
  session_run daemon "printf '%s' '{\"session_id\":\"codex-old\",\"stop_hook_active\":false}' | \"\$FM_HOME/bin/fm-turnend-guard.sh\""
  show
done
say "(inside pid $DAEMON_PID) bin/fm-lock.sh   # the displaced session tries to take the lock back"
session_run daemon '"$FM_HOME/bin/fm-lock.sh"'
show
cat "$HOME_DIR/state/.lock"

# --- S7: a dead holder is still reclaimed automatically ----------------------------------------
hr "S7: a holder whose process died is reclaimed automatically"
HOME2="$L/home-dead"
make_home "$HOME2"
printf 'project=alpha\nwindow=fixture-alpha\nbackend=tmux\n' > "$HOME2/state/alpha.meta"
session_start "$HOME2" dead-codex codex app-server --listen unix:// --managed-daemon
DEAD=$SESSION_PID
sleep 0.3
session_run dead-codex '"$FM_HOME/bin/fm-lock.sh"'
printf 'old holder: %s\n' "$OUT"
printf 'exit\n' > "$L/dead-codex.fifo"; wait "$DEAD" 2>/dev/null
kill -0 "$DEAD" 2>/dev/null || echo "pid $DEAD is now dead; state/.lock still says $(cat "$HOME2/state/.lock")"
session_start "$HOME2" claude-c claude firstmate-session
CLAUDE_C=$SESSION_PID
sleep 0.3
say "(new Claude session pid $CLAUDE_C) bin/fm-lock.sh"
session_run claude-c '"$FM_HOME/bin/fm-lock.sh"'
show
say "cat state/.lock ; ls state/.lock-takeovers"
cat "$HOME2/state/.lock"
ls "$HOME2/state/.lock-takeovers" 2>/dev/null || echo "(no takeover record - plain reclaim)"

# --- S8: a displaced Claude session -------------------------------------------------------------
hr "S8: Claude session A held the lock; Claude session D takes over; A's next stops"
HOME3="$L/home-claude"
make_home "$HOME3"
printf 'project=alpha\nwindow=fixture-alpha\nbackend=tmux\n' > "$HOME3/state/alpha.meta"
session_start "$HOME3" claude-a claude firstmate-session
CLAUDE_A=$SESSION_PID
session_start "$HOME3" claude-d claude firstmate-session
CLAUDE_D=$SESSION_PID
sleep 0.3
session_run claude-a '"$FM_HOME/bin/fm-lock.sh"'
printf 'session A: %s\n' "$OUT"
touch -t "$OLD" "$HOME3/state/.lock"
session_run claude-d '"$FM_HOME/bin/fm-lock.sh"'
printf 'session D first try: %s\n[exit %s]\n' "$OUT" "$RC"
session_run claude-d "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $CLAUDE_A"
printf 'session D takeover (captain confirmed):\n%s\n[exit %s]\n' "$OUT" "$RC"
for n in 1 2 3; do
  active=true
  [ "$n" -eq 1 ] && active=false
  PAY=$(claude_stop_payload sess-a "$active")
  say "(session A, stop $n) bin/fm-turnend-guard.sh --claude"
  session_run claude-a "printf '%s' '$PAY' | \"\$FM_HOME/bin/fm-turnend-guard.sh\" --claude"
  show
done
printf '\nDONE\n'
