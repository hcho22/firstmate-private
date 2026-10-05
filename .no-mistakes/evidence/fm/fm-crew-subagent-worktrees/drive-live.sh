#!/usr/bin/env bash
# Live end-to-end driver for fm/fm-crew-subagent-worktrees.
# Drives the REAL installed Claude Code (isolated subagents through the Agent
# tool) and the REAL firstmate scripts (fm-spawn, fm-subagent-worktree, fm-guard,
# fm-bootstrap, fm-teardown) against throwaway lab repositories.
# Only external side-channel tools (tmux, treehouse, gh, gh-axi, no-mistakes,
# herdr) are stubbed, exactly as the repository's own teardown suite does, so no
# live fleet session, pane, or GitHub state is touched.
set -u
WTROOT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M44BR43SXK4JJJ6D2ES4X423
# shellcheck source=/dev/null
. "$WTROOT/tests/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
SWT="$ROOT/bin/fm-subagent-worktree.sh"
MODEL=${MODEL:-haiku}
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
LAB=$(fm_test_tmproot fm-swt-evidence)
LAB=$(cd "$LAB" && pwd -P)
ID=swt-ev-$$
SCRATCH=/tmp/fm-$ID
trap 'rm -rf "$SCRATCH" /tmp/fm-$ID-d; fm_test_cleanup' EXIT
fm_git_identity fmtest fmtest@example.invalid
PASSES=0 FAILS=0

say() { printf '\n## %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /'; local rc=${PIPESTATUS[0]}; printf '  [exit %s]\n' "$rc"; return "$rc"; }
check() {  # <label> <command...>
  local label=$1; shift
  if "$@"; then printf 'CHECK PASS: %s\n' "$label"; PASSES=$((PASSES+1))
  else printf 'CHECK FAIL: %s\n' "$label"; FAILS=$((FAILS+1)); fi
}
run_claude() {  # <dir> <transcript> <prompt>
  (cd "$1" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    bash -c '. "$1"; fm_run_timed 300 claude -p --model "$2" --dangerously-skip-permissions --output-format text "$3"' \
    _ "$ROOT/bin/fm-timeout-lib.sh" "$MODEL" "$3") > "$2" 2>&1
}
lacks() { ! grep -q "$1" <<<"$2"; }
no_branch() { ! git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
registered_under() {  # <repo> <dir>: registered worktree paths under <dir>
  git -C "$1" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do
    [ "$p" != "$2" ] || continue
    case "$p/" in "$2/"*) printf '%s\n' "$p" ;; esac
  done
}

PROMPT_MARK='Call the Agent tool exactly once, with isolation set to "worktree" and subagent_type "general-purpose". Tell the subagent to run exactly this one shell command and then report done: pwd -P > where.txt
After the subagent returns, reply with one word: finished.'
PROMPT_COMMIT='Call the Agent tool exactly once, with isolation set to "worktree" and subagent_type "general-purpose". Tell the subagent to run exactly this one shell command and then report done: pwd -P > where.txt && git add where.txt && git -c user.email=sub@example.invalid -c user.name=sub commit -q -m "subagent work"
After the subagent returns, reply with one word: finished.'

echo "Claude Code: $CLAUDE_VERSION   model: $MODEL   git: $(git --version)"
echo "lab: $LAB   task scratch root: $SCRATCH"

###############################################################################
say "A. Reported incident, reproduced with real Claude and NO placement hook"
# primary = a firstmate primary home; crew = the crewmate's linked task worktree.
fm_git_worktree "$LAB/primary" "$LAB/crew-a" fm/task-a
git -C "$LAB/primary" remote set-head origin --auto >/dev/null 2>&1
run_claude "$LAB/crew-a" "$LAB/a.out" "$PROMPT_MARK"; echo "claude exit: $? / reply: $(tail -1 "$LAB/a.out")"
nested=$(registered_under "$LAB/primary" "$LAB/primary/.claude/worktrees" | head -1)
run git -C "$LAB/primary" worktree list
run git -C "$LAB/primary" status --porcelain
check "unhooked isolated subagent lands inside the PRIMARY at .claude/worktrees (bug reproduced)" test -n "$nested"
check "the subagent really ran in that nested copy" test "$(cat "$nested/where.txt" 2>/dev/null)" = "$nested"

say "A2. Tangle check (fm-guard banner) reports the Claude-created nested worktree"
guard_out=$(FM_ROOT_OVERRIDE="$LAB/primary" FM_HOME="$LAB/primary" "$ROOT/bin/fm-guard.sh" 2>&1)
printf '%s\n' "$guard_out" | sed 's/^/  /'
check "fm-guard banner names WORKTREES REGISTERED INSIDE THE PRIMARY CHECKOUT" grep -q "WORKTREES REGISTERED INSIDE THE PRIMARY CHECKOUT" <<<"$guard_out"
check "fm-guard banner lists the copy as unlanded (it holds an untracked where.txt)" grep -Fq "$nested (branch worktree-$(basename "$nested"), unlanded)" <<<"$guard_out"
check "fm-guard prints the retire remedy" grep -Fq "fm-subagent-worktree.sh retire $LAB/primary" <<<"$guard_out"

say "A3. Tangle check (fm-bootstrap TANGLE line) reports it too"
boot_out=$(FM_ROOT_OVERRIDE="$LAB/primary" FM_HOME="$LAB/primary" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
printf '%s\n' "$boot_out" | sed 's/^/  /'
check "bootstrap prints one TANGLE line naming the nested copy" grep -Fq "TANGLE: worktree '$nested'" <<<"$boot_out"

say "A4. The printed remedy refuses a copy that still holds work, then removes it once it is landed"
run "$SWT" retire "$LAB/primary"; rc=$?
check "retire refuses the unlanded nested copy (exit 1)" test "$rc" = 1
check "the unlanded copy and its where.txt are still on disk" test -f "$nested/where.txt"
rm -f "$nested/where.txt"   # the captain inspected it and found nothing worth keeping
run "$SWT" list "$LAB/primary"
run "$SWT" retire "$LAB/primary"; rc=$?
check "retire removes the now-landed copy (exit 0)" test "$rc" = 0
check "the nested copy is gone from disk" test ! -e "$nested"
check "nothing is registered inside the primary any more" test -z "$(registered_under "$LAB/primary" "$LAB/primary")"
check "its landed worktree-* branch was deleted" no_branch "$LAB/primary" "worktree-$(basename "$nested")"
guard_out=$(FM_ROOT_OVERRIDE="$LAB/primary" FM_HOME="$LAB/primary" "$ROOT/bin/fm-guard.sh" 2>&1)
check "fm-guard is silent once the primary is clean" lacks 'WORKTREES REGISTERED INSIDE' "$guard_out"

###############################################################################
say "B. Real fm-spawn wiring + real Claude: the subagent's copy lands in the task scratch root"
home="$LAB/home"
fm_git_worktree "$LAB/project" "$LAB/task" fm/$ID
git -C "$LAB/project" remote set-head origin --auto >/dev/null 2>&1
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$home" claude
fm_test_spawn_brief "$home" "$ID"
spawn_out=$(fm_test_run_spawn "$home" "$LAB/task" "$fakebin" "$ID" "$LAB/project" claude --mode no-mistakes --yolo off); spawn_rc=$?
echo "fm-spawn exit: $spawn_rc"
echo "WorktreeCreate hook fm-spawn wrote into $LAB/task/.claude/settings.local.json:"
jq '.hooks.WorktreeCreate' "$LAB/task/.claude/settings.local.json" | sed 's/^/  /'
echo "task meta:"; sed 's/^/  /' "$home/state/$ID.meta"
check "fm-spawn wrote a WorktreeCreate hook for the Claude worker" jq -e '.hooks.WorktreeCreate' "$LAB/task/.claude/settings.local.json"
cp "$LAB/task/.claude/settings.local.json" "$LAB/spawned-settings.json"  # teardown later cleans the task's copy
# The task's own shippable work, pushed (so teardown's own landed check passes).
git -C "$LAB/task" commit -q --allow-empty -m "task work"
git -C "$LAB/task" push -q origin "fm/$ID"; git -C "$LAB/project" fetch -q origin
run_claude "$LAB/task" "$LAB/b.out" "$PROMPT_COMMIT"; echo "claude exit: $? / reply: $(tail -1 "$LAB/b.out")"
scratch_real=$(cd "$SCRATCH" 2>/dev/null && pwd -P)
copy=$(registered_under "$LAB/project" "$scratch_real/worktrees" | head -1)
run git -C "$LAB/project" worktree list
run git -C "$LAB/project" status --porcelain --untracked-files=all
run git -C "$copy" log --oneline -2
check "the isolated subagent's copy is registered under the task scratch root $scratch_real/worktrees" test -n "$copy"
check "the subagent really ran there" test "$(git -C "$copy" show HEAD:where.txt 2>/dev/null)" = "$copy"
check "the primary/main checkout has no .claude/worktrees" test ! -e "$LAB/project/.claude/worktrees"
check "the main checkout is clean" test -z "$(git -C "$LAB/project" status --porcelain --untracked-files=all)"
check "the task worktree status does not show the copy" lacks worktrees "$(git -C "$LAB/task" status --porcelain --untracked-files=all)"
guard_out=$(FM_ROOT_OVERRIDE="$LAB/project" FM_HOME="$LAB/project" "$ROOT/bin/fm-guard.sh" 2>&1)
check "fm-guard reports no tangle for the main checkout" lacks 'WORKTREE TANGLE' "$guard_out"
run "$SWT" list "$LAB/task" "$LAB/task" "$scratch_real"

say "B2. Ship teardown REFUSES while the subagent's commit exists only in its copy"
tdbin="$LAB/tdbin"; mkdir -p "$tdbin"
for t in treehouse tmux; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tdbin/$t"; done
printf '#!/usr/bin/env bash\necho "herdr refused by evidence driver" >&2; exit 1\n' > "$tdbin/herdr"
cat > "$tdbin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$tdbin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1 ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$tdbin/no-mistakes"
chmod +x "$tdbin"/*
teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" PATH="$tdbin:$PATH" "$ROOT/bin/fm-teardown.sh" "$ID" "$@"
}
run teardown; rc=$?
check "ship teardown refuses (exit 1)" test "$rc" = 1
check "the copy holding the subagent's commit is still on disk" test -f "$copy/where.txt"
check "the task record is kept" test -f "$home/state/$ID.meta"

say "B3. After the subagent's branch is merged into the task branch, ship teardown retires the copy"
cbranch=$(git -C "$copy" symbolic-ref --short HEAD)
run git -C "$LAB/task" merge -q --no-edit "$cbranch"
git -C "$LAB/task" push -q origin "fm/$ID"; git -C "$LAB/project" fetch -q origin
run "$SWT" list "$LAB/task" "$LAB/task" "$scratch_real"
run teardown; rc=$?
check "ship teardown succeeds (exit 0)" test "$rc" = 0
check "the landed copy is gone from disk" test ! -e "$copy"
check "the landed copy is deregistered" test -z "$(registered_under "$LAB/project" "$scratch_real")"
check "its landed branch $cbranch was deleted" no_branch "$LAB/project" "$cbranch"
check "the task scratch root was removed" test ! -e "$SCRATCH"
check "the task record was removed" test ! -e "$home/state/$ID.meta"

###############################################################################
say "C. Adversarial, live: a hook that refuses never falls back to the main checkout"
git -C "$LAB/project" worktree add -q -b fm/task-c "$LAB/task-c"
mkdir -p "$LAB/task-c/.claude"
evil="$LAB/project/.claude/evil-scratch"
jq --arg cmd "'$SWT' create '$LAB/task-c' '$evil'" '.hooks.WorktreeCreate[0].hooks[0].command = $cmd' \
  "$LAB/spawned-settings.json" > "$LAB/task-c/.claude/settings.local.json"
echo "hook command under test: $(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$LAB/task-c/.claude/settings.local.json")"
before=$(git -C "$LAB/project" worktree list --porcelain | grep -c '^worktree ')
run_claude "$LAB/task-c" "$LAB/c.out" "$PROMPT_MARK"; echo "claude exit: $?"
echo "claude transcript (tail):"; tail -8 "$LAB/c.out" | sed 's/^/  /'
after=$(git -C "$LAB/project" worktree list --porcelain | grep -c '^worktree ')
run git -C "$LAB/project" worktree list
check "no worktree was registered (count $before -> $after)" test "$before" = "$after"
check "nothing was created under the main checkout's .claude" test ! -e "$LAB/project/.claude"
check "the main checkout is still clean" test -z "$(git -C "$LAB/project" status --porcelain --untracked-files=all)"

###############################################################################
say "D. Adversarial CLI checks of the landed test and retire (review round 5 fixes)"
D=/tmp/fm-$ID-d
echo "D1: status.showUntrackedFiles=no must not hide a new file"
git -C "$LAB/project" config status.showUntrackedFiles no
d1=$(printf '{"name":"agent-d1"}' | "$SWT" create "$LAB/task" "$D" 2>/dev/null)
echo "keep me" > "$d1/newfile.txt"
run git -C "$d1" status --porcelain
run "$SWT" list "$LAB/task" "$D"
check "D1 list says unlanded" bash -c "'$SWT' list '$LAB/task' '$D' | grep -q '^unlanded'"
run "$SWT" retire "$LAB/task" "$D"; rc=$?
check "D1 retire refuses (exit 1)" test "$rc" = 1
check "D1 newfile.txt is still on disk" test -f "$d1/newfile.txt"
git -C "$LAB/project" config --unset status.showUntrackedFiles
"$SWT" retire --discard "$LAB/task" "$D" >/dev/null 2>&1

echo "D2: a copy whose .git file was deleted but whose directory still holds files"
d2=$(printf '{"name":"agent-d2"}' | "$SWT" create "$LAB/task" "$D" 2>/dev/null)
echo "keep me" > "$d2/untracked.txt"; rm -f "$d2/.git"
run "$SWT" list "$LAB/task" "$D"
check "D2 list says unlanded (not missing)" bash -c "'$SWT' list '$LAB/task' '$D' | grep -q '^unlanded'"
run "$SWT" retire "$LAB/task" "$D"; rc=$?
check "D2 non-discard retire refuses (exit 1), file kept" bash -c "[ $rc = 1 ] && [ -f '$d2/untracked.txt' ]"
run "$SWT" retire --discard "$LAB/task" "$D"; rc=$?
check "D2 --discard retire removes it (exit 0)" bash -c "[ $rc = 0 ] && [ ! -e '$d2' ]"
check "D2 copy is deregistered" test -z "$(registered_under "$LAB/project" "$(cd /tmp && pwd -P)/fm-$ID-d")"

echo "D3: the hook refuses a destination inside the main checkout or an unsafe name"
run bash -c "printf '{\"name\":\"agent-x\"}' | '$SWT' create '$LAB/task' '$LAB/project/.claude/scratch'"; rc=$?
check "D3 scratch root inside the main checkout is refused, nothing created" bash -c "[ $rc = 1 ] && [ ! -e '$LAB/project/.claude/scratch' ]"
run bash -c "printf '{\"name\":\"../../escape\"}' | '$SWT' create '$LAB/task' '$D'"; rc=$?
check "D3 a path-traversal name is refused" test "$rc" = 1
run bash -c "printf '{\"name\":\"agent-y\"}' | '$SWT' create '$LAB/task' 'relative/scratch'"; rc=$?
check "D3 a relative scratch root is refused" test "$rc" = 1

printf '\n== SUMMARY: %s checks passed, %s failed ==\n' "$PASSES" "$FAILS"
[ "$FAILS" = 0 ]
