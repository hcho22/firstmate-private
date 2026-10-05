#!/usr/bin/env bash
# pty-canon-limit-slow-bash.sh - the same boundary with no zsh or rc files at
# all: the pane shell sleeps 2 s (a slow-starting login shell) and then execs a
# plain `bash --noprofile --norc -i`. Text typed during that window sits in the
# pty's canonical input queue until bash's line editor reads it.
set -u
unset TMUX
W=$(mktemp -d /tmp/fmsb.XXXXXX); export TMUX_TMPDIR="$W/t"; mkdir -p "$TMUX_TMPDIR"
printf '#!/bin/sh\nsleep 2\nexec /bin/bash --noprofile --norc -i\n' > "$W/slowsh"; chmod +x "$W/slowsh"
tmux -f /dev/null new-session -d -s probe -x 200 -y 50 "$W/slowsh"
tmux set-option -g default-shell "$W/slowsh"
for n in 900 1014 1024 1135; do
  out="$W/out.$n"
  cmd=": "; pad=$(( n - ${#cmd} - ${#out} - 22 ))
  cmd="$cmd$(printf 'x%.0s' $(seq 1 "$pad")); printf ok > '$out'"
  w=$(tmux new-window -d -P -F '#{window_id}' -t probe:)
  sleep 0.3
  tmux send-keys -t "$w" -l "$cmd"; sleep 0.3; tmux send-keys -t "$w" Enter
  for _ in $(seq 1 100); do [ -s "$out" ] && break; sleep 0.1; done
  printf 'slow bash: typed %4s bytes 0.3 s after window creation: %s\n' "${#cmd}" "$([ "$(cat "$out" 2>/dev/null)" = ok ] && echo intact || echo BROKEN)"
done
tmux kill-server; rm -rf "$W"
