#!/usr/bin/env bash
# Live driver: the Cursor primary's real stop hook (bin/fm-turnend-guard-cursor.sh)
# in a session displaced by a real captain-confirmed takeover, and in a session
# that never held the lock. Same isolation and process model as live-drive.sh.
set -u
WT=$(cd "$(dirname "$0")/.." && pwd)
L="$WT/scratchpad-test/live-cursor"
rm -rf "$L"
mkdir -p "$L/tmp" "$L/harness"
export TMPDIR="$L/tmp"
SESSION_PIDS=()
cleanup() { local p; for p in "${SESSION_PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
hr() { printf '\n==================== %s ====================\n' "$1"; }
say() { printf '$ %s\n' "$1"; }

HOME_DIR="$L/home"
mkdir -p "$HOME_DIR"
git -C "$WT" archive HEAD | tar -x -C "$HOME_DIR"
git -C "$HOME_DIR" init -q -b main
git -C "$HOME_DIR" add -A
git -C "$HOME_DIR" -c user.name=live -c user.email=live@example.invalid commit -q -m "firstmate @ head"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'project=alpha\nwindow=fixture-alpha\nbackend=tmux\n' > "$HOME_DIR/state/alpha.meta"
printf 'project=beta\nwindow=fixture-beta\nbackend=tmux\n' > "$HOME_DIR/state/beta.meta"

ln -sf /bin/bash "$L/harness/cursor-agent"
ln -sf /bin/bash "$L/harness/claude"
cat > "$L/harness/firstmate-session" <<'SH'
while :; do
  IFS= read -r cmd < "$SESSION_FIFO" || exit 0
  [ "$cmd" != exit ] || exit 0
  rm -f "${SESSION_BASE:?}.done"
  eval "$cmd" > "$SESSION_BASE.out" 2>&1
  echo "$?" > "$SESSION_BASE.rc"
  : > "$SESSION_BASE.done"
done
SH
session_start() {  # <name> <harness>; sets SESSION_PID
  mkfifo "$L/$1.fifo"
  ( cd "$L/harness" && FM_HOME="$HOME_DIR" SESSION_FIFO="$L/$1.fifo" SESSION_BASE="$L/$1" \
      PATH="$L/harness:$PATH" exec "$2" firstmate-session >/dev/null 2>&1 ) &
  SESSION_PID=$!
  SESSION_PIDS+=("$SESSION_PID")
  sleep 0.3
}
session_run() {  # <name> <command>; sets OUT RC
  local i=0
  rm -f "$L/$1.done"
  printf '%s\n' "$2" > "$L/$1.fifo"
  while [ "$i" -lt 3600 ] && [ ! -e "$L/$1.done" ]; do sleep 0.05; i=$((i + 1)); done
  OUT=$(cat "$L/$1.out" 2>/dev/null); RC=$(tr -d '[:space:]' < "$L/$1.rc" 2>/dev/null)
}
show_park() {
  if [ -z "$OUT" ]; then
    echo "(no stdout - no follow-up)"
  elif printf '%s' "$OUT" | jq -e .followup_message >/dev/null 2>&1; then
    echo "stdout JSON keys: $(printf '%s' "$OUT" | jq -c 'keys')"
    echo "followup_message:"
    printf '%s' "$OUT" | jq -r .followup_message
  else
    printf '%s\n' "$OUT"
  fi
  printf '[exit %s]\n' "$RC"
}
cursor_payload() { printf '{"session_id":"%s","generation_id":"gen-%s","loop_count":%s,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}' "$1" "$2" "$2"; }
OLD=$(date -v-90M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-90 min' '+%Y%m%d%H%M.%S')

hr "SETUP"
session_start cursor-e cursor-agent; CURSOR_E=$SESSION_PID
say "ps -o pid=,args= -p $CURSOR_E   # a Cursor primary session"
ps -o pid=,args= -p "$CURSOR_E"
session_run cursor-e '"$FM_HOME/bin/fm-lock.sh"'
printf '%s\n[exit %s]\n' "$OUT" "$RC"
touch -t "$OLD" "$HOME_DIR/state/.lock"
: > "$HOME_DIR/state/.last-watcher-beat"; touch -t "$OLD" "$HOME_DIR/state/.last-watcher-beat"
session_start claude-f claude; CLAUDE_F=$SESSION_PID
session_start cursor-g cursor-agent; CURSOR_G=$SESSION_PID

hr "C1: captain confirms; Claude session F takes over from Cursor session E"
session_run claude-f "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $CURSOR_E"
printf '%s\n[exit %s]\n' "$OUT" "$RC"

hr "C2: displaced Cursor session E ends turns (real bin/fm-turnend-guard-cursor.sh stop hook)"
for n in 1 2 3; do
  say "(Cursor E, stop $n) printf '<cursor stop payload>' | bin/fm-turnend-guard-cursor.sh"
  session_run cursor-e "printf '%s' '$(cursor_payload sess-cursor-e "$n")' | \"\$FM_HOME/bin/fm-turnend-guard-cursor.sh\""
  show_park
done

hr "C3: Cursor session G, which never held the lock, ends turns while supervision is off"
for n in 1 2; do
  say "(Cursor G, stop $n) printf '<cursor stop payload>' | bin/fm-turnend-guard-cursor.sh"
  session_run cursor-g "printf '%s' '$(cursor_payload sess-cursor-g "$n")' | \"\$FM_HOME/bin/fm-turnend-guard-cursor.sh\""
  show_park
done

hr "STATE after all Cursor stops"
say "cat state/.lock ; ls -a state/"
cat "$HOME_DIR/state/.lock"
ls -a "$HOME_DIR/state" | tr '\n' ' '; echo
for f in .turnend-cursor-blocks .cursor-park-owner .watch.lock; do
  [ -e "$HOME_DIR/state/$f" ] && echo "PRESENT: state/$f" || echo "absent: state/$f"
done
printf '\nDONE\n'
