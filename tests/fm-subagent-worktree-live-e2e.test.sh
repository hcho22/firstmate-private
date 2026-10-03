#!/usr/bin/env bash
# Opt-in live guard for the Claude isolated-subagent worktree placement that
# bin/fm-spawn.sh wires through bin/fm-subagent-worktree.sh.
# Proves, against the real installed Claude Code, both halves of the claim:
#   - control: launched from a linked task worktree with no placement hook, an
#     Agent call with `isolation: "worktree"` creates its copy inside the
#     repository's MAIN checkout under .claude/worktrees/ - the defect;
#   - treatment: with the exact .claude/settings.local.json the real fm-spawn
#     writes for a Claude worker, the same call creates its copy under the
#     task's scratch root, the subagent really runs there, and the main
#     checkout stays clean.
# The subagent records its own `pwd -P` into a file in its working directory,
# so the verdict reads where it actually ran rather than what a model reports.
# The lab is a throwaway repository; Claude keeps its existing authentication.
# No live fleet home, worktree, or session is touched.
# Refresh docs/verification/runtime-backends.md "Claude isolated-subagent
# worktree placement" from this guard after every Claude upgrade.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_SUBAGENT_WORKTREE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SUBAGENT_WORKTREE_LIVE_E2E=1 to run the live Claude subagent worktree placement guard"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

command -v claude >/dev/null 2>&1 || fail "claude is not installed; this guard refuses to pass without checking it"
command -v jq >/dev/null 2>&1 || fail "jq is required"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
MODEL=${FM_SUBAGENT_WORKTREE_LIVE_MODEL:-haiku}
ID=swt-live-$$
SCRATCH="/tmp/fm-$ID"
LAB=$(fm_test_tmproot fm-subagent-worktree-live)
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$SCRATCH"; fm_test_cleanup' EXIT
fm_git_identity fmtest fmtest@example.invalid

PROMPT='Call the Agent tool exactly once, with isolation set to "worktree" and subagent_type "general-purpose". Tell the subagent to run exactly this one shell command and then report done: pwd -P > where.txt
After the subagent returns, reply with one word: finished.'

run_claude() {  # <dir> <transcript>
  (cd "$1" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    bash -c '. "$1"; fm_run_timed 300 claude -p --model "$2" --dangerously-skip-permissions --output-format text "$3"' \
    _ "$ROOT/bin/fm-timeout-lib.sh" "$MODEL" "$PROMPT") > "$2" 2>&1
}

# copy_with_marker <listing-root>: echo the one registered worktree under the
# given directory whose where.txt names itself.
copy_with_marker() {
  local root=$1 line path found=
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path=${line#worktree } ;;
      *) continue ;;
    esac
    case "$path/" in
      "$root/"*) ;;
      *) continue ;;
    esac
    [ -f "$path/where.txt" ] || continue
    [ "$(cat "$path/where.txt")" = "$path" ] || continue
    found=$path
  done < <(git -C "$LAB/project" worktree list --porcelain)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# One project with an origin, plus two linked task worktrees of it.
fm_git_worktree "$LAB/project" "$LAB/control" wt-control
git -C "$LAB/project" remote set-head origin --auto >/dev/null 2>&1
git -C "$LAB/project" worktree add -q -b wt-treatment "$LAB/treatment"

# Control arm: no placement hook.
run_claude "$LAB/control" "$LAB/control.out" || fail "claude $CLAUDE_VERSION control run failed: $(tail -5 "$LAB/control.out")"
control_copy=$(copy_with_marker "$LAB/project/.claude/worktrees") \
  || fail "claude $CLAUDE_VERSION: an unhooked isolated subagent no longer lands in the main checkout's .claude/worktrees - re-verify the premise and update the verification record (output: $(tail -5 "$LAB/control.out"))"
echo "control: claude $CLAUDE_VERSION placed the unhooked copy at $control_copy"
"$ROOT/bin/fm-subagent-worktree.sh" retire --discard "$LAB/project" >/dev/null 2>&1 || true
rm -rf "$LAB/project/.claude"

# Treatment arm: the settings the real fm-spawn writes for a Claude worker.
home="$LAB/home"
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$home" claude
fm_test_spawn_brief "$home" "$ID"
rm -rf "$SCRATCH"
out=$(fm_test_run_spawn "$home" "$LAB/treatment" "$fakebin" "$ID" "$LAB/project" claude --mode no-mistakes --yolo off) \
  || fail "fixture fm-spawn failed: $out"
jq -e '.hooks.WorktreeCreate' "$LAB/treatment/.claude/settings.local.json" >/dev/null \
  || fail "fm-spawn did not write a WorktreeCreate hook"
run_claude "$LAB/treatment" "$LAB/treatment.out" || fail "claude $CLAUDE_VERSION treatment run failed: $(tail -5 "$LAB/treatment.out")"
scratch_real=$(cd "$SCRATCH" 2>/dev/null && pwd -P) \
  || fail "claude $CLAUDE_VERSION: the hooked run never created the task scratch root (output: $(tail -5 "$LAB/treatment.out"))"
treatment_copy=$(copy_with_marker "$scratch_real/worktrees") \
  || fail "claude $CLAUDE_VERSION: the hooked isolated subagent did not run in a copy under $scratch_real/worktrees (output: $(tail -5 "$LAB/treatment.out"))"
[ ! -e "$LAB/project/.claude/worktrees" ] \
  || fail "claude $CLAUDE_VERSION: the hooked run still created $LAB/project/.claude/worktrees"
[ -z "$(git -C "$LAB/project" status --porcelain --untracked-files=all)" ] \
  || fail "claude $CLAUDE_VERSION: the hooked run dirtied the main checkout"
echo "treatment: claude $CLAUDE_VERSION placed the hooked copy at $treatment_copy"
"$ROOT/bin/fm-subagent-worktree.sh" retire --discard "$LAB/treatment" "$scratch_real" >/dev/null 2>&1 || true
pass "claude $CLAUDE_VERSION: the fm-spawn placement hook moves an isolated subagent's worktree out of the main checkout"
