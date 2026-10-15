#!/usr/bin/env bash
# Live driver for the "lost pushed run" fix (fm/fm-crew-state-pushed-run).
#
# Runs the BASE and CHANGED bin/fm-crew-state.sh (and the wedge timer's
# crew_progress_evidence) against:
#   - the crew's REAL task copy for this branch (read-only: never committed to,
#     never fetched into),
#   - the REAL no-mistakes daemon and its real active run for this branch,
#   - the REAL runs ledger,
# from an isolated firstmate state dir and a private, empty tmux socket dir so
# the crew's pane reads as gone, exactly like the 2026-10-06 incident.
#
# Phase LIVE uses the daemon's answers untouched.
# Phase POST-PUSH passes every call through to the real binary and rewrites
# only the fields the post-push state changes (see rewrite rules below).
set -u
TC=${TC:-/Users/hcho/.treehouse/firstmate-private-0ac9d2/3/firstmate-private}
NEW=${NEW:?path to changed checkout}
BASE_REV=${BASE_REV:-15ab880458a2efc57ac53ca4298f489010eb5cb4}
REAL_NM=$(command -v no-mistakes)
T=$(mktemp -d /tmp/fmlive.XXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/base" "$T/tmux" "$T/wrap"
git -C "$NEW" archive "$BASE_REV" bin | tar -x -C "$T/base"
unset TMUX
export TMUX_TMPDIR="$T/tmux"

new_state() {  # <dir>
  mkdir -p "$1"
  printf '%s\n' "window=fm:fm-pushedrun-e2e" "worktree=$TC" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" > "$1/pushedrun.meta"
}

# Pass-through wrapper: execs the real no-mistakes, then applies sed program
# $FM_LIVE_REWRITE (if any) to `axi status` stdout only.
cat > "$T/wrap/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ] && [ -n "\${FM_LIVE_REWRITE:-}" ]; then
  "$REAL_NM" "\$@" | sed -E "\$FM_LIVE_REWRITE"
  exit "\${PIPESTATUS[0]}"
fi
exec "$REAL_NM" "\$@"
SH
chmod +x "$T/wrap/no-mistakes"

crew_state() {  # <tree> <state-dir>
  FM_STATE_OVERRIDE="$2" "$1/bin/fm-crew-state.sh" pushedrun
}

progress_evidence() {  # <tree> <state-dir>
  local anchor="$2/anchor"
  : > "$anchor"
  ( . "$1/bin/fm-classify-lib.sh"
    FM_STATE_OVERRIDE="$2" FM_CREW_STATE_BIN="$1/bin/fm-crew-state.sh" \
      crew_progress_evidence pushedrun "$2" "$anchor" 240 \
      && printf '  -> DEFER wedge escalation\n' \
      || printf '(no evidence)  -> ESCALATE: possible wedge\n' )
}

both() {  # <label>
  local tree
  printf '\n### %s\n' "$1"
  for tree in base new; do
    local root=$NEW; [ "$tree" = base ] && root=$T/base
    rm -rf "$T/state-$tree"; new_state "$T/state-$tree"
    printf '%-4s crew-state: %s\n' "$tree" "$(crew_state "$root" "$T/state-$tree")"
    printf '%-4s wedge timer evidence: %s\n' "$tree" "$(progress_evidence "$root" "$T/state-$tree")"
  done
}

echo "== environment"
echo "task copy: $TC"
echo "task copy branch: $(git -C "$TC" symbolic-ref --short HEAD)  HEAD: $(git -C "$TC" rev-parse HEAD)"
echo "no-mistakes: $REAL_NM ($("$REAL_NM" --version 2>/dev/null | tail -1))"
echo "tmux socket dir: private, no server -> the crew pane reads as gone"
echo
echo "== live axi status from the task copy (abridged)"
LIVE=$(cd "$TC" && "$REAL_NM" axi status 2>/dev/null)
printf '%s\n' "$LIVE" | grep -E '^  (id|branch|status|head_sha):|^  state:|^    (run|submitted_head|current_head|pushed_head):|^    test,'
run_head=$(printf '%s\n' "$LIVE" | sed -n 's/^  head_sha: //p' | head -1)
git -C "$TC" cat-file -e "$run_head^{commit}" 2>/dev/null \
  && echo "run head $run_head IS an object in the task copy" \
  || echo "run head $run_head is NOT an object in the task copy (pipeline fix commits never fetched)"
echo
echo "== live runs ledger rows for this branch"
(cd "$TC" && "$REAL_NM" runs --limit 200 2>/dev/null) | grep -E " $(git -C "$TC" symbolic-ref --short HEAD) " || echo "(none)"

echo
echo "== live attribution rules on the real data (changed lib)"
( . "$NEW/bin/fm-nm-run-lib.sh"
  br=$(git -C "$TC" symbolic-ref --short HEAD)
  printf 'branch_sync.pipeline.run            = %s\n' "$(fm_nm_branch_sync_field "$LIVE" pipeline run)"
  printf 'branch_sync.pipeline.submitted_head = %s\n' "$(fm_nm_branch_sync_field "$LIVE" pipeline submitted_head)"
  printf 'branch_sync.pipeline.status         = %s\n' "$(fm_nm_branch_sync_field "$LIVE" pipeline status)"
  fm_nm_head_matches_worktree "$TC" "$run_head" && r=binds || r=rejects; echo "strict head rule:            $r"
  fm_nm_run_is_pipeline_owned_active "$LIVE" && r=binds || r=rejects; echo "pipeline-owned custody rule: $r"
  fm_nm_run_is_submitted_head_active "$TC" "$LIVE" && r=binds || r=rejects; echo "submitted-head rule (new):   $r"
  led=$(fm_nm_runs_status_for_worktree "$TC" "$br" "$(cd "$TC" && "$REAL_NM" runs --limit 200 2>/dev/null)")
  echo "ledger continuation rule:    ${led:-prints nothing (no anchor row)}"
)

export PATH="$T/wrap:$PATH"
FM_LIVE_REWRITE='' both "LIVE: daemon answers untouched (branch_sync.state is currently pipeline_owned)"

POST='s/^  state: pipeline_owned$/  state: behind/'
FM_LIVE_REWRITE="$POST" both "POST-PUSH: real answers, branch_sync.state pipeline_owned -> behind (the value v1.79.0 reports after the pipeline pushes its fix commits)"

prev=$(git -C "$TC" rev-parse HEAD~1)
FM_LIVE_REWRITE="$POST; s/^(    submitted_head: ).*/\\1$prev/" \
  both "ADVERSARIAL post-push: submitted_head is another commit ($prev, this copy's HEAD~1: local work after submission / reused branch)"

FM_LIVE_REWRITE="$POST; s/^(    run: ).*/\\1\"01M4OTHERRUN00000000000000B\"/" \
  both "ADVERSARIAL post-push: branch_sync.pipeline.run names a different run"

FM_LIVE_REWRITE="$POST; s/^(  status: |    status: )running$/\\1cancelled/" \
  both "ADVERSARIAL post-push: the run is terminal (cancelled)"
