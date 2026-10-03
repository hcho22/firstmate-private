#!/usr/bin/env bash
# Behavior tests for bin/fm-subagent-worktree.sh and the Claude worker wiring
# bin/fm-spawn.sh installs for it.
#
# A task worktree is a linked worktree sharing the project's git common dir, so
# Claude resolves it back to the repository's MAIN checkout and, unhooked,
# creates every isolated subagent's worktree under <main>/.claude/worktrees/.
# These cases pin the fix with real git and no harness:
#   - create places the copy under the task's scratch root, never inside the
#     main checkout or the task worktree, mirrors Claude's branch naming and
#     default base, resumes and attaches without resetting, and fails closed on
#     every malformed or unsafe request;
#   - list and retire classify and retire copies with the landed test teardown
#     and the primary-checkout remedy rely on, forcing past populated
#     submodules and locks only where removal is already authorized, and fail
#     closed when git cannot list the repository's worktrees;
#   - the real fm-spawn writes the hook into a Claude worker's local settings,
#     and running it the way Claude does keeps the main checkout untouched and
#     fails closed.
# tests/fm-subagent-worktree-live-e2e.test.sh proves the same wiring against the
# installed Claude binary.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HELPER="$ROOT/bin/fm-subagent-worktree.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-worktree)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_git_identity fmtest fmtest@example.invalid

# make_world <name>: a main checkout on main with a bare origin and origin/HEAD,
# plus a detached linked task worktree whose HEAD is one commit AHEAD of
# origin/main, so a copy's base can be told apart. Echoes the case dir.
make_world() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/main" 2>/dev/null
  git -C "$dir/main" checkout -q -b main
  git -C "$dir/main" commit -q --allow-empty -m init
  git -C "$dir/main" push -q origin main
  git -C "$dir/main" remote set-head origin main >/dev/null 2>&1
  git -C "$dir/main" worktree add -q --detach "$dir/task" main
  git -C "$dir/task" commit -q --allow-empty -m "task work"
  printf '%s\n' "$dir"
}

# assert_row <listing> <state> <path> <branch> <msg>: one exact list line.
assert_row() {
  printf '%s\n' "$1" | grep -Fxq "$(printf '%s\t%s\t%s' "$2" "$3" "$4")" \
    || fail "$5"$'\n'"--- listing ---"$'\n'"$1"
}

hook() {  # <mode> <task-worktree> <scratch-root> <json>
  printf '%s' "$4" | "$HELPER" "$1" "$2" "$3"
}

main_is_untouched() {  # <case-dir> <label>
  local dir=$1 label=$2 status
  status=$(git -C "$dir/main" status --porcelain --untracked-files=all)
  [ -z "$status" ] || fail "$label: the main checkout was dirtied: $status"
  assert_absent "$dir/main/.claude" "$label: a .claude directory appeared in the main checkout"
}

test_create_places_copy_in_scratch_root() {
  local dir out origin_main task_head
  dir=$(make_world create)
  out=$(hook create "$dir/task" "$dir/tmp" '{"hook_event_name":"WorktreeCreate","name":"agent-a1"}' 2>/dev/null)
  expect_code 0 $? "create should succeed"
  [ "$out" = "$dir/tmp/worktrees/agent-a1" ] || fail "create printed '$out', want the canonical scratch path"
  [ "$(git -C "$out" symbolic-ref --short HEAD)" = worktree-agent-a1 ] \
    || fail "copy is not on Claude's worktree-<name> branch"
  origin_main=$(git -C "$dir/main" rev-parse origin/main)
  task_head=$(git -C "$dir/task" rev-parse HEAD)
  [ "$origin_main" != "$task_head" ] || fail "fixture must separate origin/main from the task HEAD"
  [ "$(git -C "$out" rev-parse HEAD)" = "$origin_main" ] \
    || fail "copy must default to the remote default branch, like Claude's own default"
  git -C "$dir/main" worktree list --porcelain | grep -Fxq "worktree $out" \
    || fail "copy is not registered in the shared repository"
  main_is_untouched "$dir" create
  [ -z "$(git -C "$dir/task" status --porcelain)" ] || fail "create dirtied the task worktree"

  out=$(hook create "$dir/task" "$dir/tmp" '{"worktree_name":"feat/x","base_ref":"HEAD"}' 2>/dev/null)
  expect_code 0 $? "create with the documented field names should succeed"
  [ "$out" = "$dir/tmp/worktrees/feat+x" ] || fail "a slash must map to '+' exactly as Claude does, got '$out'"
  [ "$(git -C "$out" rev-parse HEAD)" = "$task_head" ] || fail "an explicit base_ref must be honored"
  pass "create: the copy lands in the task scratch root on worktree-<name>, based like Claude's default"
}

test_create_resumes_and_attaches_without_reset() {
  local dir first again branch_head out
  dir=$(make_world resume)
  first=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-r"}' 2>/dev/null)
  again=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-r"}' 2>/dev/null)
  expect_code 0 $? "re-creating an existing copy should resume it"
  [ "$first" = "$again" ] || fail "resume printed a different path"

  git -C "$dir/main" branch worktree-agent-old "$(git -C "$dir/task" rev-parse HEAD)"
  branch_head=$(git -C "$dir/main" rev-parse worktree-agent-old)
  out=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-old"}' 2>/dev/null)
  expect_code 0 $? "an existing worktree-<name> branch should be attached"
  [ "$(git -C "$out" rev-parse HEAD)" = "$branch_head" ] || fail "an existing branch was reset instead of attached"

  mkdir -p "$dir/tmp/worktrees/agent-squat"
  out=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-squat"}' 2>&1)
  expect_code 1 $? "an unregistered directory at the destination must be refused"
  assert_contains "$out" "not a registered worktree" "squatted destination refusal lacked its reason"
  pass "create: resumes its own copy, attaches an existing branch unchanged, refuses a squatted path"
}

test_create_fails_closed() {
  local dir name out nojq cmd resolved
  dir=$(make_world refuse)
  for name in '../escape' '-flag' 'a..b' '.hidden' 'a b' 'x.lock' 'a//b' 'trail/'; do
    out=$(hook create "$dir/task" "$dir/tmp" "{\"name\":\"$name\"}" 2>&1)
    expect_code 1 $? "name '$name' must be refused"
  done
  out=$(hook create "$dir/task" "$dir/tmp" '{"name":""}' 2>&1)
  expect_code 1 $? "an empty name must be refused"
  out=$(hook create "$dir/task" "$dir/tmp" 'not json' 2>&1)
  expect_code 1 $? "a non-JSON payload must be refused"
  out=$("$HELPER" create "$dir/task" "$dir/tmp" </dev/null 2>&1)
  expect_code 1 $? "an empty payload must be refused"
  out=$(hook create "$dir/task" relative/root '{"name":"agent-x"}' 2>&1)
  expect_code 1 $? "a relative scratch root must be refused"
  out=$(hook create "$TMP_ROOT" "$dir/tmp" '{"name":"agent-x"}' 2>&1)
  expect_code 1 $? "a task worktree that is not a git work tree must be refused"

  out=$(hook create "$dir/task" "$dir/main/.claude" '{"name":"agent-in-main"}' 2>&1)
  expect_code 1 $? "a scratch root inside the main checkout must be refused"
  assert_contains "$out" "inside the main checkout" "main-checkout refusal lacked its reason"
  main_is_untouched "$dir" "refused main placement"
  out=$(hook create "$dir/task" "$dir/task/.scratch" '{"name":"agent-in-task"}' 2>&1)
  expect_code 1 $? "a scratch root inside the task worktree must be refused"
  assert_absent "$dir/task/.scratch" "a refused task-worktree placement left a directory behind"

  nojq="$dir/path-without-jq"
  mkdir -p "$nojq"
  for cmd in bash cat dirname basename git grep head mkdir sed tr; do
    resolved=$(command -v "$cmd") || continue
    ln -sf "$resolved" "$nojq/$cmd"
  done
  out=$(printf '{"name":"agent-nojq"}' | PATH="$nojq" "$HELPER" create "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "missing jq must fail closed"
  assert_contains "$out" "jq is required" "missing-jq refusal lacked its reason"
  assert_absent "$dir/tmp/worktrees/agent-nojq" "a jq-less create still made a copy"
  [ "$(git -C "$dir/main" worktree list | wc -l | tr -d ' ')" = 2 ] \
    || fail "a refused create registered a worktree"
  main_is_untouched "$dir" "refused creates"
  pass "create: fails closed on unsafe names, payloads, roots, placements, and missing jq"
}

test_list_and_retire_classify_copies() {
  local dir landed unlanded dirty locked missing nested listing out branch_tip
  dir=$(make_world retire)
  landed=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-landed"}' 2>/dev/null)
  unlanded=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-unlanded"}' 2>/dev/null)
  git -C "$unlanded" commit -q --allow-empty -m "subagent work"
  branch_tip=$(git -C "$unlanded" rev-parse HEAD)
  dirty=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-dirty"}' 2>/dev/null)
  printf 'x\n' > "$dirty/f"
  locked=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-locked"}' 2>/dev/null)
  git -C "$dir/main" worktree lock "$locked"
  missing=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-missing"}' 2>/dev/null)
  git -C "$dir/main" worktree lock "$missing"
  rm -rf "$missing"
  # A copy nested inside the task worktree itself is in scope too.
  nested="$dir/task/.nested-copy"
  git -C "$dir/main" worktree add -q --detach "$nested" main
  # A sibling task worktree elsewhere is never in scope.
  git -C "$dir/main" worktree add -q --detach "$dir/other-task" main

  listing=$("$HELPER" list "$dir/task" "$dir/task" "$dir/tmp")
  assert_row "$listing" landed "$landed" worktree-agent-landed "a clean copy on origin/main must list as landed"
  assert_row "$listing" unlanded "$unlanded" worktree-agent-unlanded "a copy with its own commit must list as unlanded"
  assert_row "$listing" unlanded "$dirty" worktree-agent-dirty "a copy with untracked work must list as unlanded"
  assert_row "$listing" locked "$locked" worktree-agent-locked "a locked copy must list as locked"
  assert_row "$listing" missing "$missing" worktree-agent-missing "a vanished copy must list as missing"
  assert_row "$listing" landed "$nested" detached "a copy nested in the task worktree must be listed"
  assert_not_contains "$listing" "$dir/other-task" "a worktree outside the scope was listed"
  assert_not_contains "$listing" "$dir/task"$'\t' "the scope directory itself was listed"
  assert_not_contains "$listing" "$dir/main"$'\t' "the main checkout was listed"

  out=$("$HELPER" retire "$dir/task" "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "retire must refuse while unlanded or locked copies remain"
  assert_contains "$out" "retired: $landed" "a landed copy was not retired"
  assert_contains "$out" "retired: $missing" "a vanished locked copy was not deregistered"
  assert_contains "$out" "retired: $nested" "a landed nested copy was not retired"
  assert_contains "$out" "REFUSED: worktree $unlanded" "an unlanded copy was not refused"
  assert_contains "$out" "REFUSED: worktree $locked" "a locked copy was not refused"
  assert_present "$unlanded" "an unlanded copy was removed"
  assert_present "$dirty/f" "a dirty copy's work was removed"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-landed \
    && fail "a landed copy's merged branch should be deleted"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-missing \
    && fail "a deregistered missing copy's landed branch should be deleted"

  out=$("$HELPER" retire --discard "$dir/task" "$dir/task" "$dir/tmp" 2>&1)
  expect_code 0 $? "retire --discard should remove every remaining copy"
  listing=$("$HELPER" list "$dir/task" "$dir/task" "$dir/tmp")
  [ -z "$listing" ] || fail "copies remain after a discard: $listing"
  [ "$(git -C "$dir/main" rev-parse worktree-agent-unlanded)" = "$branch_tip" ] \
    || fail "a discard must keep the unlanded copy's branch so its commits stay reachable"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-dirty \
    && fail "a discard should delete a discarded copy's landed branch"
  assert_present "$dir/other-task/.git" "a discard touched a worktree outside the scope"
  pass "list/retire: classify landed, unlanded, locked, and missing copies; retire only what is safe"
}

# add_origin_submodule <case-dir> [<ignore>]: commit a `sub` submodule to
# origin/main, with an optional .gitmodules `ignore` setting.
add_origin_submodule() {
  local dir=$1
  git init -q "$dir/sub"
  git -C "$dir/sub" commit -q --allow-empty -m sub
  git -C "$dir/main" -c protocol.file.allow=always submodule add -q "$dir/sub" sub
  if [ -n "${2:-}" ]; then
    git -C "$dir/main" config -f .gitmodules submodule.sub.ignore "$2"
    git -C "$dir/main" add .gitmodules
  fi
  git -C "$dir/main" commit -q -m "add submodule"
  git -C "$dir/main" push -q origin main
}

test_retire_forces_past_submodules_and_locks() {
  local dir copy dirty ahead sub_tip gone listing out
  dir=$(make_world forced)
  # ignore=all hides every submodule change from a plain `git status`.
  add_origin_submodule "$dir" all

  copy=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-sub-ship"}' 2>/dev/null)
  git -C "$copy" -c protocol.file.allow=always submodule update -q --init
  assert_row "$("$HELPER" list "$dir/task" "$dir/tmp")" landed "$copy" worktree-agent-sub-ship \
    "a clean copy with a populated submodule must list as landed"
  out=$("$HELPER" retire "$dir/task" "$dir/tmp" 2>&1)
  expect_code 0 $? "retire must remove a landed copy with a populated submodule: $out"
  assert_absent "$copy" "a landed copy with a populated submodule was kept"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-sub-ship \
    && fail "a retired landed copy's branch should be deleted"

  dirty=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-sub-dirty"}' 2>/dev/null)
  git -C "$dirty" -c protocol.file.allow=always submodule update -q --init
  printf 'work\n' > "$dirty/sub/work.txt"
  ahead=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-sub-ahead"}' 2>/dev/null)
  git -C "$ahead" -c protocol.file.allow=always submodule update -q --init
  git -C "$ahead/sub" commit -q --allow-empty -m "submodule work"
  sub_tip=$(git -C "$ahead/sub" rev-parse HEAD)
  listing=$("$HELPER" list "$dir/task" "$dir/tmp")
  assert_row "$listing" unlanded "$dirty" worktree-agent-sub-dirty \
    "uncommitted work in an ignore=all submodule must list as unlanded"
  assert_row "$listing" unlanded "$ahead" worktree-agent-sub-ahead \
    "a submodule commit the copy never recorded must list as unlanded"
  out=$("$HELPER" retire "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "retire must refuse copies whose submodules hold work: $out"
  assert_contains "$out" "REFUSED: worktree $dirty" "a copy with uncommitted submodule work was not refused"
  assert_contains "$out" "REFUSED: worktree $ahead" "a copy with an unrecorded submodule commit was not refused"
  assert_present "$dirty/sub/work.txt" "uncommitted submodule work was discarded"
  [ "$(git -C "$ahead/sub" rev-parse HEAD)" = "$sub_tip" ] || fail "an unrecorded submodule commit was discarded"

  copy=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-sub-scout"}' 2>/dev/null)
  git -C "$copy" -c protocol.file.allow=always submodule update -q --init
  gone=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-gone"}' 2>/dev/null)
  git -C "$dir/main" worktree lock "$gone"
  rm -rf "$gone"
  out=$("$HELPER" retire --discard "$dir/task" "$dir/tmp" 2>&1)
  expect_code 0 $? "retire --discard must remove a submodule copy and a locked vanished copy: $out"
  assert_contains "$out" "retired: $copy" "a discard did not retire the copy with a populated submodule"
  assert_contains "$out" "retired: $gone" "a discard did not deregister the locked vanished copy"
  [ -z "$("$HELPER" list "$dir/task" "$dir/tmp")" ] || fail "copies remain registered after a discard"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-sub-scout \
    && fail "a discard should delete a discarded copy's landed branch"
  pass "retire: submodule work blocks a ship retire; populated submodules and locks never block an authorized one"
}

test_submodule_commit_only_in_copy_is_unlanded() {
  local dir copy sub_commit out
  dir=$(make_world sub-unpushed)
  add_origin_submodule "$dir"
  copy=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-s"}' 2>/dev/null)
  git -C "$copy" -c protocol.file.allow=always submodule update -q --init
  git -C "$copy/sub" commit -q --allow-empty -m "submodule work"
  sub_commit=$(git -C "$copy/sub" rev-parse HEAD)
  git -C "$copy" add sub
  git -C "$copy" commit -q -m "record submodule work"
  git -C "$dir/task" merge -q --no-edit worktree-agent-s
  [ -z "$(git -C "$copy" status --porcelain --ignore-submodules=none)" ] || fail "fixture: the copy must be clean"
  git -C "$dir/task" merge-base --is-ancestor "$(git -C "$copy" rev-parse HEAD)" HEAD \
    || fail "fixture: the copy's HEAD must be in the task HEAD"

  assert_row "$("$HELPER" list "$dir/task" "$dir/tmp")" unlanded "$copy" worktree-agent-s \
    "a copy whose submodule commit exists only in the copy must list as unlanded"
  out=$("$HELPER" retire "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "retire must refuse a copy whose submodule commit exists nowhere else: $out"
  assert_contains "$out" "REFUSED: worktree $copy" "a copy holding the only submodule commit was not refused"
  assert_present "$copy" "a copy holding the only submodule commit was removed"
  [ "$(git -C "$copy/sub" cat-file -t "$sub_commit")" = commit ] || fail "the only copy of a submodule commit was lost"
  pass "list/retire: a submodule commit that exists only in the copy keeps the copy unlanded"
}

test_list_matches_a_vanished_scratch_root() {
  local dir copy out
  dir=$(make_world vanished)
  mkdir -p "$dir/real-tmp"
  ln -s "$dir/real-tmp" "$dir/tmp-link"
  copy=$(hook create "$dir/task" "$dir/tmp-link/fm-task" '{"name":"agent-v"}' 2>/dev/null)
  [ "$copy" = "$dir/real-tmp/fm-task/worktrees/agent-v" ] \
    || fail "fixture: create must register the canonical path, got '$copy'"
  rm -rf "$dir/real-tmp/fm-task"

  assert_row "$("$HELPER" list "$dir/task" "$dir/tmp-link/fm-task")" missing "$copy" worktree-agent-v \
    "a copy under a vanished scratch root reached through a symlink must list as missing"
  out=$("$HELPER" retire "$dir/task" "$dir/tmp-link/fm-task" 2>&1)
  expect_code 0 $? "retire must deregister a copy under a vanished scratch root: $out"
  git -C "$dir/main" worktree list --porcelain | grep -Fxq "worktree $copy" \
    && fail "the copy under a vanished scratch root is still registered"
  pass "list/retire: a vanished scratch root reached through a symlink still matches its copies"
}

# fake_git <dir> <case-pattern> <exit> <message>: put a git in <dir> that fails
# invocations whose space-joined arguments match <case-pattern> and runs the
# real git for everything else.
fake_git() {
  local real_git
  real_git=$(command -v git)
  mkdir -p "$1"
  cat > "$1/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  $2) echo "$4" >&2; exit $3 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}

test_inventory_fails_closed_without_worktree_list_z() {
  local dir copy listing out
  dir=$(make_world inventory)
  copy=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-inv"}' 2>/dev/null)

  # git before 2.36 has no `worktree list -z`.
  fake_git "$dir/git-old" '*" worktree list "*" -z "*' 129 "error: unknown switch z"
  listing=$(PATH="$dir/git-old:$PATH" "$HELPER" list "$dir/task" "$dir/tmp")
  expect_code 0 $? "list must work on a git without worktree list -z"
  assert_row "$listing" landed "$copy" worktree-agent-inv "list missed a copy on a git without worktree list -z"

  fake_git "$dir/git-broken" '*" worktree list "*' 128 "fatal: simulated worktree list failure"
  out=$(PATH="$dir/git-broken:$PATH" "$HELPER" list "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "list must fail when git cannot list worktrees"
  assert_contains "$out" "cannot list the registered worktrees" "the list failure lacked its reason"
  out=$(PATH="$dir/git-broken:$PATH" "$HELPER" retire "$dir/task" "$dir/tmp" 2>&1)
  expect_code 1 $? "retire must fail when git cannot list worktrees"
  assert_present "$copy" "a failed inventory still removed a copy"
  pass "list/retire: fail closed when git cannot list worktrees, and need no worktree list -z"
}

test_retire_deletes_branch_landed_on_remote() {
  local dir copy out
  dir=$(make_world remote-landed)
  git clone -q "$dir/origin.git" "$dir/other" 2>/dev/null
  git -C "$dir/other" commit -q --allow-empty -m "landed after the task branched"
  git -C "$dir/other" push -q origin main
  git -C "$dir/main" fetch -q origin
  copy=$(hook create "$dir/task" "$dir/tmp" '{"name":"agent-ahead"}' 2>/dev/null)
  [ "$(git -C "$copy" rev-parse HEAD)" = "$(git -C "$dir/main" rev-parse origin/main)" ] \
    || fail "fixture: the copy must be based on the fetched origin/main"
  git -C "$dir/task" merge-base --is-ancestor "$(git -C "$copy" rev-parse HEAD)" HEAD \
    && fail "fixture: the copy's base must not be in the task HEAD"

  out=$("$HELPER" retire "$dir/task" "$dir/tmp" 2>&1)
  expect_code 0 $? "retire must remove a copy landed on a remote: $out"
  assert_contains "$out" "retired: $copy" "a copy landed on a remote was not retired"
  git -C "$dir/main" show-ref --verify --quiet refs/heads/worktree-agent-ahead \
    && fail "a retired copy's branch whose tip is on a remote must be deleted"
  pass "retire: deletes a retired copy's branch whose tip landed only on a remote"
}

test_spawn_wires_claude_worker_hooks() {
  local case_dir home proj wt fakebin id=swt-claude-k7 out settings create_cmd copy scratch registered rc
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  scratch="/tmp/fm-$id"
  rm -rf "$scratch"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-spawn"
  git -C "$proj" remote set-head origin --auto >/dev/null 2>&1
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"

  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write its local settings"
  create_cmd=$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$settings")
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "the busy hook $ev was lost"
  done

  # Run the hook the way Claude does: /bin/sh -c from the worker's directory,
  # with the event payload on stdin. Claude fails the creation on a non-zero
  # exit or an empty stdout, so a refusal must surface as both.
  registered=$(git -C "$proj" worktree list --porcelain)
  out=$(cd "$wt" && printf '{"hook_event_name":"WorktreeCreate","name":"../x"}' | sh -c "$create_cmd" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the generated WorktreeCreate command exited 0 on an unsafe name instead of failing closed"
  [ -z "$out" ] || fail "the generated WorktreeCreate command printed '$out' on an unsafe name"
  [ "$(git -C "$proj" worktree list --porcelain)" = "$registered" ] \
    || fail "a refused WorktreeCreate registered a worktree"
  assert_absent "$scratch/x" "a refused WorktreeCreate made a copy"

  copy=$(cd "$wt" && printf '{"hook_event_name":"WorktreeCreate","name":"agent-spawned"}' | sh -c "$create_cmd")
  expect_code 0 $? "the generated WorktreeCreate command failed"
  [ "$copy" = "$(cd "$scratch" && pwd -P)/worktrees/agent-spawned" ] \
    || fail "the generated hook placed the copy at '$copy', not in the task scratch root"
  [ -z "$(git -C "$proj" status --porcelain --untracked-files=all)" ] \
    || fail "the project's main checkout was dirtied by the generated hook"
  assert_absent "$proj/.claude/worktrees" "the generated hook used the main checkout's .claude/worktrees"
  rm -rf "$scratch"
  pass "fm-spawn: a Claude worker's local settings route isolated worktrees into the task scratch root"
}

test_create_places_copy_in_scratch_root
test_create_resumes_and_attaches_without_reset
test_create_fails_closed
test_list_and_retire_classify_copies
test_retire_forces_past_submodules_and_locks
test_submodule_commit_only_in_copy_is_unlanded
test_retire_deletes_branch_landed_on_remote
test_list_matches_a_vanished_scratch_root
test_inventory_fails_closed_without_worktree_list_z
test_spawn_wires_claude_worker_hooks
