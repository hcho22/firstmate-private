#!/usr/bin/env bash
# Live upgrade path against the gate's target commit: old code (private base
# 9463297b) puts a ship task in flight through real treehouse and a private
# tmux server with a stand-in agent, the old code's own fm-update.sh
# fast-forwards the home to the target, then the merged session start and
# teardown run with the host's tasks-axi (0.2.6 on this host now).
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M5K9VKC2EZBSHY79EY356RH1
OUT=${1:?evidence output dir}
LAB=$(mktemp -d /tmp/fmup5.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home
HOSTPATH=$PATH
TARGET=$(git -C "$WT" rev-parse HEAD)
scrub() { sed "s#$LAB#<lab>#g; s#$WT#<worktree>#g; s#/private/tmp/#/tmp/#g"; }
lab_run() {  # [NAME=VALUE...] <command...>
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$LABPATH" SHELL=/bin/bash \
    TERM=xterm-256color LANG=en_US.UTF-8 TMUX_TMPDIR="$TMUXD" \
    TREEHOUSE_ROOT="$LAB/treehouse" FM_HOME="$H" "$@"
}
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TMUXD" tmux "$@"; }
cleanup() {
  [ -n "${TMUXD:-}" ] && lab_tmux kill-server 2>/dev/null
  pkill -f "$LAB/standin/agent" 2>/dev/null
  pkill -f "$LAB/" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT
LABPATH=$HOSTPATH

"$WT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
git -C "$H" init -q -b main
git -C "$H" fetch -q "$WT" 9463297b72618671b5b2b77effce361c40b2cb5e || exit 1
git -C "$H" checkout -q -f -B main FETCH_HEAD
git -C "$H" config user.name lab; git -C "$H" config user.email lab@example.invalid
# The lab marker .fm-lab-home is excluded locally; a real home has no marker.
printf '.fm-lab-home\n' >> "$H/.git/info/exclude"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$LAB/treehouse" "$LAB/records" "$LAB/standin"
TMUXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$H") || exit 1
printf 'tmux\n' > "$H/config/backend"
cat > "$LAB/standin/agent" <<AGENT
#!/bin/bash
rec="$LAB/records/agent-\$\$"
env | sort > "\$rec.env"; printf '%s\n' "\$@" > "\$rec.args"; pwd -P > "\$rec.cwd"
exec sleep 3600
AGENT
chmod +x "$LAB/standin/agent"
seed=$LAB/seed; origin=$LAB/origins/notes.git
mkdir -p "$seed" "$LAB/origins"; git -C "$seed" init -q -b main
printf '# notes\n' > "$seed/README.md"; git -C "$seed" add -A
git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"
git clone -q "$origin" "$H/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - lab notes library (added 2026-10-01)\n' > "$H/data/projects.md"
printf '# Captain\n\n- Prefers outcomes over mechanics.\n' > "$H/data/captain.md"
printf '# Learnings\n\n- Lab learning line.\n' > "$H/data/learnings.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$H/data/backlog.md"

ID=inflight-old
{
  echo "## 1. old code $(git -C "$H" rev-parse --short HEAD), tasks-axi $(lab_run tasks-axi --version): brief, backlog row, spawn"
  cd "$H" || exit 1
  lab_run "$H/bin/fm-brief.sh" "$ID" notes --mode local-only 2>&1 | scrub
  brief=$(ls "$H"/data/notes/"$ID"/brief.md) || exit 1
  python3 - "$brief" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Add a changelog line to notes.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Append one line to README.md, commit, report done.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  lab_run tasks-axi add "$ID" "notes: add a changelog line" --kind ship --repo notes 2>&1 | scrub
  lab_run "$H/bin/fm-spawn.sh" "$ID" "$H/projects/notes" --mode local-only --yolo off \
    --harness "$LAB/standin/agent --standin" 2>&1 | scrub
  echo "spawn_exit=${PIPESTATUS[0]}"
  echo "windows: $(lab_tmux list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')"
} > "$OUT/s-upgrade-1-old-code-spawn.txt" 2>&1

{
  echo "## 2. the target lands on the home's origin; the running old code self-updates"
  bare=$LAB/origins/firstmate.git
  git clone -q --bare "$H" "$bare"
  git -C "$H" remote add origin "$bare"
  git -C "$H" fetch -q origin
  git -C "$H" branch -q --set-upstream-to=origin/main main
  git --git-dir="$bare" fetch -q "$WT" "$TARGET" && git --git-dir="$bare" update-ref refs/heads/main FETCH_HEAD
  echo "origin/main now: $(git --git-dir="$bare" log -1 --format='%h %s' main | cut -c1-90)"
  echo "home before: $(git -C "$H" log -1 --format='%h %s' | cut -c1-90)"
  echo '$ bin/fm-update.sh   (old code, in the home)'
  (cd "$H" && lab_run "$H/bin/fm-update.sh") 2>&1 | scrub
  echo "update_exit=${PIPESTATUS[0]}"
  echo "home after: $(git -C "$H" log -1 --format='%h %s' | cut -c1-90)"
  echo "git status: $(git -C "$H" status --short | wc -l | tr -d ' ') changed paths"
  echo "in-flight record still present: $(ls "$H/state/$ID.meta" 2>/dev/null | scrub)"
  echo "stand-in agent window: $(lab_tmux list-windows -t firstmate -F '#{window_name} dead=#{pane_dead}' | grep "$ID")"
} > "$OUT/s-upgrade-2-self-update.txt" 2>&1

{
  echo "code: $(git -C "$H" rev-parse --short HEAD); tasks-axi on PATH: $(lab_run tasks-axi --version)"
  echo '$ bin/fm-session-start.sh'
  (cd "$H" && lab_run "$H/bin/fm-session-start.sh") 2>&1 | scrub
  echo "session_start_exit=${PIPESTATUS[0]}"
} > "$OUT/s-upgrade-3-session-start.txt" 2>&1

{
  echo "## new code $(git -C "$H" rev-parse --short HEAD), tasks-axi $(lab_run tasks-axi --version): bin/fm-teardown.sh $ID"
  (cd "$H" && lab_run "$H/bin/fm-teardown.sh" "$ID") 2>&1 | scrub
  echo "teardown_exit=${PIPESTATUS[0]}"
  echo
  echo "record: $(ls "$H/state/$ID.meta" 2>&1 | scrub)"
  echo "windows: $(lab_tmux list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')"
  echo "task folder kept: $(ls "$H/data/notes/$ID" | tr '\n' ' ')"
  echo "backlog:"; cat "$H/data/backlog.md"
} > "$OUT/s-upgrade-4-teardown.txt" 2>&1
echo "driver done; lab=$LAB"
