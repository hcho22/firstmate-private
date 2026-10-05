#!/usr/bin/env bash
# Live adversarial driver: when the WorktreeCreate hook refuses, the real
# Claude Code must fail that isolated worktree instead of falling back to the
# main checkout. The hook is the real fm-subagent-worktree.sh create, given a
# scratch root inside the main checkout so it refuses before creating anything.
# Usage: drive-hook-fail-closed.sh <repo-root>
# shellcheck disable=SC2016
set -u
ROOT_ARG=$1
# shellcheck source=/dev/null
. "$ROOT_ARG/tests/fixtures.sh"
MODEL=${MODEL:-haiku}
LAB=$(fm_test_tmproot fm-swt-failclosed)
LAB=$(cd "$LAB" && pwd -P)
fm_git_identity fmtest fmtest@example.invalid
step() { printf '\n$ %s\n' "$*"; }

PROMPT='Call the Agent tool exactly once, with isolation set to "worktree" and subagent_type "general-purpose". Tell the subagent to run exactly this one shell command and then report done: pwd -P > where.txt
After the Agent call returns (whether it succeeded or failed), reply with one line: the Agent result or error text.'

git init -q --bare -b main "$LAB/primary.origin.git"
git init -q -b main "$LAB/primary"
git -C "$LAB/primary" commit -q --allow-empty -m initial
git -C "$LAB/primary" remote add origin "file://$LAB/primary.origin.git"
git -C "$LAB/primary" push -q -u origin main
git -C "$LAB/primary" remote set-head origin main >/dev/null
P=$LAB/primary
git -C "$P" worktree add -q -b fm/failclosed "$LAB/task" main
mkdir -p "$LAB/task/.claude"
hookcmd=$(printf '%q create %q %q' "$ROOT/bin/fm-subagent-worktree.sh" "$LAB/task" "$P/.claude")
jq -n --arg c "$hookcmd" '{hooks:{WorktreeCreate:[{hooks:[{type:"command",command:$c,timeout:600}]}]}}' \
  > "$LAB/task/.claude/settings.local.json"
printf '.claude/settings.local.json\n' >> "$(git -C "$LAB/task" rev-parse --git-common-dir)/info/exclude"
step "hook in $LAB/task/.claude/settings.local.json (scratch root deliberately inside the main checkout)"
jq . "$LAB/task/.claude/settings.local.json"
step "claude -p (model $MODEL) in the task worktree"
(cd "$LAB/task" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
  bash -c '. "$1"; fm_run_timed 300 claude -p --model "$2" --dangerously-skip-permissions --output-format text "$3"' \
  _ "$ROOT/bin/fm-timeout-lib.sh" "$MODEL" "$PROMPT") > "$LAB/claude.out" 2>&1
echo "[claude exit $?]"; echo "--- claude reply ---"; cat "$LAB/claude.out"; echo "--------------------"
step "git -C primary worktree list"; git -C "$P" worktree list
step "ls -A primary"; ls -A "$P"
step "primary/.claude/worktrees exists?"; ls -d "$P/.claude/worktrees" 2>&1
step "git -C primary status --porcelain --untracked-files=all"; git -C "$P" status --porcelain --untracked-files=all; echo "(end of status)"
step "any where.txt anywhere in the lab?"; find "$LAB" -name where.txt -not -path '*/.git/*' 2>/dev/null; echo "(end of find)"
