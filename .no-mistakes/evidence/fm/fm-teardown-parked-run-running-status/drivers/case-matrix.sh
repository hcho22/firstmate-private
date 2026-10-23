#!/usr/bin/env bash
# Runs each parked-run teardown case ALONE from tests/fm-teardown.test.sh
# against three trees built from git objects into a throwaway /tmp root:
#   head        - target commit, code and tests as shipped
#   base-code   - target tests + base commit's bin/fm-teardown.sh and
#                 bin/fm-nm-run-lib.sh (fail-before proof for the new fixture)
#   base-tree   - base commit entirely (shows the old unrealistic fixture
#                 passed against the buggy code)
# Usage: case-matrix.sh <repo-worktree> <base-sha> <head-sha> <out-tsv>
set -u
repo=$1 base=$2 head=$3 out=$4
root=$(mktemp -d "${TMPDIR:-/tmp}/fm-case-matrix.XXXXXX")
trap 'rm -rf "$root"' EXIT

mk_tree() {  # <name> <tree-sha>
  mkdir -p "$root/$1"
  git -C "$repo" archive "$2" | tar -x -C "$root/$1"
}
mk_tree head "$head"
mk_tree base-code "$head"
git -C "$repo" show "$base:bin/fm-teardown.sh" > "$root/base-code/bin/fm-teardown.sh"
git -C "$repo" show "$base:bin/fm-nm-run-lib.sh" > "$root/base-code/bin/fm-nm-run-lib.sh"
chmod +x "$root/base-code/bin/fm-teardown.sh"
mk_tree base-tree "$base"

cases_for() {  # <tree>
  sed -n '/^fm_test_run_cases/,$p' "$root/$1/tests/fm-teardown.test.sh" \
    | grep -oE 'test_[a-z0-9_]+' \
    | grep -E 'parked|autonomous|executing|abort|another_branch'
}

# A single-case copy of the suite: the runner list at the end replaced by one
# case, everything above it (helpers, fixtures, fake CLI) byte-identical.
single_case_file() {  # <tree> <case>
  local f="$root/$1/tests/fm-teardown.test.sh" one="$root/$1/tests/zz-one-$2.test.sh"
  sed -n '/^fm_test_run_cases/q;p' "$f" > "$one"
  printf 'FM_TEST_CASE_LANES=1 fm_test_run_cases %s\n' "$2" >> "$one"
  printf '%s\n' "$one"
}

printf 'tree\tcase\texit\tlast_line\n' > "$out"
for tree in base-tree base-code head; do
  for c in $(cases_for "$tree"); do
    file=$(single_case_file "$tree" "$c")
    log="$root/$tree-$c.log"
    rc=0
    (cd "$root/$tree" && bin/fm-test-run.sh "tests/${file##*/}") > "$log" 2>&1 || rc=$?
    last=$(grep -E '^(ok|not ok|FAIL|PASS|fail:)|FAIL' "$log" | grep -v FM_TEST | tail -1 | tr '\t' ' ')
    printf '%s\t%s\t%s\t%s\n' "$tree" "$c" "$rc" "$last" >> "$out"
    if [ "$rc" != 0 ]; then
      mkdir -p "$(dirname "$out")/case-logs"
      cp "$log" "$(dirname "$out")/case-logs/$tree-$c.log"
    fi
    rm -f "$file"
  done
done
