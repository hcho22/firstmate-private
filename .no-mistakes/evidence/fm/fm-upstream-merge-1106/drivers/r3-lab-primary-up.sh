#!/usr/bin/env bash
# Mint a marked lab home with a demo project and start a real Claude primary on the lab's private tmux socket.
# Usage: r3-lab-primary-up.sh <worktree>   (prints LAB=<physical path>)
set -eu
cd "$1"
RAW=$(mktemp -d /tmp/fm-lab.XXXXXX)
LAB=$(cd "$RAW" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/treehouse"
git init -q --bare "$LAB/origin-demo.git"
git init -q -b main "$LAB/projects/demo"
printf '#!/bin/sh\necho "ahoy from demo $((6*7))"\n' > "$LAB/projects/demo/hello.sh"
chmod +x "$LAB/projects/demo/hello.sh"
git -C "$LAB/projects/demo" add hello.sh
git -C "$LAB/projects/demo" -c user.name=lab -c user.email=lab@example.invalid commit -qm "demo: hello"
git -C "$LAB/projects/demo" remote add origin "$LAB/origin-demo.git"
git -C "$LAB/projects/demo" push -q -u origin main
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 220 -y 60 -c "$PWD" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" claude
echo "LAB=$LAB"
