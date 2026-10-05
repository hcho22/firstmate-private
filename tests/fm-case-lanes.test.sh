#!/usr/bin/env bash
# Behavior tests for tests/case-lanes-helpers.sh, the shared runner that lets a
# test file run its independent cases in concurrent lanes.
#
# Each case writes a small test file that sources the helper and hands it a set
# of cases, runs that file as the runner would, and asserts on what a reader of
# the file's output and exit status sees: every case's output in the order
# given, a failing case failing the file, a stopped file reporting what it got
# through, and the file's own cleanup still running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-case-lanes)
HELPER="$ROOT/tests/case-lanes-helpers.sh"

# write_suite <dir> <body>: a test file in <dir> that sources the helper the way
# an adopting file does, then runs <body>.
write_suite() {
  local dir=$1 body=$2
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf '. %q\n' "$HELPER"
    printf '%s\n' "$body"
  } > "$dir/suite.test.sh"
  chmod +x "$dir/suite.test.sh"
}

# Cases that finish in the reverse of the order they are listed, so output order
# can only come from the helper's ordering and never from completion order.
REVERSE_CASES='
case_a() { sleep 0.6; echo "a-out"; pass "case a"; }
case_b() { sleep 0.3; echo "b-err" >&2; pass "case b"; }
case_c() { pass "case c"; }
'

test_cases_print_in_the_order_given() {
  local dir="$TMP_ROOT/order" out rc=0
  write_suite "$dir" "$REVERSE_CASES
fm_test_run_cases case_a case_b case_c"
  out=$(FM_TEST_CASE_LANES=3 "$dir/suite.test.sh" 2> "$dir/err") || rc=$?
  expect_code 0 "$rc" "a passing laned file must exit 0: $out $(cat "$dir/err")"
  [ "$out" = "$(printf 'a-out\nok - case a\nok - case b\nok - case c')" ] \
    || fail "laned output was not in the order given: $out"
  [ "$(cat "$dir/err")" = b-err ] || fail "a laned case's stderr did not reach stderr: $(cat "$dir/err")"
  pass "laned cases print their output in the order given, not the order they finish"
}

test_cases_run_concurrently() {
  local dir="$TMP_ROOT/concurrent" rc=0 started finished
  # Each case waits for every other case to have started, so the file can only
  # finish when the cases really run at the same time.
  write_suite "$dir" "
meet() { : > \"$dir/started.\$1\"; local i=0; while [ \"\$(ls \"$dir\" | grep -c '^started\\.')\" -lt 3 ]; do i=\$((i + 1)); [ \"\$i\" -lt 600 ] || fail \"case \$1 never met the others\"; sleep 0.1; done; pass \"case \$1\"; }
case_a() { meet a; }
case_b() { meet b; }
case_c() { meet c; }
fm_test_run_cases case_a case_b case_c"
  started=$SECONDS
  FM_TEST_CASE_LANES=3 "$dir/suite.test.sh" >/dev/null 2>&1 || rc=$?
  finished=$SECONDS
  expect_code 0 "$rc" "three cases that wait for each other did not all run at once"
  [ "$((finished - started))" -lt 60 ] || fail "concurrent cases took $((finished - started))s"
  pass "laned cases run concurrently"
}

test_one_lane_runs_cases_in_this_shell_in_order() {
  local dir="$TMP_ROOT/serial" out rc=0
  # A case that changes this shell's state is visible to the next only when the
  # cases run in the file's own shell, which is what one lane promises.
  write_suite "$dir" "$REVERSE_CASES
case_set() { SHARED=from-set; pass \"set\"; }
case_read() { [ \"\${SHARED:-}\" = from-set ] || fail \"serial case did not run in this shell\"; pass \"read\"; }
fm_test_run_cases case_a case_set case_read case_c"
  out=$(FM_TEST_CASE_LANES=1 "$dir/suite.test.sh" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a passing serial file must exit 0: $out"
  [ "$out" = "$(printf 'a-out\nok - case a\nok - set\nok - read\nok - case c')" ] \
    || fail "serial output was not in the order given: $out"
  pass "one lane runs every case in the file's own shell, in order"
}

test_laned_cases_do_not_share_shell_state() {
  local dir="$TMP_ROOT/isolated" out rc=0
  write_suite "$dir" "
case_set() { export LEAK=yes; pass \"set\"; }
case_read() { sleep 0.5; [ -z \"\${LEAK:-}\" ] || fail \"a laned case saw another case's export\"; pass \"read\"; }
fm_test_run_cases case_set case_read"
  out=$(FM_TEST_CASE_LANES=1 "$dir/suite.test.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the leak probe must see the leak when cases share a shell: $out"
  rc=0
  out=$(FM_TEST_CASE_LANES=2 "$dir/suite.test.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "a laned case saw another case's export: $out"
  pass "each laned case runs in its own subshell, so exports never leak between cases"
}

test_a_failing_case_fails_the_file_and_stops_claims() {
  local dir="$TMP_ROOT/failing" out rc=0
  write_suite "$dir" "
case_fail() { local i=0; while [ ! -e \"$dir/slow-started\" ]; do i=\$((i + 1)); [ \"\$i\" -lt 600 ] || fail \"case_slow never started\"; sleep 0.1; done; fail \"deliberate\"; }
case_slow() { : > \"$dir/slow-started\"; local i=0; while ! grep -qF 'not ok - deliberate' \"$dir/out\"; do i=\$((i + 1)); [ \"\$i\" -lt 600 ] || fail \"the failure was never reported\"; sleep 0.1; done; pass \"slow\"; }
case_late() { : > \"$dir/late-ran\"; pass \"late\"; }
fm_test_run_cases case_fail case_slow case_late"
  FM_TEST_CASE_LANES=2 "$dir/suite.test.sh" > "$dir/out" 2>&1 || rc=$?
  out=$(cat "$dir/out")
  expect_code 1 "$rc" "a failing case must fail the file with its status: $out"
  assert_contains "$out" "not ok - deliberate" "the failing case's report was lost"
  assert_contains "$out" "ok - slow" "a case already running when another failed did not finish"
  [ ! -e "$dir/late-ran" ] || fail "a lane claimed a new case after one had failed"
  pass "a failing case fails the file with its status, running cases finish, and no new case starts"
}

test_bad_lane_count_is_refused() {
  local dir="$TMP_ROOT/bad-count" out rc=0
  write_suite "$dir" "$REVERSE_CASES
fm_test_run_cases case_c"
  out=$(FM_TEST_CASE_LANES=two "$dir/suite.test.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-numeric lane count must be refused: $out"
  assert_contains "$out" "FM_TEST_CASE_LANES must be a positive whole number" \
    "the refusal did not name the bad lane count"
  pass "a lane count that is not a positive whole number is refused"
}

test_the_files_own_exit_trap_still_runs() {
  local dir="$TMP_ROOT/trap" out rc=0
  write_suite "$dir" "
trap 'echo file-cleanup-ran > \"$dir/cleanup\"' EXIT
case_one() { pass \"one\"; }
case_two() { pass \"two\"; }
fm_test_run_cases case_one case_two"
  out=$(FM_TEST_CASE_LANES=2 "$dir/suite.test.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "a passing laned file with its own cleanup must exit 0: $out"
  assert_present "$dir/cleanup" "the file's own EXIT cleanup did not run after laned cases"
  pass "a file's own EXIT cleanup still runs after its laned cases"
}

test_case_teardown_runs_for_each_laned_case() {
  local dir="$TMP_ROOT/teardown" out rc=0
  write_suite "$dir" "
CASE_TOKEN=
reap_case() { [ -z \"\$CASE_TOKEN\" ] || : > \"$dir/reaped.\$CASE_TOKEN\"; }
FM_TEST_CASE_TEARDOWN=reap_case
case_pass() { CASE_TOKEN=pass; pass \"pass\"; }
case_fail() { CASE_TOKEN=fail; sleep 0.5; fail \"deliberate\"; }
fm_test_run_cases case_pass case_fail"
  out=$(FM_TEST_CASE_LANES=2 "$dir/suite.test.sh" 2>&1) || rc=$?
  expect_code 1 "$rc" "the failing case must fail the file: $out"
  assert_present "$dir/reaped.pass" "the case teardown did not run after a passing laned case"
  assert_present "$dir/reaped.fail" "the case teardown did not run after a failing laned case"
  rm -f "$dir"/reaped.*
  rc=0
  out=$(FM_TEST_CASE_LANES=1 "$dir/suite.test.sh" 2>&1) || rc=$?
  expect_code 1 "$rc" "the failing case must fail the serial file: $out"
  assert_present "$dir/reaped.pass" "the case teardown did not run after a passing serial case"
  pass "the file's case teardown runs with each case's own globals, laned or serial"
}

test_case_pid_is_the_shell_running_the_case() {
  local dir="$TMP_ROOT/case-pid" out lanes rc
  # A child the case starts sees FM_TEST_CASE_PID as its parent: the shell that
  # runs the case, whether that is the file's own shell or a laned subshell.
  write_suite "$dir" "
probe() { local parent; parent=\$(sh -c 'echo \$PPID'); [ \"\$parent\" = \"\$FM_TEST_CASE_PID\" ] || fail \"case pid \$FM_TEST_CASE_PID is not the case shell \$parent\"; kill -0 \"\$FM_TEST_CASE_PID\" || fail \"case pid is not live\"; pass \"\$1\"; }
case_one() { probe one; }
case_two() { probe two; }
fm_test_run_cases case_one case_two"
  for lanes in 1 2; do
    rc=0
    out=$(FM_TEST_CASE_LANES=$lanes "$dir/suite.test.sh" 2>&1) || rc=$?
    expect_code 0 "$rc" "FM_TEST_CASE_PID was wrong with $lanes lane(s): $out"
  done
  pass "FM_TEST_CASE_PID names the live shell running each case, serial or laned"
}

test_a_stopped_file_reports_its_progress_and_stops_its_cases() {
  local dir="$TMP_ROOT/stopped" pid out i=0 rc=0
  write_suite "$dir" "
trap 'echo file-cleanup-ran > \"$dir/cleanup\"; exit 143' TERM
case_quick() { pass \"quick\"; : > \"$dir/quick-passed\"; }
case_hang() { local i=0; while [ ! -e \"$dir/quick-passed\" ]; do i=\$((i + 1)); [ \"\$i\" -lt 600 ] || fail \"case_quick never passed\"; sleep 0.1; done; sleep 300 & echo \$! > \"$dir/sleeper.pid\"; wait; }
fm_test_run_cases case_quick case_hang"
  FM_TEST_CASE_LANES=2 "$dir/suite.test.sh" > "$dir/out" 2>&1 &
  pid=$!
  while [ ! -s "$dir/sleeper.pid" ]; do
    i=$((i + 1))
    [ "$i" -lt 600 ] || { kill "$pid" 2>/dev/null; fail "the hanging case never started"; }
    sleep 0.1
  done
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  expect_code 143 "$rc" "a stopped laned file must exit with its own TERM status"
  out=$(cat "$dir/out")
  assert_contains "$out" "ok - quick" "a stopped file did not print the case it finished"
  assert_contains "$out" "not ok - case_hang was still running when the file was stopped" \
    "a stopped file did not name the case it cut off"
  assert_present "$dir/cleanup" "the file's own TERM cleanup did not run"
  ! kill -0 "$(cat "$dir/sleeper.pid")" 2>/dev/null \
    || fail "stopping the file left a laned case's child running"
  pass "a stopped laned file reports what it got through, stops its cases, and runs its own cleanup"
}

test_cases_print_in_the_order_given
test_cases_run_concurrently
test_one_lane_runs_cases_in_this_shell_in_order
test_laned_cases_do_not_share_shell_state
test_a_failing_case_fails_the_file_and_stops_claims
test_bad_lane_count_is_refused
test_the_files_own_exit_trap_still_runs
test_case_teardown_runs_for_each_laned_case
test_case_pid_is_the_shell_running_the_case
test_a_stopped_file_reports_its_progress_and_stops_its_cases
