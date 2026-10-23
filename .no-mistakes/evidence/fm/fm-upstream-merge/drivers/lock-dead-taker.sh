#!/usr/bin/env bash
# Live lock takeover and dead-taker reclaim at a given commit of the gate worktree.
# Two Claude-shaped stand-in harness processes (bash whose argv[0] path is
# .../claude/claude, each exporting its own CLAUDE_CODE_SESSION_ID and
# CLAUDE_PID) run in a private tmux server, outside the driving agent's
# ancestry. A takes the lock, B is refused, B takes over with the captain's
# confirmation, A is refused while B lives and gets the displaced notice once,
# then B's process exits and A's next session start must reclaim the dead
# taker's lock automatically (the rule restored by c2afff2a).
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M5K9VKC2EZBSHY79EY356RH1
COMMIT=${1:?commit}
OUT=${2:?evidence output file}
LAB=$(mktemp -d /tmp/fmdt.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home
scrub() { sed "s#$LAB#<lab>#g; s#$WT#<worktree>#g; s#/private/tmp/#/tmp/#g"; }
"$WT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
git -C "$H" init -q -b main
git -C "$H" fetch -q "$WT" "$COMMIT" || exit 1
git -C "$H" checkout -q -f -B main FETCH_HEAD
printf '.fm-lab-home\n' >> "$H/.git/info/exclude"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$H/data/backlog.md"
printf '# Projects\n' > "$H/data/projects.md"
printf 'tmux\n' > "$H/config/backend"
TMUXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$H") || exit 1
mkdir -p "$LAB/claude"
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TMUXD" tmux "$@"; }
cleanup() {
  lab_tmux kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$H" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash \
  TERM=xterm-256color LANG=en_US.UTF-8 TMUX_TMPDIR="$TMUXD" FM_HOME="$H" \
  tmux new-session -d -s lab -x 200 -y 50 -n A "exec -a $LAB/claude/claude /bin/bash --noprofile --norc"
lab_tmux new-window -d -t lab -n B "exec -a $LAB/claude/claude /bin/bash --noprofile --norc"
pane_pid() { lab_tmux display-message -p -t "lab:$1" '#{pane_pid}'; }
run_in() {  # <window> <tag> <command>
  lab_tmux send-keys -t "lab:$1" "cd $H && { $3 ; } >$LAB/$2.out 2>&1; echo \$? >$LAB/$2.rc" Enter
  local n=0
  while [ ! -s "$LAB/$2.rc" ] && [ "$n" -lt 1200 ]; do sleep 0.1; n=$((n + 1)); done
}
lockstate() {
  printf 'state/.lock line 1: %s | state/.lock-session: %s | state/.lock-takeovers lines: %s\n' \
    "$(head -1 "$H/state/.lock" 2>/dev/null)" "$(cat "$H/state/.lock-session" 2>/dev/null)" \
    "$( [ -f "$H/state/.lock-takeovers" ] && wc -l < "$H/state/.lock-takeovers" | tr -d ' ' || echo 0)"
}
A=$(pane_pid A); B=$(pane_pid B)
run_in A e1 "export CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=\$\$"
run_in B e2 "export CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=\$\$"
lockbanner() { sed -n '/^LOCK/,/^HOME ROLE/p' "$1" | grep -v '^HOME ROLE' | scrub; }
{
  echo "commit: $(git -C "$H" log -1 --format='%h %s' | cut -c1-100)"
  echo "stand-in Claude harness processes (outside the driving agent's ancestry):"
  ps -o pid=,ppid=,comm= -p "$A" -p "$B" | scrub
  echo "A: pid $A, CLAUDE_CODE_SESSION_ID=S1, CLAUDE_PID=$A"
  echo "B: pid $B, CLAUDE_CODE_SESSION_ID=S2, CLAUDE_PID=$B"
  echo
  echo "## 1. A runs session start"
  run_in A s1 "bin/fm-session-start.sh"
  lockbanner "$LAB/s1.out"; echo "session_start_exit=$(cat "$LAB/s1.rc")"; lockstate
  echo
  echo "## 2. B runs session start while A lives"
  run_in B s2 "bin/fm-session-start.sh"
  lockbanner "$LAB/s2.out" | head -6; echo "  [...]"; echo "session_start_exit=$(cat "$LAB/s2.rc")"; lockstate
  echo
  echo "## 3. B takes over with the captain's confirmation"
  echo "\$ bin/fm-lock.sh takeover --confirm-holder $A"
  run_in B t1 "bin/fm-lock.sh takeover --confirm-holder $A"
  scrub <"$LAB/t1.out"; echo "takeover_exit=$(cat "$LAB/t1.rc")"; lockstate
  echo
  echo "## 4. displaced A tries to take the lock back while B lives"
  echo "\$ bin/fm-lock.sh"
  run_in A l1 "bin/fm-lock.sh"
  scrub <"$LAB/l1.out"; echo "fm_lock_exit=$(cat "$LAB/l1.rc")"; lockstate
  echo
  echo "## 5. A's turn ends twice (Claude Stop payload into bin/fm-turnend-guard.sh --claude)"
  for i in 1 2; do
    echo "\$ printf '{\"stop_hook_active\":false,\"session_id\":\"S1\"}' | bin/fm-turnend-guard.sh --claude   (stop $i)"
    run_in A g$i "printf '{\"stop_hook_active\":false,\"session_id\":\"S1\"}' | bin/fm-turnend-guard.sh --claude"
    scrub <"$LAB/g$i.out"; echo "guard_exit=$(cat "$LAB/g$i.rc")"
  done
  echo
  echo "## 6. B's harness process exits (the taker is gone; nothing released the lock)"
  lab_tmux kill-window -t lab:B
  n=0; while kill -0 "$B" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$B" 2>/dev/null; then echo "B pid $B still alive"; else echo "B pid $B is dead"; fi
  lockstate
  echo
  echo "## 7. displaced A runs session start again"
  run_in A s3 "bin/fm-session-start.sh"
  lockbanner "$LAB/s3.out"; echo "session_start_exit=$(cat "$LAB/s3.rc")"; lockstate
  echo
  echo "## 8. A's next turn end"
  run_in A g3 "printf '{\"stop_hook_active\":false,\"session_id\":\"S1\"}' | bin/fm-turnend-guard.sh --claude"
  scrub <"$LAB/g3.out"; echo "guard_exit=$(cat "$LAB/g3.rc")"
  echo
  echo "## state/.lock-takeovers"
  scrub < "$H/state/.lock-takeovers" 2>/dev/null
} >"$OUT" 2>&1
echo "driver done"
