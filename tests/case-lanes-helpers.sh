#!/usr/bin/env bash
# tests/case-lanes-helpers.sh - run a test file's independent cases in a few
# concurrent lanes instead of one after another.
#
# A file adopts this only when its cases share nothing: each builds its own world
# under its own directory, keys every process, lock, and path it touches to that
# world, and leaves no state a later case reads. The only shared inputs are
# read-only: helpers and stubs the file sets up before the first case, and the
# production scripts under test. Such cases spend most of their time waiting on
# the scripts they drive (watcher polls, git, node, the scripts' own sleeps), so
# a few lanes shorten the file without asking more of the host than a few idle
# waits do.
#
# Usage, as the last command of the file:
#   . "$(dirname "${BASH_SOURCE[0]}")/case-lanes-helpers.sh"
#   fm_test_run_cases test_one test_two ...
#
# Each lane claims the next unclaimed case in the order given and runs it in its
# own subshell, so a case's exports and globals never leak into another case,
# with its output in a private file. The output is then printed in the order
# given, as each case and every case before it has finished, so the result reads
# exactly as a serial run does and the runner's silence guard sees real progress.
# The first failing case stops further claims; cases already running finish, and
# the file fails with the first failing case's status. A case that never started
# without any failure is lost coverage and fails the file.
#
# FM_TEST_CASE_PID names the shell running the current case: the file's own
# shell with one lane, the case's subshell otherwise. Either way it is a live
# ancestor of everything the case starts, at the same depth, so a case that
# needs such a pid (a fake harness a production script finds by walking its
# ancestry) uses it instead of $$, which a laned case's processes reach only
# through two more levels.
#
# A file whose cases start processes or hold resources that its own EXIT cleanup
# reaps through globals a case sets (a lock holder's pid, a fixture's job
# directory) names that cleanup in FM_TEST_CASE_TEARDOWN. A laned case runs in a
# subshell whose globals the file's shell never sees, so the helper runs that
# function when each laned case's subshell exits, pass or fail; it must reap only
# what the case's own globals name. With one lane it runs after each case
# returns; a failing case there ends the file, whose own cleanup takes over.
#
# A family's proven concurrency bound in bin/fm-test-run.sh was proven with
# these lanes active; docs/fm-test-isolation-proof.md ("In-file case lanes")
# owns how lanes count against that bound.
#
# FM_TEST_CASE_LANES sets the lane count; the default is 4, or the host's CPU
# count when that is smaller. 1 runs every case in this shell, in order, with no
# lane machinery at all, which is also the way to rerun a file serially when
# isolating a failure.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_TEST_CASE_LANE_PIDS=()
FM_TEST_CASE_LANE_DIR=
FM_TEST_CASE_PRINTED=0
FM_TEST_CASES=()

# The pids of every process in the trees rooted at the arguments, one per line.
fm_test_case_tree_pids() {  # <pid>...
  ps -A -o pid= -o ppid= | awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (k = 1; k <= n; k++) seen[r[k]] = 1 }
    { pid[NR] = $1; ppid[NR] = $2 }
    END {
      do {
        grew = 0
        for (k = 1; k <= NR; k++)
          if (!(pid[k] in seen) && (ppid[k] in seen)) { seen[pid[k]] = 1; grew = 1 }
      } while (grew)
      for (p in seen) print p
    }' | sort -n
}

# The lanes still running, one pid per line, from this shell's own job table. A
# finished lane's pid is free for any process to reuse, so kill -0 on it proves
# nothing about the lane.
fm_test_case_running_lanes() {
  local pid running
  running=" $(jobs -pr | tr '\n' ' ') "
  for pid in "${FM_TEST_CASE_LANE_PIDS[@]+"${FM_TEST_CASE_LANE_PIDS[@]}"}"; do
    case "$running" in *" $pid "*) printf '%s\n' "$pid" ;; esac
  done
}

# Stop every running lane and everything it started, by exact pid. The trees are
# frozen first and read again until they stop growing, so nothing can fork a
# replacement between reading a tree and killing it, and no pid in it can be
# recycled before the kill lands.
fm_test_case_stop_lanes() {
  local roots pids next
  [ "${#FM_TEST_CASE_LANE_PIDS[@]}" -gt 0 ] || return 0
  roots=$(fm_test_case_running_lanes)
  if [ -n "$roots" ]; then
    # shellcheck disable=SC2086  # a list of pids, one word each
    pids=$(fm_test_case_tree_pids $roots)
    while :; do
      # shellcheck disable=SC2086
      kill -STOP $pids 2>/dev/null || :
      # shellcheck disable=SC2086
      next=$(fm_test_case_tree_pids $roots)
      [ "$next" != "$pids" ] || break
      pids=$next
    done
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || :
  fi
  wait "${FM_TEST_CASE_LANE_PIDS[@]}" 2>/dev/null || :
  FM_TEST_CASE_LANE_PIDS=()
}

# One lane: claim cases in order until none is left, or one has failed. A lane
# subshell does not inherit the EXIT, INT, or TERM traps, so only the file's own
# shell ever runs its cleanup.
fm_test_case_lane() {
  local i rc dir=$FM_TEST_CASE_LANE_DIR
  for i in "${!FM_TEST_CASES[@]}"; do
    [ ! -e "$dir/failed" ] || return 0
    mkdir "$dir/claim/$i" 2>/dev/null || continue
    (
      # A command substitution whose only command is sh runs sh in place of
      # its forked child, so sh's parent is this subshell.
      # shellcheck disable=SC2016  # $PPID must expand in sh
      FM_TEST_CASE_PID=$(sh -c 'printf "%s\n" "$PPID"')
      [ -z "${FM_TEST_CASE_TEARDOWN:-}" ] || trap '"$FM_TEST_CASE_TEARDOWN"' EXIT
      "${FM_TEST_CASES[$i]}"
    ) > "$dir/out/$i.out" 2> "$dir/out/$i.err"
    rc=$?
    [ "$rc" -eq 0 ] || : > "$dir/failed"
    printf '%s\n' "$rc" > "$dir/out/$i.rc"
  done
}

fm_test_case_print() {  # <index>
  [ ! -e "$FM_TEST_CASE_LANE_DIR/out/$1.out" ] || cat "$FM_TEST_CASE_LANE_DIR/out/$1.out"
  [ ! -e "$FM_TEST_CASE_LANE_DIR/out/$1.err" ] || cat "$FM_TEST_CASE_LANE_DIR/out/$1.err" >&2
}

# Print each case whose result is in once every case before it is printed.
fm_test_case_print_finished_prefix() {
  while [ "$FM_TEST_CASE_PRINTED" -lt "${#FM_TEST_CASES[@]}" ] \
    && [ -e "$FM_TEST_CASE_LANE_DIR/out/$FM_TEST_CASE_PRINTED.rc" ]; do
    fm_test_case_print "$FM_TEST_CASE_PRINTED"
    FM_TEST_CASE_PRINTED=$((FM_TEST_CASE_PRINTED + 1))
  done
}

# After the lanes were stopped, print every case not yet printed that finished
# or was cut off mid-run, so an interrupted file still shows what it got through.
fm_test_case_print_after_stop() {
  local i
  [ -n "$FM_TEST_CASE_LANE_DIR" ] || return 0
  for ((i = FM_TEST_CASE_PRINTED; i < ${#FM_TEST_CASES[@]}; i++)); do
    if [ -e "$FM_TEST_CASE_LANE_DIR/out/$i.rc" ]; then
      fm_test_case_print "$i"
    elif [ -d "$FM_TEST_CASE_LANE_DIR/claim/$i" ]; then
      fm_test_case_print "$i"
      printf 'not ok - %s was still running when the file was stopped\n' "${FM_TEST_CASES[$i]}" >&2
    fi
  done
  FM_TEST_CASE_PRINTED=${#FM_TEST_CASES[@]}
}

# The command a signal's trap currently runs, so the lane traps can run it after
# stopping the lanes rather than replacing a file's own cleanup.
fm_test_case_trap_command() {  # <signal>
  local spec
  spec=$(trap -p "$1")
  [ -n "$spec" ] || return 0
  # `trap -p` prints `trap -- '<command>' <SIGNAL>`, quoted for reuse as shell
  # input; let the shell parse it back and keep the command word.
  eval "fm_test_case_trap_word() { printf '%s' \"\$2\"; }; fm_test_case_trap_word ${spec#trap }"
}

fm_test_run_cases() {  # <case-function>...
  local lanes lane pid i rc status=0 on_exit on_int on_term
  FM_TEST_CASES=("$@")
  [ "${#FM_TEST_CASES[@]}" -gt 0 ] || fail "fm_test_run_cases needs at least one case"
  lanes=${FM_TEST_CASE_LANES:-}
  if [ -z "$lanes" ]; then
    lanes=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    case "$lanes" in ''|*[!0-9]*|0) lanes=1 ;; esac
    [ "$lanes" -le 4 ] || lanes=4
  fi
  case "$lanes" in
    ''|*[!0-9]*|0) fail "FM_TEST_CASE_LANES must be a positive whole number, got '$lanes'" ;;
  esac
  [ "$lanes" -le "${#FM_TEST_CASES[@]}" ] || lanes=${#FM_TEST_CASES[@]}

  if [ "$lanes" -eq 1 ]; then
    # shellcheck disable=SC2034  # read by the cases this runs
    FM_TEST_CASE_PID=$$
    for i in "${!FM_TEST_CASES[@]}"; do
      "${FM_TEST_CASES[$i]}"
      [ -z "${FM_TEST_CASE_TEARDOWN:-}" ] || "$FM_TEST_CASE_TEARDOWN"
    done
    return 0
  fi

  FM_TEST_CASE_LANE_DIR=$(fm_test_tmproot fm-test-case-lanes) || fail "could not create the case lane directory"
  mkdir -p "$FM_TEST_CASE_LANE_DIR/claim" "$FM_TEST_CASE_LANE_DIR/out"
  on_exit=$(fm_test_case_trap_command EXIT)
  on_int=$(fm_test_case_trap_command INT)
  on_term=$(fm_test_case_trap_command TERM)
  # shellcheck disable=SC2064  # the file's own handlers are captured now, by design
  trap "fm_test_case_stop_lanes; fm_test_case_print_after_stop; ${on_int:-exit 130}" INT
  # shellcheck disable=SC2064
  trap "fm_test_case_stop_lanes; fm_test_case_print_after_stop; ${on_term:-exit 143}" TERM
  # shellcheck disable=SC2064
  trap "fm_test_case_stop_lanes; fm_test_case_print_after_stop; ${on_exit:-:}" EXIT
  for ((lane = 0; lane < lanes; lane++)); do
    fm_test_case_lane &
    FM_TEST_CASE_LANE_PIDS+=("$!")
  done
  while [ -n "$(fm_test_case_running_lanes)" ]; do
    fm_test_case_print_finished_prefix
    sleep 0.2
  done
  for pid in "${FM_TEST_CASE_LANE_PIDS[@]}"; do
    wait "$pid" || { printf 'not ok - a case lane ended abnormally (%s)\n' "$?" >&2; status=1; }
  done
  FM_TEST_CASE_LANE_PIDS=()
  fm_test_case_print_finished_prefix

  # Print the rest in the order given, and fail with the first failing case's
  # status. A case with no result is one that never started because an earlier
  # failure stopped the lanes; with no failure, it is lost coverage and fails
  # the file.
  for ((i = FM_TEST_CASE_PRINTED; i < ${#FM_TEST_CASES[@]}; i++)); do
    if [ -e "$FM_TEST_CASE_LANE_DIR/out/$i.rc" ]; then
      fm_test_case_print "$i"
    elif [ ! -e "$FM_TEST_CASE_LANE_DIR/failed" ]; then
      printf 'not ok - %s reported no result\n' "${FM_TEST_CASES[$i]}" >&2
      status=1
    fi
  done
  FM_TEST_CASE_PRINTED=${#FM_TEST_CASES[@]}
  for i in "${!FM_TEST_CASES[@]}"; do
    [ -e "$FM_TEST_CASE_LANE_DIR/out/$i.rc" ] || continue
    rc=$(cat "$FM_TEST_CASE_LANE_DIR/out/$i.rc")
    [ "$rc" -eq 0 ] || [ "$status" -ne 0 ] || status=$rc
  done
  return "$status"
}
