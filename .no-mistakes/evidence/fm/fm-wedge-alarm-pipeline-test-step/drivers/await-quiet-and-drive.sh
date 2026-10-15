#!/usr/bin/env bash
# Wait (bounded) for run $RUN's test step to enter its quiet configured-command
# phase, then drive the real watcher with this change's code and the base code
# side by side against it.
set -u
L=/tmp/fml.CZNO WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
EV=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305 RUN=01M4YJKR5WFZJMRQYGKGBZH4FV
cd "$L" || exit 1
NM=/usr/local/bin/no-mistakes
deadline=$(( $(date +%s) + ${WAIT_SECS:-2700} ))
while :; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "[$(date +%T)] gave up: no quiet configured-command phase within the wait"; exit 2; }
  toon=$(cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null)
  st=$(printf '%s\n' "$toon" | sed -n 's/^  status: //p' | head -1)
  row=$(printf '%s\n' "$toon" | sed -n '/active_steps/{n;p;}')
  [ "$st" = running ] || { echo "[$(date +%T)] run is no longer running: $st"; exit 3; }
  case "$row" in *'running tests'*'",""'*) break ;; esac
  sleep 20
done
echo "[$(date +%T)] quiet configured-command phase seen: $row"
sleep 15
toon=$(cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null)
head=$(printf '%s\n' "$toon" | sed -n 's/^  head_sha: //p' | head -1)
branch=$(printf '%s\n' "$toon" | sed -n 's/^  branch: //p' | head -1)
if ! git -C "$L/wt2" cat-file -e "$head^{commit}" 2>/dev/null; then
  git -C "$L/wt2" fetch -q "$WT" "$head" 2>/dev/null || git -C "$L/wt2" fetch -q "$WT" '+refs/*:refs/remotes/gate/*' 2>/dev/null
fi
git -C "$L/wt2" checkout -q -B "$branch" "$head" || { echo "[$(date +%T)] could not align the fixture crew to $head"; exit 4; }
echo "[$(date +%T)] fixture crew aligned to $branch $(git -C "$L/wt2" rev-parse --short HEAD)"
for f in rf rb; do
  rm -rf "$L/$f/state"; mkdir -p "$L/$f/state"
  printf 'window=fm:fm-reaping\nkind=ship\nworktree=%s\n' "$L/wt2" > "$L/$f/state/reaping.meta"
  printf 'paused: waiting on the validation response\n' > "$L/$f/state/reaping.status"
done
END=$(( $(date +%s) + ${DRIVE_SECS:-200} ))
( cd "$L/rf" && FM_LIVE_RUN_ID=$RUN WINDOW=60 ./watch-loop.sh "$WT" "$END" "$L/rf" fixed ) &
f=$!
( cd "$L/rb" && FM_LIVE_RUN_ID=$RUN WINDOW=60 ./watch-loop.sh "$L/base" "$END" "$L/rb" base ) &
b=$!
S="$L/samples-real-quiet-run2.log"; : > "$S"
while kill -0 $f 2>/dev/null || kill -0 $b 2>/dev/null; do
  a=$(cd /tmp && "$NM" axi status --run "$RUN" 2>/dev/null | sed -n '/active_steps/{n;p;}')
  lc=$(for p in $(pgrep -f "bin/fm-test-run.sh"); do c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p'); case "$c" in */"$RUN") printf '%s(etime %s) ' "$p" "$(ps -o etime= -p "$p" | tr -d ' ')" ;; esac; done)
  printf '[%s] axi active step: %s | fm-test-run.sh processes in that run'"'"'s copy: %s\n' "$(date +%T)" "$a" "$lc" >> "$S"
  sleep 30
done
wait
out="$EV/live-D-real-quiet-test-step-fixed-vs-base.txt"
{
  echo "# Real run $RUN ($branch @ ${head:0:8}), test step in its configured-command phase; watcher window 60s; both watchers ran concurrently"
  for v in fixed base; do d=$L/r${v:0:1}
    if [ "$v" = fixed ]; then echo "######## watcher code: this change f3ec246"; else echo "######## watcher code: base fbd3c9b"; fi
    echo "# wakes delivered to firstmate"; cat "$d/wakes-$v.log"
    echo "# triage log (deferrals, timer resets)"; grep -v "absorbed non-terminal stale (provably working): " "$d/state/.watch-triage.log"
  done
  echo "# samples of the real run"; cat "$S"
} > "$out"
cat "$out"
