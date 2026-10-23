#!/usr/bin/env bash
# Live: a foreground watcher checkpoint whose real watcher is stopped by the
# real home-scoped stop (bin/fm-watch-arm.sh --stop sends TERM). This Mac has
# neither timeout nor gtimeout, so the checkpoint runs the watcher through its
# perl fallback. A TERM death must surface as exit 143 (a failure), never as
# exit 0 with no wake line, which the checkpoint's contract reads as an
# actionable wake.
# usage: checkpoint-term-stop.sh <commit> <out>
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M5K9VKC2EZBSHY79EY356RH1
COMMIT=$1; OUT=$2
LAB=$(mktemp -d /tmp/fmck.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home
mkdir -p "$H"
git -C "$WT" archive "$COMMIT" | tar -x -C "$H"
mkdir -p "$H/state" "$H/data" "$H/config"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$H/data/backlog.md"
printf '# Projects\n' > "$H/data/projects.md"
cleanup() { pkill -f "$H/bin/" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
scrub() { sed "s#$LAB#<lab>#g"; }
{
  echo "commit: $(git -C "$WT" log -1 --format='%h %s' "$COMMIT" | cut -c1-100)"
  echo "host: timeout=$(command -v timeout || echo none) gtimeout=$(command -v gtimeout || echo none) perl=$(command -v perl)"
  echo
  echo "## 1. start a foreground checkpoint (bound 120s)"
  echo "\$ bin/fm-watch-checkpoint.sh --seconds 120 &"
  start=$(date +%s)
  ( cd "$H" && exec env -u TMUX FM_HOME="$H" FM_GATE_REFUSE_BYPASS=1 bin/fm-watch-checkpoint.sh --seconds 120 >"$LAB/ck.out" 2>"$LAB/ck.err" ) &
  ck=$!
  n=0
  while [ ! -s "$H/state/.watch.lock/pid" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  wpid=$(cat "$H/state/.watch.lock/pid" 2>/dev/null)
  echo "watcher pid recorded in state/.watch.lock/pid: ${wpid:-none}"
  ps -o pid=,ppid=,command= -p "$wpid" 2>/dev/null | scrub | cut -c1-140
  sleep 2
  echo
  echo "## 2. the home-scoped stop (what fm-watch-arm.sh --stop/--restart and a stalled-holder eviction do)"
  echo "\$ bin/fm-watch-arm.sh --stop"
  ( cd "$H" && env -u TMUX FM_HOME="$H" FM_GATE_REFUSE_BYPASS=1 bin/fm-watch-arm.sh --stop ) 2>&1 | scrub
  rc=0; wait "$ck" || rc=$?
  echo
  echo "## 3. the checkpoint's result"
  echo "checkpoint_exit=$rc elapsed=$(( $(date +%s) - start ))s (bound 120s)"
  echo "--- checkpoint stdout ---"; scrub < "$LAB/ck.out"
  echo "--- checkpoint stderr ---"; scrub < "$LAB/ck.err"
  echo "--- watch lock after ---"; ls "$H/state/.watch.lock" 2>&1 | scrub
  case "$rc" in
    0) echo "verdict: exit 0 with$(grep -Eq '^(signal:|stale:|check:|heartbeat)' "$LAB/ck.out" || echo 'out') a wake line: the caller reads this as an actionable wake" ;;
    143) echo "verdict: exit 143 = 128+TERM: the caller sees the watcher was killed, not a wake" ;;
    *) echo "verdict: exit $rc" ;;
  esac
} >"$OUT" 2>&1
echo "driver done"
