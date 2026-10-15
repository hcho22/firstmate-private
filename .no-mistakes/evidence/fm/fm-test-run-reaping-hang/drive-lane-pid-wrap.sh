#!/bin/bash
# drive-lane-pid-wrap.sh <checkout-copy> <lanes> <hold-secs>
#
# Reproduces "not ok - a case lane ended abnormally (127)" from
# tests/case-lanes-helpers.sh, as tests/fm-teardown.test.sh hit it in this run's
# configured test command, with the real helper from <checkout-copy> (a dir with
# tests/case-lanes-helpers.sh, tests/lib.sh and bin/fm-server-env-lib.sh).
#
# The suite has <lanes> cases and <lanes> lanes: every case but the last passes
# at once, so all of those lanes end right away and sit dead in the file shell's
# job table; the last case holds its lane for <hold-secs> while the helper polls.
# Once the host's pid counter wraps past the file shell's first child, macOS
# /bin/bash 3.2 drops a dead job whose pid a new child of that shell reuses
# (make_child -> delete_old_job, DEL_NOBGPID), so when the new child is one of
# the poll loop's command substitutions, the dropped lane's later `wait` reports
# "pid N is not a child of this shell". More dead lanes and a longer hold make a
# hit likely within one run.
set -u
copy=$1 lanes=$2 hold=$3
work=$(mktemp -d /tmp/lanewrap.XXXXXX)
{
  printf '#!/bin/bash\nset -u\n'
  printf '. %q\n' "$copy/tests/case-lanes-helpers.sh"
  for ((k = 1; k < lanes; k++)); do printf 'case_%d() { pass "quick %d"; }\n' "$k" "$k"; done
  printf 'case_hold() { sleep %s; pass "hold"; }\n' "$hold"
  printf 'fm_test_run_cases'
  for ((k = 1; k < lanes; k++)); do printf ' case_%d' "$k"; done
  printf ' case_hold\n'
} > "$work/suite.test.sh"
chmod +x "$work/suite.test.sh"
mkdir -p "$work/tmp"
first=$(sh -c 'echo $$')
start=$SECONDS
rc=0
TMPDIR="$work/tmp" FM_TEST_CASE_LANES=$lanes /bin/bash "$work/suite.test.sh" > "$work/out" 2> "$work/err" || rc=$?
last=$(sh -c 'echo $$')
echo "helper=$copy bash=$(/bin/bash -c 'echo $BASH_VERSION') lanes=$lanes hold=${hold}s"
echo "host pid at start=$first at end=$last (pid_max 99999; end < start means the counter wrapped)"
echo "suite exit=$rc after $((SECONDS - start))s; ok lines=$(grep -c '^ok - ' "$work/out")/$lanes"
echo "stderr (not ok and bash errors):"
grep -E 'not ok|not a child' "$work/err" | sed 's/^/  /'
grep -qE 'not ok|not a child' "$work/err" || echo "  (none)"
rm -rf "$work"
