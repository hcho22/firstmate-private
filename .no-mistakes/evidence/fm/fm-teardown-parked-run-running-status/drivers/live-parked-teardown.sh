#!/usr/bin/env bash
# Live driver: a ship task's own no-mistakes run that the CLI reports as
# `status: running` while parked at a gate must be aborted by teardown.
#
# Real parts: a marked disposable lab home (bin/fm-lab-home.sh), a private
# tmux server, the REAL treehouse binary on a throwaway project pool, the real
# bin/fm-spawn.sh ship dispatch, real git commits/pushes, and the code root's
# real bin/fm-teardown.sh run by its CLI entrypoint.
# Stand-in: `no-mistakes`. The gate phase may not drive, park, or abort a real
# pipeline, so a stateful stand-in replays recorded real `axi status` stdout
# (tests/captures/no-mistakes-v1.70.1/*.toon, and today's live v1.79.0
# executing capture), substituting only id/branch/head, and records every call.
# An `axi abort --run <id>` for the current run turns its state into the real
# cancelled capture, so the run's final state shows whether it was orphaned.
#
# Usage: live-parked-teardown.sh <code-root> <scenario> <outdir>
#   parked-own-head     real parked capture at the worktree's own HEAD
#   parked-pushed-fix   real parked capture whose head is the pipeline's own
#                       pushed fix commit (absent from the task copy), with
#                       branch_sync recording the submitted head = task HEAD
#   executing           today's live v1.79.0 capture of a run executing a step
#   other-branch        real parked capture on another branch
#   diverged-head       real parked capture on this branch at a different
#                       commit that resolves locally (no submitted-head record)
set -u
CODE_ROOT=$(cd "$1" && pwd -P) SCENARIO=$2 OUT=$3
HELPER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CAPTURES=${CAPTURES:?set CAPTURES to the head commit captures dir}
ANCHORS=${ANCHORS:-$HELPER_ROOT/../real-anchors}
mkdir -p "$OUT"
: > "$OUT/transcript.txt"
say() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }
section() { say ""; say "### $*"; }

REAL_TMUX=$(command -v tmux)
REAL_TREEHOUSE=$(command -v treehouse)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
H="$LAB/fm"
LAB_TMUX_DIR=
ID=fmlab-parked
cleanup() {
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
    "$LAB_HELPER" teardown "$H" >/dev/null 2>&1 || true
  fi
  pkill -f "fmlab-crew-agent-$$" 2>/dev/null || true
  rm -rf "/tmp/fm-$ID"
  chmod -R u+w "$LAB" 2>/dev/null
  rm -rf -- "$LAB"
}
LAB_HELPER="$CODE_ROOT/bin/fm-lab-home.sh"
trap cleanup EXIT

"$LAB_HELPER" create "$H" >/dev/null || { say "could not mark lab home"; exit 2; }
LAB_TMUX_DIR=$("$LAB_HELPER" tmux-dir "$H") || { say "could not isolate tmux"; exit 2; }
export TMUX_TMPDIR="$LAB_TMUX_DIR"
touch "$H/state/.last-watcher-beat"
printf 'tmux\n' > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"

U="$LAB/user-home"; mkdir -p "$U"
export HOME="$U" XDG_CONFIG_HOME="$U/.config" XDG_DATA_HOME="$U/.local/share" XDG_STATE_HOME="$U/.local/state" XDG_CACHE_HOME="$U/.cache"
export GIT_AUTHOR_NAME="FM Lab" GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME="FM Lab" GIT_COMMITTER_EMAIL=lab@example.invalid
unset TMUX TMUX_PANE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NM_HOME
export FM_HOME="$H"

# Project with a bare origin and a treehouse pool kept inside the lab.
PROJ="$LAB/project"; POOL="$LAB/pool"; mkdir -p "$PROJ" "$POOL"
git -C "$PROJ" init -q -b main
printf '# lab project\n' > "$PROJ/README.md"
printf 'root = "%s"\n' "$POOL" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" commit -qm initial
git clone -q --bare "$PROJ" "$LAB/origin.git"
git -C "$PROJ" remote add origin "file://$LAB/origin.git"
git -C "$PROJ" fetch -q origin
git -C "$PROJ" branch -q --set-upstream-to=origin/main main
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

# Brief for a no-mistakes ship task.
mkdir -p "$H/data/$ID"
cat > "$H/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Lab check that teardown concludes this task's own parked validation run.

## Firstmate spec
Commit one change and wait.

Delivery contract: mode=no-mistakes
EOF

# Stand-in no-mistakes CLI: stateful replay of real captures.
NMS="$LAB/nm"; mkdir -p "$NMS" "$LAB/bin"
cat > "$LAB/bin/no-mistakes" <<SH
#!/usr/bin/env bash
NMS="$NMS"
printf '%s\tcwd=%s\tno-mistakes %s\n' "\$(date +%H:%M:%S)" "\$PWD" "\$*" >> "\$NMS/calls.log"
case "\${1:-} \${2:-}" in
  "axi status")
    shift 2
    if [ "\${1:-}" = --run ] && [ "\${2:-}" != "\$(cat "\$NMS/run-id")" ]; then
      printf 'error: "run \\\\"%s\\\\" not found"\n' "\$2" >&2; exit 1
    fi
    cat "\$NMS/status.toon"; exit 0 ;;
  "axi abort")
    shift 2
    if [ "\${1:-}" = --run ] && [ "\${2:-}" = "\$(cat "\$NMS/run-id")" ]; then
      cp "\$NMS/cancelled.toon" "\$NMS/status.toon"
      echo "aborted \$2" >> "\$NMS/aborts.log"
    fi
    exit 0 ;;
  "axi ") exit 0 ;;
  "runs "*) cat "\$NMS/runs.txt" 2>/dev/null; exit 0 ;;
esac
exit 0
SH
chmod +x "$LAB/bin/no-mistakes"
printf '#!/bin/sh\nexec "%s" -f /dev/null "$@"\n' "$REAL_TMUX" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"

bind_capture() {  # <file> <branch> <head-short> <head-full> <run-id>
  awk -v branch="$2" -v head="$3" -v full="$4" -v id="$5" '
    /^  id:/ { print "  id: \"" id "\""; next }
    /^  branch:/ { print "  branch: " branch; next }
    /^  head:/ { print "  head: " head; next }
    /^  head_sha:/ { print "  head_sha: " full; next }
    { print }
  ' "$1"
}

tmux new-session -d -s firstmate -n lab -x 160 -y 50 "/bin/bash --noprofile --norc" || { say "no tmux"; exit 2; }
tmux set-option -g default-command "/bin/bash --noprofile --norc" >/dev/null

section "code root under test: $CODE_ROOT ($(git -C "$CODE_ROOT" rev-parse --short HEAD 2>/dev/null || cat "$CODE_ROOT/.lab-label" 2>/dev/null))"
say "scenario: $SCENARIO"
say "no-mistakes on PATH: $(command -v no-mistakes) (lab stand-in replaying real captures)"
say "treehouse: $REAL_TREEHOUSE ($(treehouse --version 2>/dev/null | head -1))"

section "1. real fm-spawn of a no-mistakes ship task into the lab"
( cd "$PROJ" && FM_SPAWN_NO_GUARD=1 "$CODE_ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" \
    "sh -c 'exec -a fmlab-crew-agent-$$ sleep 900'" --mode no-mistakes --yolo off --backend tmux ) \
  > "$OUT/spawn.out" 2>&1
rc=$?
say "fm-spawn exit $rc: $(grep -E '^(spawned|error|warning|REFUSED)' "$OUT/spawn.out" | head -5 | tr '\n' ' ')"
[ "$rc" = 0 ] || { cat "$OUT/spawn.out" >> "$OUT/transcript.txt"; exit 3; }
META="$H/state/$ID.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
WIN=$(sed -n 's/^window=//p' "$META")
BR=$(git -C "$WT" symbolic-ref --quiet --short HEAD || true)
say "meta: worktree=$WT window=$WIN branch=$BR kind=$(sed -n 's/^kind=//p' "$META") mode=$(sed -n 's/^mode=//p' "$META")"
say "tmux windows: $(tmux list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"

section "2. the crew creates its branch, commits, and pushes its work (what the run validates)"
[ -n "$BR" ] || { BR="fm/$ID"; git -C "$WT" checkout -qb "$BR"; }
printf 'shippable work\n' > "$WT/work.txt"
git -C "$WT" add work.txt && git -C "$WT" commit -qm "shippable work"
git -C "$WT" push -q origin "$BR"
git -C "$PROJ" fetch -q origin
HEAD_FULL=$(git -C "$WT" rev-parse HEAD); HEAD_SHORT=$(git -C "$WT" rev-parse --short=8 HEAD)
say "task HEAD $HEAD_SHORT pushed to origin/$BR"

RUN_ID=01MLABPARKEDRUN0000000000
echo "$RUN_ID" > "$NMS/run-id"
bind_capture "$CAPTURES/superseded.toon" "$BR" "$HEAD_SHORT" "$HEAD_FULL" "$RUN_ID" \
  | sed 's/superseded by new push/aborted/' > "$NMS/cancelled.toon"
case "$SCENARIO" in
  parked-own-head)
    bind_capture "$CAPTURES/parked.toon" "$BR" "$HEAD_SHORT" "$HEAD_FULL" "$RUN_ID" > "$NMS/status.toon" ;;
  parked-pushed-fix)
    # The pipeline's gate-repo clone commits its own fix round on the branch
    # and pushes it; the task copy never fetches it.
    git clone -q "$LAB/origin.git" "$LAB/pipeline-clone"
    git -C "$LAB/pipeline-clone" checkout -q "$BR"
    printf 'pipeline fix\n' >> "$LAB/pipeline-clone/work.txt"
    git -C "$LAB/pipeline-clone" commit -qam "no-mistakes(test): fix round"
    git -C "$LAB/pipeline-clone" push -q origin "$BR"
    FIX_FULL=$(git -C "$LAB/pipeline-clone" rev-parse HEAD); FIX_SHORT=${FIX_FULL:0:8}
    if git -C "$WT" rev-parse --verify --quiet "$FIX_FULL^{commit}" >/dev/null; then say "fixture broke: fix commit visible in task copy"; exit 3; fi
    say "pipeline pushed its own fix $FIX_SHORT; task copy still at $HEAD_SHORT and cannot resolve $FIX_SHORT"
    { bind_capture "$CAPTURES/parked.toon" "$BR" "$FIX_SHORT" "$FIX_FULL" "$RUN_ID"
      cat <<EOF
branch_sync:
  state: behind
  local:
    branch: $BR
    head: $HEAD_FULL
    clean: true
  pipeline:
    run: "$RUN_ID"
    status: awaiting_approval
    submitted_head: $HEAD_FULL
    current_head: $FIX_FULL
    pushed_head: $FIX_FULL
  relation: behind
EOF
    } > "$NMS/status.toon"
    printf '  %-10s %-24s %-8s  %s %s\n' running "$BR" "$FIX_SHORT" 2026-10-23 09:12 > "$NMS/runs.txt" ;;
  executing)
    bind_capture "$ANCHORS/executing-v1.79.0.toon" "$BR" "$HEAD_SHORT" "$HEAD_FULL" "$RUN_ID" > "$NMS/status.toon" ;;
  other-branch)
    bind_capture "$CAPTURES/parked.toon" fm/some-other-task deadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$RUN_ID" > "$NMS/status.toon" ;;
  diverged-head)
    PREV_FULL=$(git -C "$WT" rev-parse HEAD~1); PREV_SHORT=${PREV_FULL:0:8}
    say "run head is $PREV_SHORT (resolves in the task copy, but is not its HEAD)"
    bind_capture "$CAPTURES/parked.toon" "$BR" "$PREV_SHORT" "$PREV_FULL" "$RUN_ID" > "$NMS/status.toon" ;;
  *) say "unknown scenario"; exit 2 ;;
esac

section "3. what \`no-mistakes axi status\` reports for the run before teardown"
sed 's/^/    /' "$NMS/status.toon" | head -40 | tee -a "$OUT/transcript.txt" >/dev/null
say "    (top-level status word: $(sed -n 's/^  status: //p' "$NMS/status.toon" | head -1))"
: > "$NMS/calls.log"

section "4. real fm-teardown.sh $ID"
( cd "$PROJ" && ${TEARDOWN_TRACE:+bash -x} "$CODE_ROOT/bin/fm-teardown.sh" "$ID" ) > "$OUT/teardown.stdout" 2> "$OUT/teardown.stderr"
TRC=$?
say "fm-teardown exit $TRC"
say "--- teardown stderr"; sed 's/^/    /' "$OUT/teardown.stderr" | tee -a "$OUT/transcript.txt" >/dev/null
say "--- teardown stdout"; sed 's/^/    /' "$OUT/teardown.stdout" | tee -a "$OUT/transcript.txt" >/dev/null
say "--- no-mistakes calls teardown made"; sed 's/^/    /' "$NMS/calls.log" | tee -a "$OUT/transcript.txt" >/dev/null

section "5. after teardown"
say "task meta present: $([ -e "$META" ] && echo yes || echo no)"
say "crew window $WIN present: $(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -qx "$WIN" && echo yes || echo no)"
say "task worktree registered with project: $(git -C "$PROJ" worktree list --porcelain | grep -q "^branch refs/heads/$BR\$" && echo yes || echo no)"
say "axi abort calls: $(grep -c 'axi abort' "$NMS/calls.log" 2>/dev/null || true)"
FINAL=$(sed -n 's/^  status: //p' "$NMS/status.toon" | head -1); OUTC=$(sed -n 's/^outcome: //p' "$NMS/status.toon")
GATE=$(grep -q '^gate:' "$NMS/status.toon" && echo "gate=$(sed -n '/^gate:/,/^[a-z]/s/^  step: //p' "$NMS/status.toon")" || echo "no gate")
say "run $RUN_ID final state: status=$FINAL outcome=${OUTC:-none} $GATE"
if [ "$SCENARIO" != other-branch ] && [ "$SCENARIO" != executing ] && [ "$SCENARIO" != diverged-head ] && [ -z "$OUTC" ]; then
  say "RESULT: the run is still PARKED with its worker gone (orphaned, holding a fleet slot)"
elif [ -n "$OUTC" ]; then
  say "RESULT: teardown concluded the run before removing its worker"
else
  say "RESULT: teardown left the run alone"
fi
printf '%s\n' "$TRC" > "$OUT/teardown.rc"
