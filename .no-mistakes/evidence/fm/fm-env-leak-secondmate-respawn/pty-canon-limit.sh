#!/usr/bin/env bash
# pty-canon-limit.sh - isolate the typing boundary fm-spawn relies on: type one
# N-byte command line into a brand-new tmux window (the user's login shell,
# exactly as fm-spawn's new-window gets it) 0.3 s after creation - fm-spawn's
# own pacing - and check whether the shell received it intact.
set -u
unset TMUX
W=$(mktemp -d /tmp/fmcanon.XXXXXX); export TMUX_TMPDIR="$W/t"; mkdir -p "$TMUX_TMPDIR"
tmux new-session -d -s probe -x 200 -y 50
run() {  # <bytes> <delay-before-typing>
  local n=$1 delay=$2 out="$W/out.$1.$2" pad cmd w
  # `printf ok > out` padded with a harmless ':' argument to exactly n bytes.
  cmd=": "; pad=$(( n - ${#cmd} - ${#out} - 22 ))
  cmd="$cmd$(printf 'x%.0s' $(seq 1 "$pad")); printf ok > '$out'"
  w=$(tmux new-window -d -P -F '#{window_id}' -t probe:)
  sleep "$delay"
  tmux send-keys -t "$w" -l "$cmd"; sleep 0.3; tmux send-keys -t "$w" Enter
  for _ in $(seq 1 100); do [ -s "$out" ] && break; sleep 0.1; done
  if [ "$(cat "$out" 2>/dev/null)" = ok ]; then r=intact; else r=BROKEN; fi
  printf 'typed %4s bytes, %-4ss after window creation: %s\n' "${#cmd}" "$delay" "$r"
}
for n in 900 1000 1020 1030 1135 1400; do run "$n" 0.3; done
for n in 1135 1400; do run "$n" 5; done
tmux kill-server; rm -rf "$W"
