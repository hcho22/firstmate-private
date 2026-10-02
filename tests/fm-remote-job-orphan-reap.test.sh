#!/usr/bin/env bash
# Behavior tests for remote job workers abandoned by a pruned code root.
#
# The leak this pins: a worker launched from a worktree's own bin/ outlives that
# worktree. Its restart supervisor sits above the serving child, so killing the
# recorded worker pid only makes the supervisor respawn, and nothing else ever
# stops it. Observed 2026-08-07 as 29 workers at ppid 1, 1-2 days old, each
# still appending to a log in a pruned no-mistakes gate worktree.
#
# bin/fm-remote-job-reap-orphans.sh is a machine-wide sweep by design. tests/lib.sh
# scopes every sweep a test runs to its own TMPDIR (FM_REMOTE_JOB_REAP_SCOPE), so
# these cases reap only their own fixtures and no other script's sweep can stop
# them; the scope cases below also prove the unscoped sweep still reaches them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-orphan-reap)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REAPER="$ROOT/bin/fm-remote-job-reap-orphans.sh"

TRACKED_PIDS=()
orphan_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap orphan_cleanup EXIT

track() { TRACKED_PIDS+=("$1"); }

alive() { kill -0 "$1" 2>/dev/null; }

pgid_of() { ps -p "$1" -o pgid= 2>/dev/null | tr -d '[:space:]'; }

ppid_of() { ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'; }

# Wait up to <seconds> for <pid> to exit; 0 when it did.
wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

# Wait up to <seconds> for <pid> to have a live child; 0 when it does.
wait_child() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(pgrep -P "$pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- a real worker fixture, launched exactly the way fm-on's Linux start does -

# build_remote_root <dir>: a minimal but genuine Firstmate code root carrying
# the real worker and job library.
build_remote_root() {
  local root=$1
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$root/bin/"
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q -b main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name Test
  git -C "$root" add AGENTS.md bin
  git -C "$root" commit -qm 'remote job fixture'
}

pid_is_numeric() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# start_worker <remote-root> <account-home> <state-root>: start the worker
# through the shared library start path and echo the supervisor pid.
start_worker() {
  local root=$1 account_home=$2 state_root=$3 pid deadline
  pid=$(
    export FM_REMOTE_JOB_STATE_ROOT="$state_root"
    export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    export FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS=1
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_start_linux_worker "$root" "$account_home" >&2 || exit 1
    deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      pid=$(pgrep -f "^/bin/bash $root/bin/fm-remote-job-worker.sh\$" | head -n 1)
      if pid_is_numeric "$pid"; then
        printf '%s\n' "$pid"
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  ) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

CASE1="$TMP_ROOT/case1"
mkdir -p "$CASE1/account"
build_remote_root "$CASE1/remote-root"
WORKER=$(start_worker "$CASE1/remote-root" "$CASE1/account" "$CASE1/remote-jobs") ||
  fail "could not start the fixture remote job worker"
track "$WORKER"
wait_child "$WORKER" 10 || fail "the fixture worker never started its serving child"
SERVE=$(pgrep -P "$WORKER" | head -n 1)

[ "$(pgid_of "$WORKER")" = "$WORKER" ] ||
  fail "the started worker is not its own process group leader, so its tree cannot be signalled as one group"
[ "$(pgid_of "$SERVE")" = "$WORKER" ] ||
  fail "the serving child is outside the worker's process group"
pass "the Linux start path puts the whole worker tree in its own process group"

[ "$(ppid_of "$WORKER")" = 1 ] ||
  fail "the fixture worker is not orphaned to init, so this case does not reproduce the leak"

# The exact teardown shape that leaked in production: a fixture cleanup removes
# the worker's state root and then stops only the single recorded worker pid -
# which is the serving child, not the supervisor. KILL makes that obsolete
# teardown reproduction independent of the graceful handler's missing-state
# refusal. The supervisor respawns, so the tree survives a teardown that looks
# complete.
rm -rf "$CASE1/remote-jobs"
kill -KILL "$SERVE" 2>/dev/null || true
wait_gone "$SERVE" 10 || fail "the recorded serving child did not stop"
alive "$WORKER" || fail "the fixture supervisor did not survive a lone child kill, so this case no longer covers the leak"
wait_child "$WORKER" 15 || fail "the supervisor did not respawn after its recorded child pid was killed"
pass "removing the state root and killing the recorded worker pid leaves the tree running at ppid 1"

# A worker whose code root is intact is never a reap candidate, which is what
# keeps the account's healthy LaunchAgent worker out of scope.
out=$("$REAPER" 2>&1) || fail "the reaper failed against a live code root: $out"
assert_not_contains "$out" "$WORKER" "the reaper reported a worker whose code root still exists"
alive "$WORKER" || fail "the reaper stopped a worker whose code root still exists"
pass "a worker whose code root still exists is never reaped"

# Prune the code root the way a returned worktree does.
SURVIVOR=$(pgrep -P "$WORKER" | head -n 1)
rm -rf "$CASE1/remote-root"
wait_gone "$WORKER" 60 || fail "the worker survived its code root being pruned"
wait_gone "$SURVIVOR" 60 || fail "a serving child outlived the abandoned supervisor"
pass "a worker stops its whole tree once its code root is pruned"

# --- the belt-and-suspenders sweep over already-orphaned workers -------------
#
# A current worker stops itself, so the sweep is exercised against a stand-in
# that presents the same command line from a pruned root without that
# self-termination - the shape of every worker started before it shipped.

# start_stand_in <remote-root>: start the stand-in as its own process group
# leader and set STAND_IN to its supervisor pid.
start_stand_in() {
  local root=$1
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
# Stand-in for a worker predating self-termination: a supervisor that always
# respawns its serving child and never inspects its own code root.
set -u
if [ "${1:-}" = --serve ]; then
  while :; do sleep 0.2; done
fi
while :; do
  "$0" --serve &
  wait $! 2>/dev/null
  sleep 0.2
done
SH
  chmod +x "$root/bin/fm-remote-job-worker.sh"
  printf 'fixture\n' > "$root/AGENTS.md"
  set -m
  "$root/bin/fm-remote-job-worker.sh" >/dev/null 2>&1 &
  STAND_IN=$!
  set +m
  track "$STAND_IN"
  wait_child "$STAND_IN" 10 || fail "the stand-in worker never started its serving child"
}

CASE2="$TMP_ROOT/case2"
start_stand_in "$CASE2/remote-root"
STALE=$STAND_IN
STALE_SERVE=$(pgrep -P "$STALE" | head -n 1)

rm -rf "$CASE2/remote-root"

out=$("$REAPER" --dry-run 2>&1) || fail "the reaper dry run failed: $out"
assert_contains "$out" "$STALE" "the dry run did not report the abandoned worker"
assert_contains "$out" "would reap" "the dry run did not mark its report as a preview"
alive "$STALE" || fail "the dry run stopped the abandoned worker instead of only reporting it"
pass "a dry run reports the abandoned worker and signals nothing"

out=$("$REAPER" 2>&1) || fail "the reaper failed: $out"
assert_contains "$out" "$STALE" "the reaper did not report stopping the abandoned worker"
wait_gone "$STALE" 20 || fail "the abandoned worker survived the reaper"
wait_gone "$STALE_SERVE" 20 || fail "the abandoned worker's serving child survived the reaper"
pass "the reaper stops an abandoned worker's whole tree"

out=$("$REAPER" 2>&1) || fail "a repeat reaper run failed: $out"
assert_not_contains "$out" "$STALE" "the reaper reported an already-stopped worker"
pass "the reaper is idempotent"

# --- the sweep scope -----------------------------------------------------------

CASE3="$TMP_ROOT/case3"
mkdir -p "$TMP_ROOT/elsewhere"
start_stand_in "$CASE3/remote-root"
SCOPED=$STAND_IN
SCOPED_SERVE=$(pgrep -P "$SCOPED" | head -n 1)
rm -rf "$CASE3/remote-root"

out=$(FM_REMOTE_JOB_REAP_SCOPE="$TMP_ROOT/elsewhere" "$REAPER" 2>&1) ||
  fail "a sweep scoped to another directory failed: $out"
assert_not_contains "$out" "$SCOPED" "a sweep scoped to another directory reported an out-of-scope worker"
alive "$SCOPED" || fail "a sweep scoped to another directory stopped an out-of-scope worker"
# Host-wide reach is proven with a dry run, so the case signals nothing outside
# its own fixtures.
out=$(env -u FM_REMOTE_JOB_REAP_SCOPE "$REAPER" --dry-run 2>&1) ||
  fail "an unscoped dry run failed: $out"
assert_contains "$out" "would reap abandoned remote job worker $SCOPED" \
  "an unscoped sweep did not reach the abandoned worker"
alive "$SCOPED" || fail "the unscoped dry run stopped the abandoned worker"
pass "a scoped sweep leaves an out-of-scope worker alone and an unscoped sweep still reaches it"

for scope in relative/dir "$TMP_ROOT/no-such-directory"; do
  rc=0
  out=$(FM_REMOTE_JOB_REAP_SCOPE="$scope" "$REAPER" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an invalid sweep scope ($scope) did not refuse the sweep: rc=$rc $out"
  assert_contains "$out" "FM_REMOTE_JOB_REAP_SCOPE" "an invalid sweep scope refusal did not name the setting"
  alive "$SCOPED" || fail "an invalid sweep scope ($scope) stopped a worker instead of refusing"
done
pass "an invalid sweep scope refuses the whole sweep instead of widening it"

# A scope spelled through a symlink still matches the physical code root.
ln -s "$CASE3" "$TMP_ROOT/case3-link"
out=$(FM_REMOTE_JOB_REAP_SCOPE="$TMP_ROOT/case3-link" "$REAPER" 2>&1) ||
  fail "a sweep scoped through a symlink failed: $out"
assert_contains "$out" "reaped abandoned remote job worker $SCOPED" \
  "a sweep scoped through a symlink did not reap the abandoned worker inside it"
wait_gone "$SCOPED" 20 || fail "the in-scope abandoned worker survived its scoped sweep"
wait_gone "$SCOPED_SERVE" 20 || fail "the in-scope worker's serving child survived its scoped sweep"
pass "a scoped sweep reaps an abandoned worker inside its scope, however the scope is spelled"
