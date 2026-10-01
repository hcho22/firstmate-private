#!/usr/bin/env bash
# Behavior tests for the per-project task data layout.
#
# bin/fm-task-data-lib.sh owns where a task's private documents live
# (data/<ProjectDir>/<task-id>/) and resolves them through one lookup with a
# bounded legacy read of the old flat data/<task-id>/ folders.
# bin/fm-data-migrate.sh moves a home's flat folders into the new layout.
# The brief-to-teardown path in the new layout is covered end to end in
# tests/fm-backlog-atomicity.test.sh, where real spawn and teardown run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-data-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-data)

# --- helpers ----------------------------------------------------------------

# Run one resolver function in a clean subshell so sourcing never leaks.
lib() {  # <function> <args...>
  ( . "$ROOT/bin/fm-task-data-lib.sh"; "$@" )
}

# Content-and-layout signature of a whole tree: every directory and every
# file's checksum, so "nothing changed" is a byte-level statement.
tree_sig() {  # <dir>
  (
    cd "$1" || exit 1
    find . -type d | LC_ALL=C sort
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done
  )
}

write_brief_for() {  # <dir> <repo>
  mkdir -p "$1"
  printf 'You are in a disposable git worktree of %s, at a detached HEAD on a clean default branch.\n' "$2" > "$1/brief.md"
}

# A home with flat task folders in every shape the migration must place:
#   rt-alpha, rt-alpha-two   ship briefs naming RepToday (one id prefixes the other)
#   im-scout                 a scout naming Immerse, with a report
#   fmhome-own               a brief naming this firstmate home's own unregistered repo
#   backlog-only             no repo in its brief; the backlog line names Purvia
#   mate-one                 a registered secondmate's charter
#   lone-dir                 files only, no marker
#   mystery                  a brief that names no repo and no backlog line
make_home() {  # <name> -> prints the home
  local home="$TMP_ROOT/$1/fmhome"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
- RepToday [no-mistakes] - coaching app (added 2026-09-24)
- Immerse [direct-PR] - camera app (added 2026-09-29)
- Purvia [no-mistakes] - rag app (added 2026-09-29)
EOF
  write_brief_for "$home/data/rt-alpha" RepToday
  write_brief_for "$home/data/rt-alpha-two" RepToday
  write_brief_for "$home/data/im-scout" Immerse
  printf 'report\n' > "$home/data/im-scout/report.md"
  write_brief_for "$home/data/fmhome-own" fmhome
  mkdir -p "$home/data/backlog-only"
  printf '# brief without a repo line\n' > "$home/data/backlog-only/brief.md"
  mkdir -p "$home/data/mate-one"
  printf '# charter\n' > "$home/data/mate-one/brief.md"
  mkdir -p "$home/data/lone-dir"
  printf 'col\n' > "$home/data/lone-dir/list.csv"
  mkdir -p "$home/data/mystery"
  printf '# brief without a repo line\n' > "$home/data/mystery/brief.md"
  printf '%s\n' '- mate-one - a mate (home: /tmp/mate-one-home; scope: sample scope; projects: RepToday; added 2026-09-30)' \
    > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done

- [x] rt-alpha - Alpha task data/rt-alpha/report.md (repo: RepToday) (kind: scout)
  Evidence in /Users/x/firstmate/data/rt-alpha-two/out.txt and in data/rt-alpha.
  See "data/rt-alpha/report.md", (data/rt-alpha-two/report.md), then data/rt-alpha/ and data/rt-alpha.
  Not links: data/rt-alphabet/x and mydata/rt-alpha/x and data/RepToday/rt-alpha/report.md
- [x] backlog-only - Purvia work (repo: Purvia) (kind: scout)
  Deliverable: report data/backlog-only/report.md
EOF
  cp "$home/data/backlog.md" "$home/data/done-archive.md"
  printf 'Captain note: see data/rt-alpha/report.md for context.\n' > "$home/data/captain.md"
  printf '%s\n' "$home"
}

# The migration with the two placements the fixture cannot derive.
ASSIGN_ARGS=(--assign mystery=Purvia --assign lone-dir=RepToday)

# --- resolver ---------------------------------------------------------------

test_project_dirname_mapping() {
  local home data out
  home=$(make_home dirname)
  data="$home/data"
  [ "$(lib fm_task_data_project_dirname "$data" RepToday)" = RepToday ] || fail "a registered name was not kept"
  [ "$(lib fm_task_data_project_dirname "$data" reptoday)" = RepToday ] || fail "a registered name did not take the registry spelling"
  [ "$(lib fm_task_data_project_dirname "$data" projects/Immerse)" = Immerse ] || fail "a projects/<name> argument was not reduced to its name"
  [ "$(lib fm_task_data_project_dirname "$data" "$home/projects/Purvia")" = Purvia ] || fail "an absolute project path was not reduced to its name"
  [ "$(lib fm_task_data_project_dirname "$data" '')" = _unassigned ] || fail "no project did not map to _unassigned"
  [ "$(lib fm_task_data_project_dirname "$data" SomeUnregistered)" = SomeUnregistered ] || fail "an unregistered project did not get its own folder"
  [ "$(lib fm_task_data_project_dirname "$data" firstmate)" = firstmate ] || fail "the firstmate repo did not get an ordinary project folder"
  out=$(FM_HOME="$home" lib fm_task_data_project_dirname "$data" fmhome) || fail "dirname failed for the home's own name"
  [ "$out" = fmhome ] || fail "this home's own repo name did not get an ordinary project folder: $out"
  [ "$(lib fm_task_data_project_dirname "$data" _secondmates)" = _secondmates ] || fail "an internal folder name was not passed through"
  out=$(lib fm_task_data_project_dirname "$data" 'has space' 2>/dev/null) || fail "an unusable name must not fail"
  [ "$out" = _unassigned ] || fail "a name that cannot be a folder did not map to _unassigned: $out"
  out=$(lib fm_task_data_project_dirname "$data" handoff 2>/dev/null) || fail "a reserved name must not fail"
  [ "$out" = _unassigned ] || fail "a reserved root folder name became a project folder: $out"
  out=$(lib fm_task_data_project_dirname "$data" _sneaky 2>/dev/null) || fail "an underscore name must not fail"
  [ "$out" = _unassigned ] || fail "a user name in the reserved underscore space became a folder: $out"
  pass "project names map to registry spelling, their own name, reserved folders, or _unassigned"
}

test_project_dirname_adopts_an_existing_folder_spelling() {
  local home out
  home=$(make_home case-adopt)
  mkdir -p "$home/data/Unregistered"
  out=$(lib fm_task_data_project_dirname "$home/data" unregistered)
  [ "$out" = Unregistered ] || fail "a differently-cased existing folder was not adopted: $out"
  pass "an existing folder's spelling is adopted so a case-insensitive disk never holds two"
}

test_for_new_places_in_the_project_folder() {
  local home out rc
  home=$(make_home for-new)
  out=$(lib fm_task_data_dir_for_new "$home/data" fresh-task RepToday)
  [ "$out" = "$home/data/RepToday/fresh-task" ] || fail "new task placed at $out"
  out=$(lib fm_task_data_dir_for_new "$home/data/" fresh-task RepToday)
  [ "$out" = "$home/data/RepToday/fresh-task" ] || fail "a trailing slash on data changed the placement: $out"
  out=$(lib fm_task_data_dir_for_new "$home/data" rt-alpha Immerse)
  [ "$out" = "$home/data/rt-alpha" ] || fail "an id that already has a folder was not placed where it already lives: $out"
  rc=0; lib fm_task_data_dir_for_new "$home/data" '../escape' RepToday >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a traversal id returned $rc, expected 2"
  rc=0; lib fm_task_data_dir_for_new "$home/data" RepToday RepToday >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || fail "an id equal to a project folder name returned $rc, expected 4"
  rc=0; lib fm_task_data_dir_for_new "$home/data" _hidden RepToday >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || fail "an underscore id returned $rc, expected 4"
  [ ! -e "$home/data/RepToday" ] || fail "resolving a placement created a directory"
  pass "new tasks are placed in their project folder; existing folders and bad ids are respected"
}

test_lookup_canonical_legacy_and_ambiguity() {
  local home data out rc
  home=$(make_home lookup)
  data="$home/data"
  mkdir -p "$data/RepToday/canon-task" "$data/_unassigned/own-task"
  printf 'b\n' > "$data/RepToday/canon-task/brief.md"
  [ "$(lib fm_task_data_dir "$data" canon-task)" = "$data/RepToday/canon-task" ] || fail "canonical lookup failed"
  [ "$(lib fm_task_data_dir "$data" own-task)" = "$data/_unassigned/own-task" ] || fail "reserved folder lookup failed"
  [ "$(lib fm_task_data_dir "$data" rt-alpha)" = "$data/rt-alpha" ] || fail "the bounded legacy read did not find a flat folder"
  [ "$(lib fm_task_data_file "$data" rt-alpha brief.md)" = "$data/rt-alpha/brief.md" ] || fail "file lookup in a legacy folder failed"
  [ "$(lib fm_task_data_relpath "$data" canon-task)" = RepToday/canon-task ] || fail "relpath of a canonical folder is wrong"
  [ "$(lib fm_task_data_relpath "$data///" rt-alpha)" = rt-alpha ] || fail "relpath of a legacy folder is wrong"
  rc=0; lib fm_task_data_dir "$data" no-such-task >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "a missing task returned $rc, expected 1"
  rc=0; lib fm_task_data_dir "$data" '../rt-alpha' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a traversal id returned $rc, expected 2"
  for reserved in handoff extensions remote-secondmates RepToday _unassigned lone-dir; do
    mkdir -p "$data/$reserved"
    rc=0; lib fm_task_data_dir "$data" "$reserved" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || fail "$reserved was read as a task folder (rc=$rc)"
  done

  # A canonical folder wins over a leftover flat one for the same id.
  mkdir -p "$data/Immerse/rt-alpha"
  [ "$(lib fm_task_data_dir "$data" rt-alpha)" = "$data/Immerse/rt-alpha" ] || fail "the flat folder shadowed the canonical one"

  # The same id under two project folders is refused, never guessed.
  mkdir -p "$data/Purvia/rt-alpha"
  out=$(lib fm_task_data_dir "$data" rt-alpha 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] || fail "an id under two project folders returned $rc, expected 3"
  assert_contains "$out" "more than one project folder" "the ambiguity was not explained"
  pass "lookup finds canonical folders first, reads legacy ones, and refuses ambiguity"
}

test_lookup_ignores_symlinked_folders() {
  local home data outside
  home=$(make_home symlink)
  data="$home/data"
  outside="$TMP_ROOT/symlink/outside"
  mkdir -p "$outside/stolen-task" "$data/Purvia"
  ln -s "$outside" "$data/RepToday"
  ln -s "$outside/stolen-task" "$data/Purvia/linked-task"
  lib fm_task_data_dir "$data" stolen-task >/dev/null 2>&1 && fail "a symlinked project folder was followed"
  lib fm_task_data_dir "$data" linked-task >/dev/null 2>&1 && fail "a symlinked task folder was followed"
  pass "lookup never follows a symlinked project or task folder"
}

test_task_dirs_listing() {
  local home data out
  home=$(make_home listing)
  data="$home/data"
  mkdir -p "$data/RepToday/canon-task" "$data/handoff/x" "$data/extensions/pkg" "$data/_unassigned/own-task"
  out=$(lib fm_task_data_task_dirs "$data")
  assert_contains "$out" "$data/RepToday/canon-task" "a canonical task folder was not listed"
  assert_contains "$out" "$data/_unassigned/own-task" "a reserved-folder task was not listed"
  assert_contains "$out" "$data/rt-alpha" "a legacy marker folder was not listed"
  assert_not_contains "$out" "$data/lone-dir" "a marker-less flat folder was listed as a task"
  assert_not_contains "$out" "$data/handoff" "the handoff root folder was listed as a task"
  assert_not_contains "$out" "$data/extensions" "the extensions root folder was listed as a task"
  pass "the task listing covers canonical and legacy folders and skips root folders"
}

test_brief_places_each_kind_in_its_folder() {
  local home
  home="$TMP_ROOT/brief-kinds/fmhome"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- RepToday [no-mistakes] - coaching app (added 2026-09-24)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-one reptoday --mode no-mistakes >/dev/null || fail "ship scaffold failed"
  assert_present "$home/data/RepToday/ship-one/brief.md" "a ship brief did not land in its registry-spelled project folder"
  assert_grep "$home/data/RepToday/ship-one/nm-<run>-findings.txt" "$home/data/RepToday/ship-one/brief.md" \
    "the ask-user snapshot path is not inside the project folder"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" own-one firstmate --scout >/dev/null || fail "own scaffold failed"
  assert_present "$home/data/firstmate/own-one/brief.md" "a firstmate-repo brief did not land in its own project folder"
  assert_grep "$home/data/firstmate/own-one/report.md" "$home/data/firstmate/own-one/brief.md" \
    "the scout report path is not inside the task folder"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" mate-x --secondmate --no-projects >/dev/null \
    || fail "charter scaffold failed"
  assert_present "$home/data/_secondmates/mate-x/brief.md" "a charter did not land in _secondmates"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-one reptoday --mode no-mistakes >/dev/null 2>&1 \
    && fail "a second scaffold for the same id overwrote the first"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-one Other --mode no-mistakes >/dev/null 2>&1 \
    && fail "the same id under another project created a second folder"
  [ ! -e "$home/data/Other" ] || fail "a refused scaffold left a project folder behind"
  for flat in ship-one own-one mate-x; do
    [ ! -e "$home/data/$flat" ] || fail "a flat folder was created for $flat"
  done
  pass "briefs land in project and _secondmates folders, never flat, and never twice"
}

test_placement_never_mixes_task_and_project_folders() {
  local home data out rc
  # A flat task folder holding a project's folder name is not that project's folder.
  home=$(make_home flat-holds-project-name)
  data="$home/data"
  mkdir -p "$data/RepToday"
  printf '# charter\n' > "$data/RepToday/brief.md"
  rc=0; lib fm_task_data_dir_for_new "$data" t1 RepToday >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || fail "a project folder name held by a flat task folder returned $rc, expected 4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t1 RepToday --scout >/dev/null 2>&1 \
    && fail "a brief was nested inside a flat task folder"
  [ ! -e "$data/RepToday/t1" ] || fail "a refused brief left a folder inside the flat task folder"
  [ "$(lib fm_task_data_dir "$data" RepToday)" = "$data/RepToday" ] || fail "the flat task folder stopped resolving"

  # The same name in another case: whatever the disk, a new brief is either
  # refused or placed where lookup finds it.
  home=$(make_home flat-holds-project-name-case)
  data="$home/data"
  mkdir -p "$data/reptoday"
  printf '# charter\n' > "$data/reptoday/brief.md"
  if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t1 RepToday --scout >/dev/null 2>&1; then
    out=$(lib fm_task_data_dir "$data" t1) || fail "a new brief was placed where lookup cannot find it"
    [ -f "$out/brief.md" ] || fail "lookup found a folder without the new brief: $out"
  fi

  # A legacy charter named like a registered project still resolves, and
  # placing that id again finds it instead of refusing.
  [ "$(lib fm_task_data_dir "$data" reptoday)" = "$data/reptoday" ] || fail "a legacy charter named like a project stopped resolving"
  [ "$(lib fm_task_data_dir_for_new "$data" reptoday _secondmates)" = "$data/reptoday" ] \
    || fail "re-placing a legacy charter named like a project did not find it"

  # A new id equal to an unregistered project folder never becomes that folder.
  home=$(make_home id-equals-project-folder)
  data="$home/data"
  mkdir -p "$data/Unreg/t1"
  printf 'b\n' > "$data/Unreg/t1/brief.md"
  rc=0; lib fm_task_data_dir_for_new "$data" Unreg Other >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || fail "an id equal to an unregistered project folder returned $rc, expected 4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" Unreg Other --scout >/dev/null 2>&1 \
    && fail "a brief was written into a project folder"
  [ ! -e "$data/Unreg/brief.md" ] || fail "a project folder was given a task marker"
  [ "$(lib fm_task_data_dir "$data" t1)" = "$data/Unreg/t1" ] || fail "a task inside the project folder stopped resolving"
  pass "a top-level data folder is a task folder or a project folder, never both"
}

# --- migration --------------------------------------------------------------

run_migrate() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$MIGRATE" "$@" 2>&1
}

test_migrate_reads_the_repo_from_a_real_brief() {
  local home out
  home="$TMP_ROOT/real-brief/fmhome"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- RepToday [no-mistakes] - coaching app (added 2026-09-24)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" real-ship reptoday --mode no-mistakes >/dev/null || fail "ship scaffold failed"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" real-scout reptoday --scout >/dev/null || fail "scout scaffold failed"
  # Put both back where the pre-layout scripts would have written them.
  mv "$home/data/RepToday/real-ship" "$home/data/real-ship"
  mv "$home/data/RepToday/real-scout" "$home/data/real-scout"
  rmdir "$home/data/RepToday"
  out=$(run_migrate "$home" --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "move: real-ship -> RepToday/real-ship (brief)" "the migration could not read the repo from a real ship brief"
  assert_contains "$out" "move: real-scout -> RepToday/real-scout (brief)" "the migration could not read the repo from a real scout brief"
  pass "the migration reads the project from the briefs fm-brief.sh really writes"
}

test_migrate_dry_run_reports_and_changes_nothing() {
  local home before out rc=0
  home=$(make_home dry-run)
  before=$(tree_sig "$home")
  out=$(run_migrate "$home" --dry-run "${ASSIGN_ARGS[@]}") || rc=$?
  [ "$rc" = 0 ] || fail "dry run exited $rc: $out"
  [ "$(tree_sig "$home")" = "$before" ] || fail "a dry run changed the home"
  assert_contains "$out" "mode: dry-run" "the mode was not reported"
  assert_contains "$out" "move: rt-alpha -> RepToday/rt-alpha (brief)" "rt-alpha placement missing"
  assert_contains "$out" "move: rt-alpha-two -> RepToday/rt-alpha-two (brief)" "rt-alpha-two placement missing"
  assert_contains "$out" "move: im-scout -> Immerse/im-scout (brief)" "im-scout placement missing"
  assert_contains "$out" "move: fmhome-own -> fmhome/fmhome-own (brief)" "the unregistered firstmate-repo placement missing"
  assert_contains "$out" "move: backlog-only -> Purvia/backlog-only (backlog repo)" "the backlog-repo placement missing"
  assert_contains "$out" "move: mate-one -> _secondmates/mate-one (secondmate registry)" "the charter placement missing"
  assert_contains "$out" "move: mystery -> Purvia/mystery (assigned)" "the assigned placement missing"
  assert_contains "$out" "move: lone-dir -> RepToday/lone-dir (assigned)" "the marker-less assigned placement missing"
  assert_contains "$out" "rewrite: backlog.md" "the backlog rewrite was not reported"
  assert_contains "$out" "rewrite: done-archive.md" "the archive rewrite was not reported"
  assert_contains "$out" "note: captain.md holds 1 legacy" "a link in an untouched fleet file was not reported"
  assert_contains "$out" "summary: dry-run move=8" "the dry-run summary does not count every move"
  assert_contains "$out" "unresolved=0 legacy_remaining=0" "the dry-run summary misstates what remains"
  pass "a dry run reports every move and rewrite and changes nothing"
}

test_migrate_reports_what_it_cannot_place() {
  local home out
  home=$(make_home unplaced)
  out=$(run_migrate "$home" --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "unresolved: data/mystery has no recorded project" "an unplaceable folder was not reported"
  assert_contains "$out" "--assign mystery=<Project>" "the unresolved report did not say how to place it"
  assert_contains "$out" "skip: data/lone-dir has no task marker" "a marker-less folder was not reported"
  assert_contains "$out" "summary: dry-run move=6" "the placeable moves were miscounted"
  assert_contains "$out" "unresolved=1 legacy_remaining=2" "the dry-run summary misstates what remains"
  pass "folders the command cannot place are reported with the way to place them"
}

test_migrate_apply_moves_folders_and_rewrites_links() {
  local home out captain_before
  home=$(make_home apply)
  captain_before=$(cksum < "$home/data/captain.md")
  out=$(run_migrate "$home" --apply "${ASSIGN_ARGS[@]}") || fail "apply failed: $out"
  assert_contains "$out" "summary: apply move=8" "the apply summary does not count every move"

  assert_present "$home/data/RepToday/rt-alpha/brief.md" "rt-alpha did not move"
  assert_present "$home/data/RepToday/rt-alpha-two/brief.md" "rt-alpha-two did not move"
  assert_present "$home/data/Immerse/im-scout/report.md" "the scout report did not move with its folder"
  assert_present "$home/data/fmhome/fmhome-own/brief.md" "the firstmate-repo task did not move"
  assert_present "$home/data/Purvia/backlog-only/brief.md" "the backlog-placed task did not move"
  assert_present "$home/data/_secondmates/mate-one/brief.md" "the charter did not move"
  assert_present "$home/data/Purvia/mystery/brief.md" "the assigned task did not move"
  assert_present "$home/data/RepToday/lone-dir/list.csv" "the marker-less assigned folder did not move"
  for flat in rt-alpha rt-alpha-two im-scout fmhome-own backlog-only mate-one mystery lone-dir; do
    [ ! -e "$home/data/$flat" ] || fail "flat folder $flat survived the migration"
  done

  cat > "$TMP_ROOT/apply/expected-backlog.md" <<'EOF'
# Backlog

## Done

- [x] rt-alpha - Alpha task data/RepToday/rt-alpha/report.md (repo: RepToday) (kind: scout)
  Evidence in /Users/x/firstmate/data/RepToday/rt-alpha-two/out.txt and in data/RepToday/rt-alpha.
  See "data/RepToday/rt-alpha/report.md", (data/RepToday/rt-alpha-two/report.md), then data/RepToday/rt-alpha/ and data/RepToday/rt-alpha.
  Not links: data/rt-alphabet/x and mydata/rt-alpha/x and data/RepToday/rt-alpha/report.md
- [x] backlog-only - Purvia work (repo: Purvia) (kind: scout)
  Deliverable: report data/Purvia/backlog-only/report.md
EOF
  cmp -s "$home/data/backlog.md" "$TMP_ROOT/apply/expected-backlog.md" \
    || fail "the backlog was not rewritten exactly: $(diff "$TMP_ROOT/apply/expected-backlog.md" "$home/data/backlog.md")"
  cmp -s "$home/data/done-archive.md" "$TMP_ROOT/apply/expected-backlog.md" \
    || fail "the archive was not rewritten exactly"
  [ "$(cksum < "$home/data/captain.md")" = "$captain_before" ] || fail "a fleet-wide root file was edited"
  assert_present "$home/data/projects.md" "a fleet-wide root file went missing"
  assert_present "$home/data/secondmates.md" "a fleet-wide root file went missing"
  pass "apply moves every folder, rewrites backlog and archive links exactly, and leaves fleet files alone"
}

test_migrate_is_idempotent() {
  local home out after_first
  home=$(make_home idempotent)
  run_migrate "$home" --apply "${ASSIGN_ARGS[@]}" >/dev/null || fail "first apply failed"
  after_first=$(tree_sig "$home")
  out=$(run_migrate "$home" --apply) || fail "second apply failed: $out"
  assert_contains "$out" "summary: apply move=0 rewrite_files=0 rewrite_refs=0 unresolved=0 legacy_remaining=0" \
    "a repeat run did not report nothing to do"
  [ "$(tree_sig "$home")" = "$after_first" ] || fail "a repeat run changed the home"
  out=$(run_migrate "$home" --dry-run) || fail "repeat dry run failed: $out"
  assert_not_contains "$out" "move:" "a migrated home still plans moves"
  pass "re-running the migration changes nothing"
}

test_migrate_finishes_an_interrupted_rewrite() {
  local home out
  home=$(make_home interrupted)
  cp "$home/data/backlog.md" "$TMP_ROOT/interrupted/backlog.original"
  run_migrate "$home" --apply "${ASSIGN_ARGS[@]}" >/dev/null || fail "apply failed"
  # The folders moved but the rewrite never landed.
  cp "$TMP_ROOT/interrupted/backlog.original" "$home/data/backlog.md"
  out=$(run_migrate "$home" --apply) || fail "repeat apply failed: $out"
  assert_contains "$out" "move=0 rewrite_files=1" "the repeat run did not finish the rewrite"
  assert_grep "data/RepToday/rt-alpha/report.md" "$home/data/backlog.md" "the repeat run left the old link"
  pass "a run interrupted between the moves and the rewrite is finished by repeating it"
}

test_migrate_refuses_while_a_task_is_live() {
  local home before out rc
  home=$(make_home live)
  fm_write_meta "$home/state/some-task.meta" "window=x" "kind=ship" "mode=no-mistakes"
  before=$(tree_sig "$home")
  rc=0; out=$(run_migrate "$home" --apply "${ASSIGN_ARGS[@]}") || rc=$?
  [ "$rc" = 3 ] || fail "apply with a live task exited $rc, expected 3: $out"
  assert_contains "$out" "blocked: task some-task is live" "the live task was not named"
  assert_contains "$out" "summary: refused" "the refusal was not summarized"
  [ "$(tree_sig "$home")" = "$before" ] || fail "a refused run changed the home"
  rc=0; out=$(run_migrate "$home" --dry-run "${ASSIGN_ARGS[@]}") || rc=$?
  [ "$rc" = 3 ] || fail "dry run with a live task exited $rc, expected 3"
  assert_contains "$out" "move: rt-alpha" "a blocked dry run did not still show the plan"
  pass "a live task refuses the migration, dry run included, and nothing moves"
}

test_migrate_refuses_while_sources_are_registered() {
  local home before out rc
  home=$(make_home sources)
  mkdir -p "$home/state/procevent"
  printf 'record\n' > "$home/state/procevent/source-1"
  before=$(tree_sig "$home")
  rc=0; out=$(run_migrate "$home" --apply "${ASSIGN_ARGS[@]}") || rc=$?
  [ "$rc" = 3 ] || fail "apply with a registered source exited $rc, expected 3: $out"
  assert_contains "$out" "registered sources remain in procevent" "the registered source was not named"
  [ "$(tree_sig "$home")" = "$before" ] || fail "a refused run changed the home"
  pass "registered process-event sources refuse the migration"
}

test_migrate_allows_a_registered_secondmate() {
  local home out
  home=$(make_home secondmate)
  fm_write_meta "$home/state/mate-one.meta" "window=x" "kind=secondmate" "mode=secondmate"
  out=$(run_migrate "$home" --apply "${ASSIGN_ARGS[@]}") || fail "a registered secondmate blocked the migration: $out"
  assert_present "$home/data/_secondmates/mate-one/brief.md" "the charter did not move"
  pass "a persistent secondmate does not block the migration"
}

test_migrate_refuses_a_conflict_before_moving_anything() {
  local home before out rc
  home=$(make_home conflict)
  mkdir -p "$home/data/RepToday/rt-alpha"
  before=$(tree_sig "$home")
  rc=0; out=$(run_migrate "$home" --apply "${ASSIGN_ARGS[@]}") || rc=$?
  [ "$rc" = 4 ] || fail "a conflicting target exited $rc, expected 4: $out"
  assert_contains "$out" "conflict:" "the conflict was not reported"
  [ "$(tree_sig "$home")" = "$before" ] || fail "a conflicted run moved something anyway"
  pass "an existing target refuses the whole migration before any move"
}

test_migrate_moves_a_flat_task_folder_named_like_a_project() {
  local home out
  home="$TMP_ROOT/flat-named-like-project/fmhome"
  mkdir -p "$home/data/immerse" "$home/state"
  printf '%s\n' '- Immerse [direct-PR] - camera app (added 2026-09-29)' > "$home/data/projects.md"
  printf '%s\n' '- immerse - a mate (home: /tmp/immerse-home; scope: sample scope; projects: Immerse; added 2026-09-30)' \
    > "$home/data/secondmates.md"
  printf '# charter\n' > "$home/data/immerse/brief.md"
  out=$(run_migrate "$home" --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "move: immerse -> _secondmates/immerse (secondmate registry)" \
    "a flat charter named like a project was not planned as a task"
  assert_contains "$out" "legacy_remaining=0" "the dry-run summary misstates what remains"
  out=$(run_migrate "$home" --apply) || fail "apply failed: $out"
  assert_present "$home/data/_secondmates/immerse/brief.md" "the flat charter named like a project did not move"
  pass "a flat task folder named like a project is migrated as a task, not kept as a project folder"
}

test_migrate_assign_and_unresolved() {
  local home out
  home=$(make_home assign)
  out=$(run_migrate "$home" --apply) || fail "apply without assignments failed: $out"
  assert_present "$home/data/mystery/brief.md" "an unplaceable folder was moved without an assignment"
  assert_present "$home/data/lone-dir/list.csv" "a marker-less folder was moved without an assignment"
  [ "$(lib fm_task_data_dir "$home/data" mystery)" = "$home/data/mystery" ] \
    || fail "an unplaced folder became unreachable"
  out=$(run_migrate "$home" --apply --assign mystery=Purvia) || fail "later assignment failed: $out"
  assert_present "$home/data/Purvia/mystery/brief.md" "a later assignment did not place the folder"
  run_migrate "$home" --apply --assign 'bad id=x' >/dev/null && fail "a malformed assignment was accepted"
  pass "unplaceable folders stay readable until assigned, and assignment places them"
}

test_migrate_revert_restores_the_original_layout() {
  local home before out
  home=$(make_home revert)
  # A link already written in the new form is not something the forward run
  # produced, so revert legitimately flattens it; keep it out of the byte check.
  for f in backlog.md done-archive.md; do
    grep -v 'Not links:' "$home/data/$f" > "$home/data/$f.tmp" && mv "$home/data/$f.tmp" "$home/data/$f"
  done
  before=$(tree_sig "$home")
  run_migrate "$home" --apply "${ASSIGN_ARGS[@]}" >/dev/null || fail "apply failed"
  assert_present "$home/data/.layout-migration.tsv" "the migration recorded nothing to revert from"
  out=$(run_migrate "$home" --dry-run --revert) || fail "revert dry run failed: $out"
  assert_contains "$out" "revert: rt-alpha" "the revert plan does not name the folders it will move back"
  out=$(run_migrate "$home" --apply --revert) || fail "revert failed: $out"
  [ "$(tree_sig "$home")" = "$before" ] || fail "revert did not restore the home byte for byte"
  assert_absent "$home/data/.layout-migration.tsv" "the revert left its manifest behind"
  pass "revert restores the flat layout and every recorded link exactly"
}

test_project_dirname_mapping
test_project_dirname_adopts_an_existing_folder_spelling
test_for_new_places_in_the_project_folder
test_lookup_canonical_legacy_and_ambiguity
test_lookup_ignores_symlinked_folders
test_task_dirs_listing
test_brief_places_each_kind_in_its_folder
test_placement_never_mixes_task_and_project_folders
test_migrate_reads_the_repo_from_a_real_brief
test_migrate_dry_run_reports_and_changes_nothing
test_migrate_reports_what_it_cannot_place
test_migrate_apply_moves_folders_and_rewrites_links
test_migrate_is_idempotent
test_migrate_finishes_an_interrupted_rewrite
test_migrate_refuses_while_a_task_is_live
test_migrate_refuses_while_sources_are_registered
test_migrate_allows_a_registered_secondmate
test_migrate_refuses_a_conflict_before_moving_anything
test_migrate_moves_a_flat_task_folder_named_like_a_project
test_migrate_assign_and_unresolved
test_migrate_revert_restores_the_original_layout

printf '# all fm-task-data tests passed\n'
