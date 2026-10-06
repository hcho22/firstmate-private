#!/usr/bin/env bash
# Interrupting the remote secondmate lifecycle e2e through bin/fm-test-run.sh
# while its remote job worker is serving leaves no worker alive and no sandbox
# behind, whether the run gets Ctrl-C or is killed outright with its whole
# process group. The worker isolates its own process group, so before the
# runner reaped it, an interrupted run left it polling its fixture for as long
# as that fixture existed, and a killed run left both behind indefinitely.
# tests/fm-test-run.test.sh covers the same guarantee for every way a run can
# end against a minimal fixture; this file proves it against the real e2e.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

E2E=tests/fm-remote-secondmate-lifecycle-e2e.test.sh
FM_TEST_EVENT_HANG_GUARD_SECONDS=${FM_TEST_EVENT_HANG_GUARD_SECONDS:-600}

# serving_worker_under <dir>: a serving remote job worker rooted inside <dir>.
serving_worker_under() {
  local pid
  for pid in $(fm_test_remote_job_workers_under "$1"); do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *' --serve') printf '%s\n' "$pid"; return 0 ;;
    esac
  done
  return 1
}

# The nested runner a case started and has not yet waited for. A case that fails
# or is interrupted while that runner is still going stops it here, so the
# runner's own interrupt path reaps the e2e and its worker instead of leaving the
# e2e to run on. It runs as FM_TEST_CASE_TEARDOWN and from the file's EXIT trap.
E2E_RUNNER=
stop_e2e_runner() {
  [ -n "$E2E_RUNNER" ] || return 0
  kill -TERM -- "-$E2E_RUNNER" 2>/dev/null || true
  wait "$E2E_RUNNER" 2>/dev/null || true
  E2E_RUNNER=
}

# run_e2e_interrupt_case <int|abort>
run_e2e_interrupt_case() {
  local mode=$1 tmp caller runner rc=0 deadline survivors pid
  tmp=$(fm_test_tmproot fm-e2e-interrupt)
  caller="$tmp/caller-tmp"
  mkdir -p "$caller"
  # The runner leads its own process group with INT at its default, as it
  # would in a terminal, so a group signal reaches the run and nothing else.
  (cd "$ROOT" && TMPDIR="$caller" \
    exec perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' \
    bin/fm-test-run.sh --jobs 1 "$E2E") >"$tmp/out" 2>"$tmp/err" &
  runner=$!
  E2E_RUNNER=$runner
  deadline=$((SECONDS + FM_TEST_EVENT_HANG_GUARD_SECONDS))
  until serving_worker_under "$caller" >/dev/null; do
    kill -0 "$runner" 2>/dev/null \
      || fail "$mode: the e2e ended before its remote job worker was serving: $(tail -20 "$tmp/out")"
    [ "$SECONDS" -lt "$deadline" ] || fail "$mode: the e2e never started a serving remote job worker"
    sleep 0.2
  done
  case "$mode" in
    int) kill -INT -- "-$runner" ;;
    abort) kill -KILL -- "-$runner" ;;
  esac
  wait "$runner" 2>/dev/null || rc=$?
  E2E_RUNNER=
  if [ "$mode" = abort ]; then
    # The killed run cleans nothing up itself; the sentinel it left must.
    deadline=$((SECONDS + FM_TEST_EVENT_HANG_GUARD_SECONDS))
    while [ -n "$(fm_test_remote_job_workers_under "$caller")" ] ||
      [ -n "$(find "$caller" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; do
      [ "$SECONDS" -lt "$deadline" ] || break
      sleep 0.2
    done
  fi
  survivors=$(fm_test_remote_job_workers_under "$caller")
  if [ -n "$survivors" ]; then
    for pid in $survivors; do fm_test_stop_remote_job_worker_tree "$pid"; done
    fail "$mode: remote job worker(s) $(printf '%s' "$survivors" | tr '\n' ' ')outlived the interrupted e2e: $(tail -20 "$tmp/err")"
  fi
  [ -z "$(find "$caller" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
    || fail "$mode: the interrupted e2e left its sandbox behind: $(find "$caller" -maxdepth 4 | head -20)"
  [ "$mode" != int ] || [ "$rc" -eq 130 ] || fail "an interrupted e2e run must exit 130, got $rc: $(tail -20 "$tmp/err")"
}

test_ctrl_c_mid_e2e_leaves_no_worker() {
  run_e2e_interrupt_case int
  pass "Ctrl-C during the remote secondmate e2e leaves no remote job worker or sandbox behind"
}

test_killed_e2e_run_leaves_no_worker() {
  run_e2e_interrupt_case abort
  pass "killing the remote secondmate e2e run outright leaves no remote job worker or sandbox behind"
}

# Each case runs its own e2e copy under a private temp root, so the two cases
# share nothing and run in the concurrent lanes tests/case-lanes-helpers.sh owns.
FM_TEST_CASE_TEARDOWN=stop_e2e_runner
trap 'stop_e2e_runner; fm_test_cleanup' EXIT
# shellcheck source=tests/case-lanes-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/case-lanes-helpers.sh"
fm_test_run_cases \
  test_ctrl_c_mid_e2e_leaves_no_worker \
  test_killed_e2e_run_leaves_no_worker
