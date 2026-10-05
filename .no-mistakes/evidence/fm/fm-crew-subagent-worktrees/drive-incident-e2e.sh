#!/usr/bin/env bash
# Live end-to-end driver for the reported incident and its fix, against the
# real installed Claude Code plus the real firstmate scripts of the checkout
# under test. Usage: drive-incident-e2e.sh <repo-root>
#   Arm 1 (defect + detection): an unhooked Claude session in a linked task
#     worktree isolates a subagent; its copy lands inside the primary checkout.
#     Real fm-guard and fm-bootstrap must report it, and the printed remedy
#     must refuse it while it holds work and retire it once it holds none.
#   Arm 2 (fix + teardown): real fm-spawn writes the Claude worker settings;
#     the same Claude call lands the copy under /tmp/fm-<id>/worktrees; the
#     primary stays clean and the guard is silent; a real ship teardown
#     refuses while the copy holds unlanded work and retires it once landed.
# shellcheck disable=SC2016
set -u
ROOT_ARG=$1
# shellcheck source=/dev/null
. "$ROOT_ARG/tests/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

MODEL=${MODEL:-haiku}
ID=swt-inc-$$
SCRATCH=/tmp/fm-$ID
LAB=$(fm_test_tmproot fm-swt-incident)
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$SCRATCH"; fm_test_cleanup' EXIT
fm_git_identity fmtest fmtest@example.invalid

h() { printf '\n==== %s ====\n' "$*"; }
step() { printf '\n$ %s\n' "$*"; }

PROMPT='Call the Agent tool exactly once, with isolation set to "worktree" and subagent_type "general-purpose". Tell the subagent to run exactly this one shell command and then report done: pwd -P > where.txt
After the subagent returns, reply with one word: finished.'

run_claude() {  # <dir> <transcript>
  (cd "$1" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    bash -c '. "$1"; fm_run_timed 300 claude -p --model "$2" --dangerously-skip-permissions --output-format text "$3"' \
    _ "$ROOT/bin/fm-timeout-lib.sh" "$MODEL" "$PROMPT") > "$2" 2>&1
}

# The "primary home": a normal checkout on main with an origin.
git init -q --bare -b main "$LAB/primary.origin.git"
git init -q -b main "$LAB/primary"
printf '# primary\n' > "$LAB/primary/README.md"
git -C "$LAB/primary" add README.md
git -C "$LAB/primary" commit -q -m initial
git -C "$LAB/primary" remote add origin "file://$LAB/primary.origin.git"
git -C "$LAB/primary" push -q -u origin main
git -C "$LAB/primary" remote set-head origin main >/dev/null
# Mirror the real firstmate home's .gitignore for the runtime dirs bootstrap writes.
printf '%s\n' state/ data/ config/ >> "$LAB/primary/.git/info/exclude"
P=$LAB/primary

guard() { FM_ROOT_OVERRIDE="$P" FM_HOME="$P" "$ROOT/bin/fm-guard.sh" 2>&1; }
bootstrap_tangle() { FM_ROOT_OVERRIDE="$P" FM_HOME="$P" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || echo "(no TANGLE lines)"; }

h "ARM 1: unhooked Claude worker (the reported defect) -> tangle detection"
git -C "$P" worktree add -q -b fm/unhooked "$LAB/task-unhooked" main
step "claude -p (model $MODEL) in linked task worktree $LAB/task-unhooked, no WorktreeCreate hook"
run_claude "$LAB/task-unhooked" "$LAB/arm1.out"; echo "[claude exit $?] reply: $(tail -1 "$LAB/arm1.out")"
step "git -C primary worktree list"; git -C "$P" worktree list
step "git -C primary status --porcelain --untracked-files=all"; git -C "$P" status --porcelain --untracked-files=all
step "where did the subagent actually run? (where.txt contents)"; cat "$P"/.claude/worktrees/*/where.txt 2>/dev/null || echo "(none)"
step "bin/fm-guard.sh with FM_ROOT=primary"; guard
step "bin/fm-bootstrap.sh TANGLE lines with FM_ROOT=primary"; bootstrap_tangle
step "printed remedy: fm-subagent-worktree.sh retire <primary> (copy still holds where.txt)"
"$ROOT/bin/fm-subagent-worktree.sh" retire "$P"; echo "[exit $?]"
step "copy still on disk?"; ls -d "$P"/.claude/worktrees/* 2>&1
step "inspect + drop the scratch output, then run the remedy again"
rm -f "$P"/.claude/worktrees/*/where.txt
"$ROOT/bin/fm-subagent-worktree.sh" retire "$P"; echo "[exit $?]"
step "git -C primary worktree list"; git -C "$P" worktree list
step "git -C primary branch --list 'worktree-*'"; git -C "$P" branch --list 'worktree-*'; echo "(end of branch list)"
step "bin/fm-guard.sh after the remedy"; guard | grep -A3 "WORKTREE TANGLE" || echo "(no WORKTREE TANGLE banner)"
rm -rf "$P/.claude"

h "ARM 2: Claude worker spawned by real fm-spawn (the fix) -> scratch placement + teardown"
git -C "$P" worktree add -q -b "fm/$ID" "$LAB/task" main
home=$LAB/home
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$home" claude
fm_test_spawn_brief "$home" "$ID"
rm -rf "$SCRATCH"
step "bin/fm-spawn.sh $ID $P claude --mode no-mistakes --yolo off (fake tmux/treehouse, pane at $LAB/task)"
out=$(fm_test_run_spawn "$home" "$LAB/task" "$fakebin" "$ID" "$P" claude --mode no-mistakes --yolo off); echo "[exit $?]"
printf '%s\n' "$out" | tail -3
step "WorktreeCreate hook fm-spawn wrote into $LAB/task/.claude/settings.local.json"
jq '.hooks.WorktreeCreate' "$LAB/task/.claude/settings.local.json"
step "claude -p (model $MODEL) in the spawned task worktree"
run_claude "$LAB/task" "$LAB/arm2.out"; echo "[claude exit $?] reply: $(tail -1 "$LAB/arm2.out")"
step "git -C primary worktree list"; git -C "$P" worktree list
step "git -C primary status --porcelain --untracked-files=all"; git -C "$P" status --porcelain --untracked-files=all; echo "(end of status)"
step "primary/.claude/worktrees exists?"; ls -d "$P/.claude/worktrees" 2>&1
step "where did the subagent actually run? (where.txt contents)"; cat "$SCRATCH"/worktrees/*/where.txt 2>/dev/null || cat /private"$SCRATCH"/worktrees/*/where.txt
step "bin/fm-guard.sh with FM_ROOT=primary"; guard | grep -A3 "WORKTREE TANGLE" || echo "(no WORKTREE TANGLE banner)"
step "bin/fm-bootstrap.sh TANGLE lines with FM_ROOT=primary"; bootstrap_tangle
step "fm-subagent-worktree.sh list <task> <task> $SCRATCH (teardown's inventory)"
"$ROOT/bin/fm-subagent-worktree.sh" list "$LAB/task" "$LAB/task" "$SCRATCH"

# Teardown fakes: no tmux/treehouse/herdr side effects, no PR, no no-mistakes run.
tdbin=$LAB/tdbin; mkdir -p "$tdbin"
for t in treehouse tmux gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tdbin/$t"; done
cat > "$tdbin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$tdbin/no-mistakes"
chmod +x "$tdbin"/*
teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR= \
    PATH="$tdbin:$PATH" "$ROOT/bin/fm-teardown.sh" "$ID" "$@"
}
# The task itself ships: one commit on its branch, pushed.
git -C "$LAB/task" commit -q --allow-empty -m "task work"
git -C "$LAB/task" push -q origin "fm/$ID"
git -C "$P" fetch -q origin
copy=$("$ROOT/bin/fm-subagent-worktree.sh" list "$LAB/task" "$LAB/task" "$SCRATCH" | cut -f2 | head -1)
step "bin/fm-teardown.sh $ID (ship) while the subagent copy still holds uncommitted where.txt"
teardown; echo "[teardown exit $?]"
step "copy and task record still present?"; ls -d "$copy"; ls "$home/state/$ID.meta"
step "land the subagent's work: commit in the copy, merge into the task branch, push"
git -C "$copy" add where.txt && git -C "$copy" commit -q -m "subagent output"
git -C "$LAB/task" merge -q --no-edit "worktree-$(basename "$copy")"
git -C "$LAB/task" push -q origin "fm/$ID"
"$ROOT/bin/fm-subagent-worktree.sh" list "$LAB/task" "$LAB/task" "$SCRATCH"
step "bin/fm-teardown.sh $ID (ship) again"
teardown; echo "[teardown exit $?]"
step "copy on disk?"; ls -d "$copy" 2>&1
step "git -C primary worktree list"; git -C "$P" worktree list
step "git -C primary branch --list 'worktree-*'"; git -C "$P" branch --list 'worktree-*'; echo "(end of branch list)"
step "task record?"; ls "$home/state/$ID.meta" 2>&1
