#!/usr/bin/env bash
# Behavior tests for the remote transport's per-home lanes, caller-disconnect
# cancellation, stdin default, and staging-litter reaping.
#
# Pins, against the real worker and the real fm-on -> entrypoint transport
# (through the deterministic FM_SSH_BIN seam tests/fm-on.test.sh proves
# preserves exit status):
#   T9: a job for home B completes while home A runs a long job, and two
#       A-jobs execute strictly in stage order even when staged rapidly.
#   T3: a caller killed mid-wait cancels its job - the worker never executes a
#       cancelled queued job and terminates a running cancelled job's process
#       group - and a caller whose parent dies without delivering a signal
#       (the dead-ssh-channel shape) cancels the same way; a burst of short
#       commands staged right behind an abandoned job completes with no convoy.
#   T6: a non-payload fm-on call with an OPEN stdin pipe completes instead of
#       wedging staging, and a payload caller with --stdin still delivers its
#       bytes through the worker.
#   Stage litter older than the reap age does not survive a worker pass while
#   fresh staging does.
#
# Every lane holder and every abandoned job is a gated fixture that ends only
# when the test releases it or the worker cancels it, and every positive wait is
# bounded by a time guard on the real event. Nothing asserts how many seconds a
# step took: elapsed time on a shared host measures its load, not the property.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-transport-lanes)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
HOME_A="$TMP_ROOT/home-a"
HOME_B="$TMP_ROOT/home-b"
HOME_EDGE="$TMP_ROOT/home-a "
LOCAL_HOME="$TMP_ROOT/local-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
mkdir -p "$REMOTE_ROOT/bin" "$HOME_A" "$HOME_B" "$HOME_EDGE" "$LOCAL_HOME/data" "$ACCOUNT_HOME"

cleanup_lane_fixture() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_lane_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-delta-read.sh" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" "$ROOT/bin/fm-backend.sh" \
  "$ROOT/bin/fm-pending-reply-lib.sh" "$ROOT/bin/fm-task-inbox-lib.sh" \
  "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-marker-lib.sh" \
  "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-tmux-lib.sh" \
  "$ROOT/bin/fm-composer-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" \
  "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" \
  "$ROOT/bin/fm-ff-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" \
  "$REMOTE_ROOT/bin/"
mkdir -p "$REMOTE_ROOT/bin/backends"
cp "$ROOT/bin/backends/herdr.sh" "$REMOTE_ROOT/bin/backends/herdr.sh"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
# Appends its tag to a shared log: the log order is the observable execution
# order.
cat > "$REMOTE_ROOT/bin/fm-mark-job.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
# Holds its lane until the release marker exists: appends its tag to the log,
# publishes its pid atomically (the file's presence marks the start), then
# blocks. A held lane is a state the test controls instead of a sleep the host's
# load can outlast, and an abandoned gated job can end only by cancellation.
cat > "$REMOTE_ROOT/bin/fm-gate-job.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$2"
if [ -n "${4:-}" ]; then
  printf '%s\n' "$$" > "$4.tmp" && mv -f -- "$4.tmp" "$4"
fi
while [ ! -e "$3" ]; do sleep 0.1; done
SH
cat > "$REMOTE_ROOT/bin/fm-stdin-probe.sh" <<'SH'
#!/bin/bash
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'lane transport fixture'

# ios routes to home A, build routes to home B.
cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $HOME_A; scope: iOS work; projects: alpha; added 2026-08-02)
- build - build delivery (host: remote-mac; root: $REMOTE_ROOT; home: $HOME_B; scope: build work; projects: beta; added 2026-08-02)
EOF

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60
export FM_REMOTE_JOB_TIMEOUT=30
export FM_REMOTE_JOB_STAGE_REAP_SECONDS=1
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
rm -f -- "$STATE_ROOT/seq"
SEQ_PIDS=()
for i in $(seq 1 20); do
  fm_remote_job_next_seq > "$TMP_ROOT/seq-$i" &
  SEQ_PIDS+=("$!")
done
for pid in "${SEQ_PIDS[@]}"; do
  wait "$pid" || fail "a concurrent sequence allocator failed"
done
SEQ_RESULTS=$(cat "$TMP_ROOT"/seq-* | sort -n)
SEQ_EXPECTED=$(seq 1 20)
[ "$SEQ_RESULTS" = "$SEQ_EXPECTED" ] \
  || fail "concurrent sequence claims were not unique and monotonic: $SEQ_RESULTS"
[ "$(find "$STATE_ROOT/.seq-claims" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 20 ] \
  || fail "concurrent sequence allocations did not retain every durable claim"
mkdir "$STATE_ROOT/.seq-claims/999998" "$STATE_ROOT/.seq-claims/999999"
touch -t 200001010000 "$STATE_ROOT/.seq-claims/999998"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "sequence claim reaping failed"
assert_absent "$STATE_ROOT/.seq-claims/999998" "an expired sequence claim survived stale reaping"
assert_present "$STATE_ROOT/.seq-claims/999999" "a fresh sequence claim was reaped"
mkdir "$STATE_ROOT/.seq-claims/999997"
touch -t 200001010000 "$STATE_ROOT/.seq-claims/999997"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "rate-limited sequence claim reaping failed"
assert_present "$STATE_ROOT/.seq-claims/999997" "sequence claims were rescanned before the hourly interval"
touch -t 200001010000 "$STATE_ROOT/.seq-claims-reaped"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "expired sequence claim reaping failed"
assert_absent "$STATE_ROOT/.seq-claims/999997" "an expired sequence claim survived the next hourly scan"
rmdir "$STATE_ROOT/.seq-claims/999999"
pass "atomic sequence claims remain unique and reap only after expiry"

fm_on() {
  FM_HOME="$LOCAL_HOME" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  "$ROOT/bin/fm-on.sh" "$@"
}

job_state() { # <id>
  fm_remote_job_read_state "$STATE_ROOT/jobs/$1" 2>/dev/null || true
}

# Every positive wait waits on the real event and is bounded by time, never by a
# count of sleeps: each iteration of a counted loop also pays process spawns, so
# on a loaded host the give-up arrives before the fixture's own path to the
# event. Only a genuine hang may reach the guard. SECONDS ticks on wall-clock
# second boundaries, so requiring more than the guard in ticks guarantees the
# full guard has elapsed.
EVENT_WAIT_SECONDS=60
# One whole fm-on call crosses fm-on, the ssh stand-in, the remote entrypoint, the
# queue, and a worker lane, many process spawns each, so its guard is wider.
CALL_GUARD_SECONDS=120
# An execution bound far beyond every guard here: a gated job ends only by its
# release or by cancellation, never by the worker's timeout path.
GATED_TIMEOUT=3600
# A held-open writer must outlive the call guard it is meant to outlast.
STDIN_HOLD_SECONDS=$((CALL_GUARD_SECONDS * 2))

wait_until() { # <command...>: poll until the command succeeds
  local started=$SECONDS
  until "$@"; do
    [ $((SECONDS - started)) -le "$EVENT_WAIT_SECONDS" ] || return 1
    sleep 0.05
  done
}

# Keeps a pipe's writer alive until the marker exists, so the reader's stdin
# capture stays open exactly as long as the test needs it.
hold_open_until() { # <marker>
  local started=$SECONDS
  until [ -e "$1" ] || [ $((SECONDS - started)) -gt "$STDIN_HOLD_SECONDS" ]; do
    sleep 0.05
  done
}

job_is() { [ "$(job_state "$1")" = "$2" ]; } # <id> <state>
wait_for_state() { wait_until job_is "$1" "$2"; } # <id> <state>
jobs_entry_absent() { [ ! -d "$STATE_ROOT/jobs/$1" ]; } # <name under jobs/>
job_records_absent() { ! ls "$STATE_ROOT"/jobs/job-* >/dev/null 2>&1; }
stage_dir_present() { ls "$STATE_ROOT/jobs"/.stage.* >/dev/null 2>&1; }
process_gone() { ! kill -0 "$1" 2>/dev/null; } # <pid>
log_has() { grep -qx -- "$2" "$1" 2>/dev/null; } # <log> <line>

# Sets QUEUED_JOB to the one queued job that is not the lane holder.
QUEUED_JOB=
queued_job_besides() { # <holder id>
  local job
  for job in "$STATE_ROOT"/jobs/job-*; do
    [ -d "$job" ] || continue
    [ "${job##*/}" = "$1" ] && continue
    if [ "$(job_state "${job##*/}")" = queued ]; then
      QUEUED_JOB=${job##*/}
      return 0
    fi
  done
  return 1
}

stage_gate() { # <home> <tag> <log> <release> [pid-file]: stage a job that holds its lane until <release> exists
  FM_REMOTE_JOB_TIMEOUT=$GATED_TIMEOUT fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$1" \
    fm-gate-job.sh "${@:2}" < /dev/null > /dev/null
}

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
wait_until test -f "$STATE_ROOT/worker.ready" \
  || fail "the worker did not publish its readiness heartbeat"

# T9: home B's job completes while home A runs a long job, and A's queued job
# stays strictly behind A's running job. Home A's job is held until released, so
# B's completion proves lane B was not queued behind lane A without measuring how
# long it took.
LOG_A="$TMP_ROOT/log-a"
LOG_B="$TMP_ROOT/log-b"
A1_RELEASE="$TMP_ROOT/a1-release"
stage_gate "$HOME_A" a1 "$LOG_A" "$A1_RELEASE"
A1=$FM_REMOTE_JOB_ID
wait_for_state "$A1" running || fail "home A's long job did not begin running"
# The state flips to running just before the command starts, so wait for the
# command's own first line before treating home A's lane as held by it.
wait_until log_has "$LOG_A" a1 || fail "home A's long job never started its command"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh a2 "$LOG_A" < /dev/null > /dev/null
A2=$FM_REMOTE_JOB_ID
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_EDGE" fm-mark-job.sh b1 "$LOG_B" < /dev/null > /dev/null
B1=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$B1" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "home B's job behind home A's long job did not complete"
[ "$(job_state "$A1")" = running ] || fail "home A's long job should still be running for the FIFO assertion"
[ "$(cat "$LOG_A")" = a1 ] || fail "home A's queued job ran beside its running job: $(cat "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$B1" || fail "home B's job could not be reaped"
: > "$A1_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$A1" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$A2" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(printf '%s' "$(cat "$LOG_A")")" = "$(printf 'a1\na2')" ] \
  || fail "home A's jobs did not execute in stage order: $(cat "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$A1" || fail "home A's first job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$A2" || fail "home A's second job could not be reaped"
pass "lanes run homes concurrently while each home stays FIFO"

# T9 stage order: five jobs staged in rapid succession behind a busy lane must
# execute in staging-sequence order, not the queue directory's random-id order.
# The lane stays busy until all five are staged, so they genuinely queue together.
: > "$LOG_A"
HOLD_RELEASE="$TMP_ROOT/hold-release"
stage_gate "$HOME_A" hold "$LOG_A" "$HOLD_RELEASE"
HOLD=$FM_REMOTE_JOB_ID
wait_for_state "$HOLD" running || fail "the lane-holding job did not begin running"
RAPID_IDS=()
for tag in r1 r2 r3 r4 r5; do
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh "$tag" "$LOG_A" < /dev/null > /dev/null
  RAPID_IDS+=("$FM_REMOTE_JOB_ID")
done
: > "$HOLD_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$HOLD" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_reap "$ACCOUNT_HOME" "$HOLD" || true
for id in "${RAPID_IDS[@]}"; do
  fm_remote_job_wait "$ACCOUNT_HOME" "$id" || fail "$FM_REMOTE_JOB_ERROR"
  fm_remote_job_reap "$ACCOUNT_HOME" "$id" || true
done
[ "$(cat "$LOG_A")" = "$(printf 'hold\nr1\nr2\nr3\nr4\nr5')" ] \
  || fail "rapidly staged same-home jobs did not execute in stage order: $(tr '\n' ' ' < "$LOG_A")"
pass "same-home jobs staged in the same second execute in staging-sequence order"

# The delayed stage's stdin stays open until the fast stage has published, so the
# fast stage completes first by construction and the order assertion does not
# depend on how fast the host stages.
: > "$LOG_A"
PUBLISH_RELEASE="$TMP_ROOT/publish-release"
FAST_PUBLISHED="$TMP_ROOT/fast-published"
stage_gate "$HOME_A" publish-hold "$LOG_A" "$PUBLISH_RELEASE"
PUBLISH_HOLD=$FM_REMOTE_JOB_ID
wait_for_state "$PUBLISH_HOLD" running || fail "the publication-order lane holder did not begin running"
(
  {
    printf 'delayed payload\n'
    hold_open_until "$FAST_PUBLISHED"
  } | fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" \
    fm-mark-job.sh delayed "$LOG_A"
) > "$TMP_ROOT/delayed-stage-id" &
DELAYED_STAGE_PID=$!
wait_until stage_dir_present || fail "the delayed stdin stage did not begin capturing"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh fast "$LOG_A" < /dev/null > /dev/null
FAST_STAGE=$FM_REMOTE_JOB_ID
: > "$FAST_PUBLISHED"
wait "$DELAYED_STAGE_PID" || fail "the delayed stdin stage failed to publish"
DELAYED_STAGE=$(cat "$TMP_ROOT/delayed-stage-id")
FAST_SEQ=$(fm_remote_job_read_number "$STATE_ROOT/jobs/$FAST_STAGE" seq) \
  || fail "the fast stage lost its sequence"
DELAYED_SEQ=$(fm_remote_job_read_number "$STATE_ROOT/jobs/$DELAYED_STAGE" seq) \
  || fail "the delayed stage lost its sequence"
[ "$FAST_SEQ" -lt "$DELAYED_SEQ" ] \
  || fail "sequence order did not follow publication order: fast=$FAST_SEQ delayed=$DELAYED_SEQ"
: > "$PUBLISH_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$PUBLISH_HOLD" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$FAST_STAGE" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$DELAYED_STAGE" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$LOG_A")" = "$(printf 'publish-hold\nfast\ndelayed')" ] \
  || fail "execution order diverged from publication sequence: $(tr '\n' ' ' < "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$PUBLISH_HOLD" || true
fm_remote_job_reap "$ACCOUNT_HOME" "$FAST_STAGE" || true
fm_remote_job_reap "$ACCOUNT_HOME" "$DELAYED_STAGE" || true
pass "same-home sequence order follows completed staging publication"

# T3a: a caller killed while its job is still queued cancels it; the worker
# never executes it. Lane A stays held for the whole cancellation, so the queued
# record can only have vanished by cancellation, never by running.
HOLD2_RELEASE="$TMP_ROOT/hold2-release"
stage_gate "$HOME_A" hold2 "$LOG_A" "$HOLD2_RELEASE"
HOLD2=$FM_REMOTE_JOB_ID
wait_for_state "$HOLD2" running || fail "the cancellation fixture's lane holder did not begin running"
QUEUED_EFFECT="$TMP_ROOT/queued-cancel-effect"
fm_on ios fm-touch-job.sh "$QUEUED_EFFECT" > /dev/null 2>&1 &
QUEUED_CALLER=$!
wait_until queued_job_besides "$HOLD2" || fail "the doomed caller's job never appeared in the queue"
kill -TERM "$QUEUED_CALLER" 2>/dev/null || true
wait "$QUEUED_CALLER" 2>/dev/null || true
wait_until jobs_entry_absent "$QUEUED_JOB" \
  || fail "the cancelled queued job's record survived (state: $(job_state "$QUEUED_JOB"))"
[ "$(job_state "$HOLD2")" = running ] \
  || fail "the cancelled queued job's record vanished only after its lane holder ended (state: $(job_state "$HOLD2"))"
assert_absent "$QUEUED_EFFECT" "the worker executed a queued job whose caller was killed while its lane was held"
: > "$HOLD2_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$HOLD2" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_reap "$ACCOUNT_HOME" "$HOLD2" || true
# A job staged after the cancelled one on the same lane runs strictly after it
# would have, so its completion proves the lane moved past the cancelled job
# without executing it.
SENTINEL_EFFECT="$TMP_ROOT/queued-cancel-sentinel"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-touch-job.sh "$SENTINEL_EFFECT" < /dev/null > /dev/null
SENTINEL=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$SENTINEL" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_reap "$ACCOUNT_HOME" "$SENTINEL" || true
assert_present "$SENTINEL_EFFECT" "the lane did not run the job staged behind the cancelled one"
assert_absent "$QUEUED_EFFECT" "the worker executed a cancelled queued job once its lane was free"
pass "a caller killed mid-wait cancels its queued job before execution"

# T3b: a caller killed while its job is running terminates the job's process
# group instead of letting it run for nobody. The job's execution bound is far
# beyond every guard and its release is never given, so the record can vanish and
# the process can end only through cancellation.
GATE_LOG="$TMP_ROOT/gate-log"
NEVER_RELEASED="$TMP_ROOT/never-released"
RUN_PID="$TMP_ROOT/running-cancel-pid"
FM_REMOTE_JOB_TIMEOUT=$GATED_TIMEOUT \
  fm_on build fm-gate-job.sh running-cancel "$GATE_LOG" "$NEVER_RELEASED" "$RUN_PID" > /dev/null 2>&1 &
RUNNING_CALLER=$!
wait_until test -f "$RUN_PID" || fail "the running-cancellation fixture never started"
kill -TERM "$RUNNING_CALLER" 2>/dev/null || true
wait "$RUNNING_CALLER" 2>/dev/null || true
wait_until job_records_absent || fail "the cancelled running job's record survived"
wait_until process_gone "$(cat "$RUN_PID")" \
  || fail "a cancelled running job's process group was not terminated"
pass "a caller killed mid-wait stops its running job's process group"

# T3c: a caller whose parent exits WITHOUT delivering any signal - the shape a
# dead ssh channel leaves behind - still cancels through the entrypoint's
# parent-liveness probe.
ORPHAN_PID="$TMP_ROOT/orphan-cancel-pid"
# shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_TIMEOUT="$GATED_TIMEOUT" \
  bash -c '
    "$1/bin/fm-on.sh" build fm-gate-job.sh orphan-cancel "$4" "$5" "$2" >/dev/null 2>&1 &
    deadline=$((SECONDS + $3))
    while [ ! -f "$2" ] && [ "$SECONDS" -le "$deadline" ]; do sleep 0.1; done
  ' _ "$ROOT" "$ORPHAN_PID" "$CALL_GUARD_SECONDS" "$GATE_LOG" "$NEVER_RELEASED"
assert_present "$ORPHAN_PID" "the orphan-cancellation fixture never started"
wait_until job_records_absent || fail "the orphaned caller's job record survived its disconnect"
wait_until process_gone "$(cat "$ORPHAN_PID")" \
  || fail "a job abandoned by a signal-less disconnect kept running"
pass "a signal-less caller disconnect cancels the abandoned job through the parent probe"

# T3: a burst of short commands staged right behind an abandoned job completes
# with no convoy. The abandoned job holds lane build, its release is never given,
# and its execution bound is far beyond every guard, so it cannot end by itself:
# each burst command can complete only if the worker drops the abandoned job and
# moves on, and a convoy would sit behind it until the guard. The burst starts
# without waiting for the cancellation to settle, and one command takes the other
# home's lane.
BURST_PID="$TMP_ROOT/burst-abandoned-pid"
FM_REMOTE_JOB_TIMEOUT=$GATED_TIMEOUT \
  fm_on build fm-gate-job.sh burst-abandoned "$GATE_LOG" "$NEVER_RELEASED" "$BURST_PID" > /dev/null 2>&1 &
BURST_CALLER=$!
wait_until test -f "$BURST_PID" || fail "the burst fixture's abandoned job never started"
kill -TERM "$BURST_CALLER" 2>/dev/null || true
wait "$BURST_CALLER" 2>/dev/null || true
for spec in build:c1 ios:c2 build:c3; do
  route=${spec%%:*}
  tag=${spec#*:}
  rc=0
  fm_run_timed "$CALL_GUARD_SECONDS" env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$ROOT/bin/fm-on.sh" "$route" fm-touch-job.sh "$TMP_ROOT/burst-$tag" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "post-cancellation burst command $tag on $route did not complete (exit $rc): it convoyed behind abandoned work"
  assert_present "$TMP_ROOT/burst-$tag" "post-cancellation burst command $tag did not run"
done
assert_absent "$NEVER_RELEASED" "the abandoned job's release was given before the burst finished"
wait_until job_records_absent || fail "the burst's abandoned job record survived its cancellation"
wait_until process_gone "$(cat "$BURST_PID")" \
  || fail "the burst's abandoned job kept running after its caller was killed"
pass "bounded reads after a cancellation complete behind abandoned work with no convoy"

# T6: a non-payload call with an OPEN stdin pipe completes instead of wedging
# staging on a stdin capture that never reaches EOF. The pipe's writer stays open
# until the call has returned, and outlives the call guard, so only a call that
# ignores its stdin can finish.
printf 'rsm\n' > "$HOME_A/.fm-secondmate-home"
printf '# fixture secondmate home\n' > "$HOME_A/AGENTS.md"
mkdir -p "$HOME_A/state" "$HOME_A/bin"
STDIN_OPEN_RELEASE="$TMP_ROOT/stdin-open-release"
rc=0
fm_run_timed "$CALL_GUARD_SECONDS" env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state rsm \
  < <(hold_open_until "$STDIN_OPEN_RELEASE") > "$TMP_ROOT/state-out" 2> "$TMP_ROOT/state-err" || rc=$?
: > "$STDIN_OPEN_RELEASE"
[ "$rc" -ne 124 ] || fail "a control-state call with an open stdin pipe wedged staging"
assert_grep 'missing' "$TMP_ROOT/state-out" \
  "the control-state call did not complete through the worker: $(cat "$TMP_ROOT/state-err")"
pass "an open caller stdin no longer wedges a non-payload remote command"

# A live explicit stdin stage can exceed the litter age while waiting for EOF;
# the stale sweep must retain it until its owning entrypoint publishes the job.
rc=0
{
  printf 'slow payload one\n'
  sleep 3
  printf 'slow payload two\n'
} | fm_on --stdin ios fm-stdin-probe.sh > "$TMP_ROOT/slow-payload-out" 2> "$TMP_ROOT/slow-payload-err" || rc=$?
expect_code 0 "$rc" "a live slow stdin stage must survive stale reaping: $(cat "$TMP_ROOT/slow-payload-err")"
assert_grep 'stdin=slow payload one' "$TMP_ROOT/slow-payload-out" "the slow stdin stage lost its first bytes"
assert_grep 'stdin=slow payload two' "$TMP_ROOT/slow-payload-out" "the slow stdin stage was reaped before EOF"
pass "a live explicit-stdin stage survives the staging-litter age bound"

# T6: a payload caller with --stdin still delivers its bytes.
printf 'payload byte one\npayload byte two\n' > "$TMP_ROOT/payload"
fm_on --stdin ios fm-stdin-probe.sh < "$TMP_ROOT/payload" > "$TMP_ROOT/payload-out" 2>/dev/null \
  || fail "the --stdin payload call failed"
assert_grep 'stdin=payload byte one' "$TMP_ROOT/payload-out" "--stdin did not deliver the payload"
assert_grep 'stdin=payload byte two' "$TMP_ROOT/payload-out" "--stdin lost part of the payload"
pass "--stdin still delivers a payload caller's bytes"

# Stage litter: an abandoned .stage.* older than the reap age does not survive
# a worker pass, while staging owned by this live process is left alone even if
# CI scheduling pauses long enough for it to cross the age bound.
OLD_STAGE="$STATE_ROOT/jobs/.stage.abandoned"
LIVE_STAGE="$STATE_ROOT/jobs/.stage.live"
LIVE_STAGE_BUILD="$STATE_ROOT/jobs/.stage-live-build"
mkdir -p "$OLD_STAGE" "$LIVE_STAGE_BUILD"
printf '%s\n' "$$" > "$LIVE_STAGE_BUILD/.owner-pid"
fm_remote_job_process_start "$$" > "$LIVE_STAGE_BUILD/.owner-start" \
  || fail "the live staging fixture could not record its owner identity"
mv -- "$LIVE_STAGE_BUILD" "$LIVE_STAGE"
touch -t 200001010000 "$OLD_STAGE" "$LIVE_STAGE"
wait_until jobs_entry_absent .stage.abandoned \
  || fail "stage litter older than the reap age survived the worker pass"
assert_present "$LIVE_STAGE" "the worker reaped staging owned by a live process"
rm -rf -- "$LIVE_STAGE"
pass "abandoned stage litter is reaped by age while live staging survives"

echo "ALL TESTS PASSED"
