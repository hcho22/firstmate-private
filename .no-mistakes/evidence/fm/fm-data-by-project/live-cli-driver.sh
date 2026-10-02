#!/usr/bin/env bash
# Live CLI drive of the per-project task data layout against scratch homes.
# Candidate scripts come from the worktree; the "legacy" home is produced by the
# base commit's own fm-brief.sh so the migration sees what a real home holds.
set -u
CAND=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M3WJKS4N49ZJQAJY53AH5Z2M
S=$(cd "$(dirname "$0")" && pwd)
BASE=$S/base

run() {  # print the command, run it, print its exit code
  printf '\n$ %s\n' "$*"
  "$@" 2>&1
  local rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}
tree_of() {  # <data> : every file and dir, plus a content hash
  (cd "$1" && find . \( -type f -o -type d \) | LC_ALL=C sort | while IFS= read -r p; do
    if [ -f "$p" ]; then printf '%s  %s\n' "$(shasum -a 256 "$p" | cut -c1-12)" "$p"; else printf '%-12s  %s/\n' dir "$p"; fi
  done)
}
digest() { tree_of "$1" | shasum -a 256 | cut -c1-16; }
section() { printf '\n==================== %s ====================\n' "$*"; }
check() {  # <description> <command...>
  local d=$1; shift
  if "$@"; then echo "CHECK PASS: $d"; else echo "CHECK FAIL: $d"; fi
}

new_home() {  # <dir>
  mkdir -p "$1/data" "$1/state"
  cat > "$1/data/projects.md" <<'EOF'
- RepToday [no-mistakes-prod-only] - Discipline-first iOS micro-workout app for busy adults (added 2026-09-24)
- firstmate [no-mistakes] - the firstmate orchestrator itself (added 2026-09-01)
EOF
}

###########################################################################
section "A. New tasks land in data/<Project>/<task-id>/ (candidate fm-brief.sh)"
H=$S/home-new
new_home "$H"
for f in backlog.md captain.md captain-shared.md learnings.md secondmates.md; do printf '# %s\n' "$f" > "$H/data/$f"; done
FLEET_BEFORE=$(cd "$H/data" && shasum -a 256 *.md)
export FM_HOME=$H
run "$CAND/bin/fm-brief.sh" rt-new-ship reptoday --mode no-mistakes
run "$CAND/bin/fm-brief.sh" rt-new-scout RepToday --scout
run "$CAND/bin/fm-brief.sh" fm-self-fix firstmate --mode local-only
run "$CAND/bin/fm-brief.sh" unregistered-task SomeNewRepo --scout
FM_SECONDMATE_CHARTER='Own RepToday delivery' run "$CAND/bin/fm-brief.sh" sm-reptoday --secondmate RepToday
section "A-adversarial. names that must not land flat or collide"
run "$CAND/bin/fm-brief.sh" weird-proj 'bad name!' --scout
run "$CAND/bin/fm-brief.sh" _sneaky RepToday --scout
run "$CAND/bin/fm-brief.sh" RepToday RepToday --scout
run "$CAND/bin/fm-brief.sh" rt-new-scout firstmate --scout
unset FM_HOME
echo
echo "--- resulting data/ tree"
tree_of "$H/data"
echo "--- scout report pointer inside the scaffolded scout brief"
grep -n 'report.md' "$H/data/RepToday/rt-new-scout/brief.md" | sed "s#$S#<scratch>#g"
check "registry spelling RepToday used for lowercase repo arg" test -f "$H/data/RepToday/rt-new-ship/brief.md"
check "scout brief in project folder" test -f "$H/data/RepToday/rt-new-scout/brief.md"
check "scout brief points its report at the project folder" grep -q "data/RepToday/rt-new-scout/report.md" "$H/data/RepToday/rt-new-scout/brief.md"
check "firstmate repo is an ordinary project folder" test -f "$H/data/firstmate/fm-self-fix/brief.md"
check "unregistered repo gets its repo-name folder" test -f "$H/data/SomeNewRepo/unregistered-task/brief.md"
check "secondmate charter in _secondmates" test -f "$H/data/_secondmates/sm-reptoday/brief.md"
check "unfolderable project name filed under _unassigned" test -f "$H/data/_unassigned/weird-proj/brief.md"
check "reserved underscore id refused (no folder anywhere)" bash -c "! ls -d '$H'/data/*/_sneaky '$H'/data/_sneaky 2>/dev/null | grep -q ."
check "task id equal to project name sits inside the project folder" test -f "$H/data/RepToday/RepToday/brief.md"
check "same id under another project refused, not duplicated" test ! -e "$H/data/firstmate/rt-new-scout"
check "no flat task folder was created" bash -c "for d in '$H'/data/*/; do n=\$(basename \"\$d\"); [ -f \"\$d/brief.md\" ] && exit 1; done; exit 0"
FLEET_AFTER=$(cd "$H/data" && shasum -a 256 *.md)
check "fleet-wide root files unchanged by new briefs" test "$FLEET_BEFORE" = "$FLEET_AFTER"

###########################################################################
section "B. Legacy flat home (built by the BASE fm-brief.sh), then migrated by the candidate"
L=$S/home-legacy
new_home "$L"
export FM_HOME=$L
"$BASE/bin/fm-brief.sh" rt-premium-fix RepToday --mode no-mistakes >/dev/null 2>&1 || echo "base brief rt-premium-fix failed"
"$BASE/bin/fm-brief.sh" rt-xcode-check RepToday --scout >/dev/null 2>&1 || echo "base brief rt-xcode-check failed"
"$BASE/bin/fm-brief.sh" fm-data-by-project firstmate --mode no-mistakes >/dev/null 2>&1 || echo "base brief fm-data-by-project failed"
FM_SECONDMATE_CHARTER='Own RepToday' "$BASE/bin/fm-brief.sh" sm-alpha --secondmate RepToday >/dev/null 2>&1 || echo "base charter sm-alpha failed"
unset FM_HOME
printf 'findings\n' > "$L/data/rt-xcode-check/report.md"
# The two real-home shapes the captain asked to file under RepToday:
mkdir -p "$L/data/reptoday-artist-checklist" "$L/data/reptoday-coach-config-repair"
printf 'exercise,art\npushup,done\n' > "$L/data/reptoday-artist-checklist/reptoday-exercise-art-checklist.csv"
printf '# config repair report\n' > "$L/data/reptoday-coach-config-repair/report.md"
printf '{"plan":1}\n' > "$L/data/reptoday-coach-config-repair/repair-plan.json"
# A flat folder only the backlog annotation can place:
mkdir -p "$L/data/rt-legacy-annotated" && printf 'notes\n' > "$L/data/rt-legacy-annotated/report.md"
# Fleet-wide root files and non-task root folders:
cat > "$L/data/backlog.md" <<'EOF'
# Backlog
## In flight
## Done
- [x] rt-xcode-check Xcode version check (repo: RepToday) - report: data/rt-xcode-check/report.md
- [x] rt-legacy-annotated old notes (repo: RepToday) - see data/rt-legacy-annotated/report.md.
- [x] reptoday-coach-config-repair coach config - report data/reptoday-coach-config-repair/report.md
- note: links to data/backlog.md and data/projects.md are fleet files, never task links
EOF
printf -- '- [x] fm-data-by-project (repo: firstmate) brief: data/fm-data-by-project/brief.md\n' > "$L/data/done-archive.md"
printf -- '- artist checklist at `data/reptoday-artist-checklist/reptoday-exercise-art-checklist.csv`\n' > "$L/data/note-archive.md"
printf '# Captain\nsee data/rt-premium-fix/brief.md\n' > "$L/data/captain.md"
printf '# Captain shared\n' > "$L/data/captain-shared.md"
printf '# Learnings\n' > "$L/data/learnings.md"
printf -- '- sm-alpha - RepToday mate (home: %s/sm-alpha-home; scope: RepToday delivery; projects: RepToday; added 2026-09-30)\n' "$S" > "$L/data/secondmates.md"
mkdir -p "$L/data/handoff" "$L/data/extensions/packages" "$L/data/remote-secondmates"
printf 'h\n' > "$L/data/handoff/note.md"
echo "--- legacy data/ tree (T0)"
tree_of "$L/data"
T0=$(digest "$L/data")
cp -R "$L/data" "$S/legacy-data-T0"
echo "T0 digest: $T0"

section "B1. lookup before migration: candidate fleet view finds legacy flat reports (bounded legacy read)"
(cd "$S" && FM_HOME=$L FM_STATE_OVERRIDE=$L/state FM_SNAPSHOT_NOW=2026-10-01T00:00:00Z "$CAND/bin/fm-fleet-snapshot.sh" 2>&1 | jq -c '.scout_reports' 2>&1 | sed "s#$S#<scratch>#g")

section "B2. migration refuses while a task is live (dry run and apply)"
printf 'kind=ship\n' > "$L/state/rt-premium-fix.meta"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --apply
check "live task refusal moved nothing" test "$(digest "$L/data")" = "$T0"
rm -f "$L/state/rt-premium-fix.meta"

section "B3. dry run (default) reports every move and changes nothing"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh"
check "dry run left data/ byte-identical" test "$(digest "$L/data")" = "$T0"

section "B4. apply without assignments: the two RepToday folders are reported, left flat, still readable"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --apply
echo "--- data/ tree after first apply"
tree_of "$L/data"
echo "--- legacy-read lookup still finds the unplaced report folder"
(cd "$S" && FM_HOME=$L FM_STATE_OVERRIDE=$L/state FM_SNAPSHOT_NOW=2026-10-01T00:00:00Z "$CAND/bin/fm-fleet-snapshot.sh" 2>&1 | jq -c '.scout_reports' 2>&1 | sed "s#$S#<scratch>#g")

section "B5. apply with the captain's assignments files both folders under RepToday"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --apply --assign reptoday-artist-checklist=RepToday --assign reptoday-coach-config-repair=reptoday
echo "--- data/ tree after assigned apply (T1)"
tree_of "$L/data"
echo "--- backlog and archives after rewrite"
cat "$L/data/backlog.md" "$L/data/done-archive.md" "$L/data/note-archive.md"
T1=$(digest "$L/data")
cp -R "$L/data" "$S/legacy-data-T1"
check "both captain-named folders under data/RepToday" bash -c "test -f '$L/data/RepToday/reptoday-artist-checklist/reptoday-exercise-art-checklist.csv' && test -f '$L/data/RepToday/reptoday-coach-config-repair/repair-plan.json'"
check "secondmate charter moved to _secondmates" test -f "$L/data/_secondmates/sm-alpha/brief.md"
check "firstmate task moved to data/firstmate" test -f "$L/data/firstmate/fm-data-by-project/brief.md"
for f in projects.md secondmates.md captain.md captain-shared.md learnings.md handoff/note.md; do
  check "fleet-wide $f unchanged at data/ root" cmp -s "$S/legacy-data-T0/$f" "$L/data/$f"
done
check "fleet-file links (data/backlog.md, data/projects.md) not rewritten" grep -q 'links to data/backlog.md and data/projects.md' "$L/data/backlog.md"
check "no flat task folder remains" bash -c "for d in '$L'/data/*/; do for m in brief.md report.md launch-brief.md ship-instructions.md; do [ -f \"\$d\$m\" ] && exit 1; done; done; exit 0"
echo "--- lookup after migration: fleet view finds reports in project folders"
(cd "$S" && FM_HOME=$L FM_STATE_OVERRIDE=$L/state FM_SNAPSHOT_NOW=2026-10-01T00:00:00Z "$CAND/bin/fm-fleet-snapshot.sh" 2>&1 | jq -c '.scout_reports' 2>&1 | sed "s#$S#<scratch>#g")

section "B6. re-running is idempotent"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --apply --assign reptoday-artist-checklist=RepToday --assign reptoday-coach-config-repair=reptoday
check "rerun changed nothing" test "$(digest "$L/data")" = "$T1"

section "B7. revert restores the flat layout and every recorded link exactly"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --revert
check "revert dry run changed nothing" test "$(digest "$L/data")" = "$T1"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --revert --apply
echo "--- diff of data/ against T0 (empty means byte-identical)"
diff -r "$S/legacy-data-T0" "$L/data" && echo "(no differences)"
check "revert restored T0 byte-for-byte" test "$(digest "$L/data")" = "$T0"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --revert --apply
check "repeated revert changed nothing" test "$(digest "$L/data")" = "$T0"

section "B8. migrate forward again, then a new brief joins the migrated project folder"
FM_HOME=$L run "$CAND/bin/fm-data-migrate.sh" --apply --assign reptoday-artist-checklist=RepToday --assign reptoday-coach-config-repair=RepToday
echo "--- diff of data/ against T1 (single-pass forward vs two-pass forward)"
diff -r "$S/legacy-data-T1" "$L/data" && echo "(no differences)"
check "forward again reaches the same folders and bytes (manifest compared as a set)" bash -c "diff -r -x .layout-migration.tsv '$S/legacy-data-T1' '$L/data' >/dev/null && diff <(sort '$S/legacy-data-T1/.layout-migration.tsv') <(sort '$L/data/.layout-migration.tsv') >/dev/null"
FM_HOME=$L run "$CAND/bin/fm-brief.sh" rt-after-migration RepToday --scout
check "post-migration brief joined data/RepToday" test -f "$L/data/RepToday/rt-after-migration/brief.md"
ls -1 "$L/data/RepToday"

###########################################################################
section "C. cycle refusal: moves that wait on each other are refused, named, nothing moves"
C=$S/home-cycle
mkdir -p "$C/data/alpha" "$C/data/beta" "$C/state"
printf 'a\n' > "$C/data/alpha/report.md"
printf 'b\n' > "$C/data/beta/report.md"
printf -- '- [x] alpha (repo: beta) data/alpha/report.md\n- [x] beta (repo: alpha) data/beta/report.md\n' > "$C/data/backlog.md"
echo "--- before"; tree_of "$C/data"
TC=$(digest "$C/data")
FM_HOME=$C run "$CAND/bin/fm-data-migrate.sh" --apply
check "cycle refused with nothing moved or rewritten" test "$(digest "$C/data")" = "$TC"

section "C2. a task named like its own project moves into and back out of that folder"
X=$S/home-selfnamed
mkdir -p "$X/data/RepToday" "$X/state"
printf -- '- RepToday [no-mistakes] - x\n' > "$X/data/projects.md"
printf 'r\n' > "$X/data/RepToday/report.md"
printf -- '- [x] RepToday (repo: RepToday) data/RepToday/report.md\n' > "$X/data/backlog.md"
TX=$(digest "$X/data")
FM_HOME=$X run "$CAND/bin/fm-data-migrate.sh" --apply
tree_of "$X/data"
check "self-named task now at data/RepToday/RepToday" test -f "$X/data/RepToday/RepToday/report.md"
FM_HOME=$X run "$CAND/bin/fm-data-migrate.sh" --revert --apply
check "self-named revert restored exactly" test "$(digest "$X/data")" = "$TX"
