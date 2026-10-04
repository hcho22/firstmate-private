#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
REPEAT_WORKER_PID=
RESTART_SUPERVISOR_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
# worker.pid records the serving child, not its restart supervisor, so stopping
# that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup_remote_job_fixture() {
  [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WORKER_PID" ] || kill "$RECOVERY_WORKER_PID" 2>/dev/null || true
  [ -z "$REPEAT_WORKER_PID" ] || kill "$REPEAT_WORKER_PID" 2>/dev/null || true
  [ -z "$RESTART_SUPERVISOR_PID" ] || kill -KILL "$RESTART_SUPERVISOR_PID" 2>/dev/null || true
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_remote_job_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
# Run far past the 1 s timeout its cases grant, so only the worker's deadline
# can end it while the case waits, however late a loaded host enforces it.
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 20
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-hold-job.sh" <<'SH'
#!/bin/bash
# Hold the lane until the case creates the release file, and stop once the case
# is gone or after 120 s, so a failed case never leaves the job waiting forever.
deadline=$((SECONDS + 120))
while [ ! -e "$1" ] && [ -d "${1%/*}" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
# Ignore every stop signal but KILL, record this pid, and hold until the case
# creates the release file, so only a KILL from the worker can keep the side
# effect from landing. Stop once the case is gone or after 120 s, so a failed
# case never leaves the job waiting forever.
trap '' HUP INT TERM
printf '%s\n' "$$" > "$1"
deadline=$((SECONDS + 120))
while [ ! -e "$3" ] && [ -d "${3%/*}" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

DEFAULT_STATE="$TMP_ROOT/default-timeout-jobs"
DEFAULT_BOUNDS=$(
  unset FM_REMOTE_JOB_QUEUE_TIMEOUT
  unset FM_REMOTE_JOB_TIMEOUT
  # shellcheck disable=SC2030 # This source intentionally initializes subshell-only defaults.
  FM_REMOTE_JOB_STATE_ROOT="$DEFAULT_STATE"
  export FM_REMOTE_JOB_STATE_ROOT
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
  printf '%s %s\n' \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/queue_deadline")" \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/timeout")"
)
read -r DEFAULT_QUEUE_DEADLINE DEFAULT_EXECUTION_TIMEOUT <<< "$DEFAULT_BOUNDS"
DEFAULT_QUEUE_REMAINING=$((DEFAULT_QUEUE_DEADLINE - $(date +%s)))
[ "$DEFAULT_QUEUE_REMAINING" -ge 350 ] || fail "the default queue bound is too short"
[ "$DEFAULT_EXECUTION_TIMEOUT" -ge 350 ] || fail "the default execution bound cannot contain a 300-second long poll"
pass "default queue and execution bounds independently cover long polls"

# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

LOCAL_BIN_PARENT="$ACCOUNT_HOME/.local"
LOCAL_BIN_TARGET="$TMP_ROOT/local-bin-target"
mkdir -p "$LOCAL_BIN_PARENT" "$LOCAL_BIN_TARGET"
ln -s "$LOCAL_BIN_TARGET" "$LOCAL_BIN_PARENT/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$LOCAL_BIN_PARENT/bin:"*|*":$LOCAL_BIN_TARGET:"*) fail "the composed PATH followed a symlinked local bin" ;;
esac
rm -f "$LOCAL_BIN_PARENT/bin"
mkdir "$LOCAL_BIN_PARENT/bin"
pass "operator PATH excludes a symlinked local bin"

NVM_ROOT="$ACCOUNT_HOME/.nvm"
NVM_V20="$NVM_ROOT/versions/node/v20.18.0/bin"
NVM_V24="$NVM_ROOT/versions/node/v24.14.1/bin"
mkdir -p "$NVM_ROOT/alias" "$NVM_V20" "$NVM_V24"
printf '20\n' > "$NVM_ROOT/alias/default"
printf '#!/bin/bash\nprintf "20\\n"\n' > "$NVM_V20/node"
printf '#!/bin/bash\nprintf "24\\n"\n' > "$NVM_V24/node"
chmod +x "$NVM_V20/node" "$NVM_V24/node"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 20 ] || fail "the composed PATH ignored nvm's default alias"
rm -f "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 24 ] || fail "the nvm fallback did not select the highest installed version"
printf 'system\n' > "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NVM_V20:"*|*":$NVM_V24:"*) fail "the composed PATH ignored nvm's system default" ;;
esac
printf '20\n' > "$NVM_ROOT/alias/default"
pass "operator PATH honors nvm defaults with a deterministic fallback"

NIX_PROFILE="$ACCOUNT_HOME/.nix-profile"
NIX_BIN="$TMP_ROOT/nix-profile-bin"
mkdir -p "$NIX_PROFILE" "$NIX_BIN"
ln -s "$NIX_BIN" "$NIX_PROFILE/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NIX_BIN:"*) ;;
  *) fail "the composed PATH omitted a resolved Nix profile bin link" ;;
esac
pass "operator PATH resolves the authorized Nix profile bin link"

# Which install of a multi-version tool a remote job resolves is decided by the
# order these directories land on PATH, so the composition has to be sorted
# rather than whatever order the filesystem returns. The fixture is created in
# a deliberately unsorted order, and the expectation is the shell's own
# pathname expansion - the mechanism the portable-PATH contract in
# tests/fm-on.test.sh reconstructs.
MISE_INSTALLS="$ACCOUNT_HOME/.local/share/mise/installs"
for TOOL_VERSION in node/26.7.0 node/8.1 node/26 bun/1.4 bun/1.3.14 python/3.12.7; do
  mkdir -p "$MISE_INSTALLS/$TOOL_VERSION/bin"
done
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
MISE_COMPOSED=$(printf '%s\n' "$FM_REMOTE_JOB_OPERATOR_PATH" | tr ':' '\n' | grep -F "$MISE_INSTALLS/" || true)
MISE_EXPECTED=$(printf '%s\n' "$MISE_INSTALLS"/*/*/bin)
[ "$MISE_COMPOSED" = "$MISE_EXPECTED" ] \
  || fail "the composed operator PATH did not order tool installs like the shell's own expansion"$'\n'"expected: $MISE_EXPECTED"$'\n'"actual:   $MISE_COMPOSED"
# This assertion detects the defect on bash 3.2 and 5.2, where compgen -G returns unsorted glob matches, but reads green on bash 5.3+ because glob sorting moved into the glob library so both mechanisms agree there.
rm -rf -- "$ACCOUNT_HOME/.local/share/mise"
pass "operator PATH orders discovered tool installs deterministically"

# Every positive wait waits on the real event and is bounded by time, never by a
# count of sleeps: each iteration of a counted loop also pays process spawns, and
# a worker lane, a freshly written stub, or a restarted worker reaches its next
# event only after many more, so on a loaded host the give-up arrives before the
# fixture's own path to the event. Only a genuine hang may reach the guard.
# SECONDS ticks on wall-clock second boundaries, so requiring more than the guard
# in ticks guarantees the full guard has elapsed.
EVENT_WAIT_SECONDS=60
wait_until() { # <command...>: poll until the command succeeds
  local started=$SECONDS
  until "$@"; do
    [ $((SECONDS - started)) -le "$EVENT_WAIT_SECONDS" ] || return 1
    sleep 0.05
  done
}
job_in_state() { [ "$(fm_remote_job_read_state "$1" 2>/dev/null || true)" = "$2" ]; } # <job-dir> <state>
process_gone() { ! kill -0 "$1" 2>/dev/null; } # <pid>
worker_pid_replaced() { # <old pid>: another worker has published its pid
  local current
  current=$(cat "$STATE_ROOT/worker.pid" 2>/dev/null || true)
  [ -n "$current" ] && [ "$current" != "$1" ]
}

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
wait_until test -f "$STATE_ROOT/worker.ready" \
  || fail "the worker did not publish its readiness heartbeat"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

printf 'first line\nsecond line\n' > "$TMP_ROOT/stdin"
# shellcheck disable=SC2016 # Literal shell-looking argv is an injection probe.
TOP_SECRET=must-not-cross fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-probe-job.sh 'two words' '$(not executed)' < "$TMP_ROOT/stdin" > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
[ "$(file_mode "$JOB_DIR")" = 700 ] \
  || fail "staged job directory is not mode 0700"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the completed probe did not preserve exit status"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" "home=$REMOTE_HOME" "the worker did not pass the staged FM_HOME"
assert_contains "$OUT" "root=$REMOTE_ROOT" "the worker did not pass the configured root"
assert_contains "$OUT" 'active=1' "the target did not execute inside the worker environment"
# shellcheck disable=SC2016 # Literal shell-looking expected output is an injection probe.
assert_contains "$OUT" 'args: <two words> <$(not executed)>' "the worker changed argv boundaries"
assert_contains "$OUT" 'stdin=first line' "the worker lost staged stdin"
assert_contains "$OUT" 'stdin=second line' "the worker lost staged stdin"
assert_contains "$OUT" 'secret=absent' "ambient environment crossed into the worker child"
case "$OUT" in *"$REMOTE_ROOT/bin:$ACCOUNT_HOME/.local/bin:"*) : ;; *) fail "worker PATH omitted its fixed root and account head" ;; esac
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the completed job could not be reaped"
assert_absent "$JOB_DIR" "reap retained a completed job record"
assert_absent "$FAKE_PERL_LOG" "the worker invoked an unavailable Perl runtime"
pass "the worker preserves bounded argv and stdin in an empty environment"

ACTIVE_SIDE_EFFECT="$TMP_ROOT/active-side-effect"
ACTIVE_RELEASE="$TMP_ROOT/active-release"
# The job stays active until this case releases it, so the readiness checks can
# pass only on heartbeats the worker writes while the job runs, never on an idle
# pass after it ends. Its execution timeout outlasts the probe's hang guard.
FM_REMOTE_JOB_TIMEOUT=$((EVENT_WAIT_SECONDS * 2))
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-hold-job.sh "$ACTIVE_RELEASE" "$ACTIVE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
wait_until job_in_state "$JOB_DIR" running \
  || fail "the active-job readiness fixture did not begin running"
ACTIVE_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
touch -t 200001010000 "$STATE_ROOT/worker.ready"
wait_until fm_remote_job_probe "$ACCOUNT_HOME" \
  || fail "the active worker did not refresh its readiness heartbeat"
job_in_state "$JOB_DIR" running || fail "the readiness probe passed only after the active job ended"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$ACTIVE_WORKER_PID" ] \
  || fail "ensure replaced a healthy worker during an active job"
job_in_state "$JOB_DIR" running || fail "the active job ended before ensure had checked the worker"
: > "$ACTIVE_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the active job did not complete after the readiness probe"
assert_present "$ACTIVE_SIDE_EFFECT" "the active job was interrupted by the concurrent readiness check"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the active readiness job could not be reaped"
pass "active jobs keep the worker ready for concurrent requests"

OLD_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker running stale code"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "the replacement worker did not publish the current code identity"
pass "ensure replaces a live worker after its code changes"

RELOCATED_ROOT="$TMP_ROOT/relocated-root"
cp -R "$REMOTE_ROOT" "$RELOCATED_ROOT"
OLD_WORKER_PID=$NEW_WORKER_PID
OLD_WORKER_PGID=$(fm_remote_job_process_pgid "$OLD_WORKER_PID") \
  || fail "the worker replacement fixture could not resolve its process group"
fm_remote_job_ensure_worker "$RELOCATED_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker bound to a different code root"
! kill -0 -- "-$OLD_WORKER_PGID" 2>/dev/null \
  || fail "ensure left the replaced worker supervisor group alive"
fm_remote_job_stage "$ACCOUNT_HOME" "$RELOCATED_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the relocated worker rejected its configured code root"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the relocated-root probe could not be reaped"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
pass "worker identity binds the canonical configured code root"

CRASHED_WORKER_PID=$NEW_WORKER_PID
kill -KILL "$CRASHED_WORKER_PID"
wait "$CRASHED_WORKER_PID" 2>/dev/null || true
assert_present "$STATE_ROOT/worker.lock" "an unclean exit did not retain the worker ownership lock"
sleep 20 &
OTHER_PID=$!
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
kill -0 "$OTHER_PID" 2>/dev/null || fail "stale worker state caused an unrelated process to be signaled"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OTHER_PID" ] || fail "the replacement adopted an unrelated persisted pid"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "stale ownership recovery did not start the current worker"
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=
pass "stale ownership is reclaimed without signaling a reused pid"

FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the worker did not terminate an over-time job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the timed-out job could not be reaped"
pass "the worker enforces the job timeout and publishes its result"

QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
wait_until job_in_state "$FIRST_JOB_DIR" running \
  || fail "the blocking job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "an expired queued job did not publish a timeout result"
assert_absent "$QUEUED_SIDE_EFFECT" "the worker executed a queued job after its durable deadline"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the blocking job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the expired queued job could not be reaped"
pass "the worker expires queued jobs before they can mutate"

FIRST_DELAYED_SIDE_EFFECT="$TMP_ROOT/first-delayed-side-effect"
FIRST_DELAYED_RELEASE="$TMP_ROOT/first-delayed-release"
SECOND_DELAYED_SIDE_EFFECT="$TMP_ROOT/second-delayed-side-effect"
# The first job holds the lane until the second job has been queued for longer
# than its whole execution timeout, so the second can complete only if its
# window starts at its claim rather than when it was staged. The hold is
# measured from the second job's staging, so a loaded host only lengthens it.
QUEUED_JOB_TIMEOUT=10
FM_REMOTE_JOB_QUEUE_TIMEOUT=600
FM_REMOTE_JOB_TIMEOUT=$((EVENT_WAIT_SECONDS * 2))
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-hold-job.sh "$FIRST_DELAYED_RELEASE" "$FIRST_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
wait_until job_in_state "$FIRST_JOB_DIR" running \
  || fail "the first delayed job did not begin running"
FM_REMOTE_JOB_TIMEOUT=$QUEUED_JOB_TIMEOUT
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$SECOND_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
sleep $((QUEUED_JOB_TIMEOUT + 2))
job_in_state "$FIRST_JOB_DIR" running || fail "the first delayed job stopped holding the lane"
: > "$FIRST_DELAYED_RELEASE"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "queue time consumed the second job's execution timeout"
assert_present "$SECOND_DELAYED_SIDE_EFFECT" "the queued job did not receive its full execution timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first delayed job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the second delayed job could not be reaped"
pass "queued jobs receive a fresh bounded execution window"

if command -v shasum >/dev/null 2>&1; then
  EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
else
  EMPTY_SHA=$(: | sha256sum | awk '{print $1}')
fi
mkdir -p "$REMOTE_HOME/state"
REPLY_LOG_REL=state/parent-replies.status
PREEMPT_SIDE_EFFECT="$TMP_ROOT/preempt-side-effect"
# The poll's window (the reader's 300-second maximum) is five times the short
# command's queue window, so the short command can complete inside its queue
# window only if the worker preempts the poll; waiting out the poll would expire
# it first. No elapsed time is measured.
FM_REMOTE_JOB_QUEUE_TIMEOUT=60
FM_REMOTE_JOB_TIMEOUT=400
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 300 < /dev/null > /dev/null
POLL_JOB_ID=$FM_REMOTE_JOB_ID
POLL_JOB_DIR="$STATE_ROOT/jobs/$POLL_JOB_ID"
wait_until job_in_state "$POLL_JOB_DIR" running \
  || fail "the long-poll job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$PREEMPT_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] \
  || fail "the short command behind a long poll did not complete inside its queue window (exit $FM_REMOTE_JOB_EXIT): it waited behind the poll"
assert_present "$PREEMPT_SIDE_EFFECT" "the short command behind a long poll did not run"
fm_remote_job_wait "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "a preempted long poll was not distinguished from an elapsed window"
[ ! -s "$FM_REMOTE_JOB_STDOUT" ] || fail "a preempted long poll published partial stdout"
[ ! -s "$FM_REMOTE_JOB_STDERR" ] || fail "a preempted long poll published partial stderr"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the short command could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "the preempted poll could not be reaped"
pass "a queued short command preempts a running long poll instead of waiting its window"

printf 'hello after preemption\n' > "$REMOTE_HOME/$REPLY_LOG_REL"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 5 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the re-armed poll after preemption did not complete"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" 'status=delta' "the re-armed poll did not return a delta from the preserved cursor"
assert_contains "$OUT" 'hello after preemption' "the re-armed poll lost data appended around the preemption"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the re-armed poll could not be reaped"
rm -f -- "$REMOTE_HOME/$REPLY_LOG_REL"
pass "a poll re-armed after preemption reads the same cursor with nothing lost"

FM_REMOTE_JOB_TIMEOUT=15
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 6 < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
wait_until job_in_state "$FIRST_JOB_DIR" running \
  || fail "the first sibling poll did not begin running"
POLL_PAIR_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 1 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
POLL_PAIR_ELAPSED=$(( $(date +%s) - POLL_PAIR_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the first sibling poll did not close its own window"
[ "$POLL_PAIR_ELAPSED" -ge 4 ] || fail "a queued sibling poll preempted a running poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the queued sibling poll did not run after the first window"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first sibling poll could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the queued sibling poll could not be reaped"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
pass "sibling polls never preempt each other into a re-arm churn loop"

STARTED="$TMP_ROOT/shutdown-started"
SHUTDOWN_SIDE_EFFECT="$TMP_ROOT/shutdown-side-effect"
SHUTDOWN_RELEASE="$TMP_ROOT/shutdown-release"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$STARTED" "$SHUTDOWN_SIDE_EFFECT" "$SHUTDOWN_RELEASE" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
wait_until test -s "$STARTED" || fail "the shutdown fixture did not begin executing"
SHUTDOWN_COMMAND_PID=$(cat "$STARTED")
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait_until process_gone "$WORKER_PID" || fail "the worker did not finish its TERM shutdown"
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=1 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err" &
wait_until test -f "$STATE_ROOT/worker.ready" || fail "the replacement worker did not become ready"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "the interrupted job did not publish an unknown-completion result"
wait_until process_gone "$SHUTDOWN_COMMAND_PID" \
  || fail "worker shutdown left the active command $SHUTDOWN_COMMAND_PID running"
: > "$SHUTDOWN_RELEASE"
assert_absent "$SHUTDOWN_SIDE_EFFECT" "the active command mutated after worker shutdown"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the interrupted job could not be reaped"
pass "worker shutdown terminates the active command tree before replacement"

CRASH_STARTED="$TMP_ROOT/crash-started"
CRASH_SIDE_EFFECT="$TMP_ROOT/crash-side-effect"
CRASH_RELEASE="$TMP_ROOT/crash-release"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$CRASH_STARTED" "$CRASH_SIDE_EFFECT" "$CRASH_RELEASE" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
wait_until test -s "$CRASH_STARTED" || fail "the crash fixture did not begin executing"
CRASH_COMMAND_PID=$(cat "$CRASH_STARTED")
CRASHED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -KILL "$CRASHED_WORKER_PID"
wait_until worker_pid_replaced "$CRASHED_WORKER_PID" \
  || fail "the Linux supervisor did not restart a crashed worker"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "worker crash recovery did not publish unknown completion"
wait_until process_gone "$CRASH_COMMAND_PID" \
  || fail "worker crash recovery left the orphaned command $CRASH_COMMAND_PID running"
: > "$CRASH_RELEASE"
assert_absent "$CRASH_SIDE_EFFECT" "an orphaned command mutated after worker crash recovery"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the crash-recovered job could not be reaped"
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the restarted worker did not remain ready"
pass "Linux supervision recovers crashes and stops orphaned commands"

mkdir -p "$ACCOUNT_HOME/.local/bin"
PREEXEC_STARTED="$TMP_ROOT/preexecution-started"
PREEXEC_FINISHED="$TMP_ROOT/preexecution-finished"
# The stub hangs tracked-command validation (git ls-files) for longer than any
# wait below can last, so only the worker's own job deadline can end it. Its start
# marker records its pid.
cat > "$ACCOUNT_HOME/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  printf '%s\n' "\$\$" > "$PREEXEC_STARTED"
  sleep 200
  printf 'finished\n' > "$PREEXEC_FINISHED"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$ACCOUNT_HOME/.local/bin/git"
# The first run of a freshly written executable costs about a second on macOS, so
# pay it here, outside any job's budget.
"$ACCOUNT_HOME/.local/bin/git" --version > /dev/null
# A job's execution deadline is wall-clock time from its claim, and tracked-command
# validation starts only after the lane process has spawned, composed its PATH,
# and launched the stub. How long that takes depends on host load: a budget the
# host cannot reach validation within publishes 124 before validation is ever
# entered, which says nothing about validation. So the case is established, not
# assumed: widen the budget until the job's validation was entered, then assert on
# that run. A host that cannot enter validation even with the widest budget fails
# here with that fact.
# The queue window is an hour, so a worker that bounded validation by it rather
# than by the job's own timeout could not finish inside the wait below.
SAVED_TIMEOUT=$FM_REMOTE_JOB_TIMEOUT
SAVED_QUEUE_TIMEOUT=$FM_REMOTE_JOB_QUEUE_TIMEOUT
FM_REMOTE_JOB_QUEUE_TIMEOUT=3600
PREEXEC_BUDGET=3
while :; do
  rm -f -- "$PREEXEC_STARTED"
  FM_REMOTE_JOB_TIMEOUT=$PREEXEC_BUDGET
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
  JOB_ID=$FM_REMOTE_JOB_ID
  # The wait is the job's budget plus the hang guard, and neither the stub nor
  # the queue window can end inside it, so a job that completes in time had its
  # hung validation ended at the job's own deadline.
  PREEXEC_DEADLINE=$((SECONDS + PREEXEC_BUDGET + EVENT_WAIT_SECONDS))
  until job_in_state "$STATE_ROOT/jobs/$JOB_ID" 'done'; do
    [ "$SECONDS" -lt "$PREEXEC_DEADLINE" ] \
      || fail "tracked-command validation was not bounded by the ${PREEXEC_BUDGET}s job timeout"
    sleep 0.05
  done
  fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
  [ "$FM_REMOTE_JOB_EXIT" -eq 124 ] \
    || fail "the pre-execution deadline did not publish a timeout result (exit $FM_REMOTE_JOB_EXIT)"
  [ ! -e "$PREEXEC_STARTED" ] || break
  fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the unentered pre-execution job could not be reaped"
  [ "$PREEXEC_BUDGET" -lt 48 ] \
    || fail "the pre-execution timeout fixture did not enter tracked-command validation within a ${PREEXEC_BUDGET}s budget"
  PREEXEC_BUDGET=$((PREEXEC_BUDGET * 4))
done
FM_REMOTE_JOB_TIMEOUT=$SAVED_TIMEOUT
FM_REMOTE_JOB_QUEUE_TIMEOUT=$SAVED_QUEUE_TIMEOUT
assert_present "$PREEXEC_STARTED" "the pre-execution timeout fixture did not enter tracked-command validation"
wait_until process_gone "$(cat "$PREEXEC_STARTED")" \
  || fail "tracked-command validation was still running after the job timeout"
assert_absent "$PREEXEC_FINISHED" "tracked-command validation continued after the job timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the pre-execution timeout leaked output readers or FIFOs"
rm -f -- "$ACCOUNT_HOME/.local/bin/git"
pass "pre-execution validation obeys the job timeout"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-output-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 23 ] || fail "bounded output changed the command exit status"
OUTPUT_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')
[ "$OUTPUT_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained output beyond its byte bound"
ERROR_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDERR" | tr -d ' ')
[ "$ERROR_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained stderr beyond its byte bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the bounded-output job could not be reaped"
pass "the worker drains bounded output without changing command results"

SIDE_EFFECT="$TMP_ROOT/side-effect"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_stop_worker_tree "$WORKER_PID" \
  || fail "the worker tree did not stop before the staged-record tamper"
assert_absent "$STATE_ROOT/worker.pid" "the worker did not clear its pid before the staged-record tamper"
# The worker checks the queue deadline before it validates argv, and this job
# waits for a freshly started worker. Its queue window is a hang guard, so a
# starved host that is slow to start the worker cannot expire the job (124)
# before the symlink refusal (126) is reached.
SAVED_QUEUE_TIMEOUT=$FM_REMOTE_JOB_QUEUE_TIMEOUT
FM_REMOTE_JOB_QUEUE_TIMEOUT=600
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
FM_REMOTE_JOB_QUEUE_TIMEOUT=$SAVED_QUEUE_TIMEOUT
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
rm -f -- "$JOB_DIR/argv"
ln -s "$TMP_ROOT/not-an-argv" "$JOB_DIR/argv"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 126 ] \
  || fail "the worker accepted a symlinked argv record (exit $FM_REMOTE_JOB_EXIT, expected 126)"
assert_absent "$SIDE_EFFECT" "the worker executed a job after its argv changed to a symlink"
pass "the worker refuses symlinked job fields before command execution"

QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
QUARANTINE_RELEASE="$TMP_ROOT/quarantine-release"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" "$QUARANTINE_RELEASE" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
wait_until test -s "$QUARANTINE_STARTED" || fail "the quarantine fixture did not begin executing"
QUARANTINE_COMMAND_PID=$(cat "$QUARANTINE_STARTED")
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
wait_until test -f "$STATE_ROOT/worker.lock/quarantine" || fail "failed shutdown released worker ownership"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
wait_until process_gone "$QUARANTINE_COMMAND_PID" \
  || fail "explicit termination left the quarantined command $QUARANTINE_COMMAND_PID running"
: > "$QUARANTINE_RELEASE"
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"

RECOVERY_HOME="$TMP_ROOT/recovery-account"
RECOVERY_STATE="$TMP_ROOT/recovery-jobs"
RECOVERY_JOB="$RECOVERY_STATE/jobs/job-quarantine"
mkdir -p "$RECOVERY_HOME" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB/.claim"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_STATE" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB" "$RECOVERY_JOB/.claim"
sleep 20 &
QUARANTINED_PROCESS_PID=$!
sleep 0.01 &
QUARANTINE_OWNER_PID=$!
wait "$QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_STATE/worker.lock/pid"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/start"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$RECOVERY_STATE/worker.lock/quarantine"
printf 'running\n' > "$RECOVERY_JOB/state"
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_JOB/.claim/owner"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/supervisor"
: > "$RECOVERY_JOB/stdout"
: > "$RECOVERY_JOB/stderr"
chmod 600 "$RECOVERY_STATE/worker.lock"/* "$RECOVERY_JOB/state" "$RECOVERY_JOB/.claim"/* \
  "$RECOVERY_JOB/stdout" "$RECOVERY_JOB/stderr"
touch -t 200001010000 "$RECOVERY_STATE/worker.lock"
set +e
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-refused.out" 2> "$TMP_ROOT/recovery-refused.err"
RECOVERY_REFUSED_RC=$?
set -e
[ "$RECOVERY_REFUSED_RC" -ne 0 ] || fail "quarantine recovery ignored a recorded live process"
assert_present "$RECOVERY_STATE/worker.lock/quarantine" "a live recorded process lost quarantine protection"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/owner"
printf 'stale owner identity\n' > "$RECOVERY_JOB/.claim/owner_start"
printf 'stale supervisor identity\n' > "$RECOVERY_JOB/.claim/supervisor_start"
chmod 600 "$RECOVERY_JOB/.claim/owner" "$RECOVERY_JOB/.claim/owner_start" \
  "$RECOVERY_JOB/.claim/supervisor_start"
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-worker.out" 2> "$TMP_ROOT/recovery-worker.err" &
RECOVERY_WORKER_PID=$!
wait_until test -f "$RECOVERY_STATE/worker.ready" || fail "a reused supervisor pid did not permit worker recovery"
assert_absent "$RECOVERY_STATE/worker.lock/quarantine" "recovered worker retained stale quarantine"
kill -0 "$QUARANTINED_PROCESS_PID" 2>/dev/null \
  || fail "worker recovery signalled a process whose supervisor identity did not match"
kill -TERM "$RECOVERY_WORKER_PID"
wait "$RECOVERY_WORKER_PID" 2>/dev/null || true
RECOVERY_WORKER_PID=
kill "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
wait "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
pass "quarantine recovery refuses unverifiable supervisors and ignores reused pids"

# A replacement stops a Linux worker by signalling its whole isolated group, and
# the supervisor in that group forwards a second stop signal to the same serving
# child, so the serving child is always signalled more than once. Signal a small
# bounded burst and then keep signalling until it is gone: the first signal
# starts the shutdown and every later one lands inside it, the same way the group
# signal and the forwarded signal do. A shutdown that dies part way through
# leaves its ownership lock behind holding a half-written temp file no later
# worker can clear, and every replacement then fails to report ready.
#
# The burst is bounded and the follow-up signals are paced deliberately. An
# unpaced signal loop delivers hundreds of thousands of signals per second,
# which corrupts the signalled bash's own pending-trap bookkeeping ("warning:
# run_pending_traps: bad value in trap_list[15]") and then kills it part way
# through the shutdown with SIGTERM or SIGSEGV. That reports a shutdown defect
# this worker does not have. Ten back-to-back signals still all land inside the
# shutdown's first file operation, so the repeat this pins is unchanged: with
# the default disposition restored instead of ignored, the ownership lock is
# left behind every run.
REPEAT_HOME="$TMP_ROOT/repeat-signal-account"
REPEAT_STATE="$TMP_ROOT/repeat-signal-jobs"
mkdir -p "$REPEAT_HOME"
chmod 700 "$REPEAT_HOME"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/repeat-signal.out" 2> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
wait_until test -f "$REPEAT_STATE/worker.ready" || fail "the repeated-signal worker did not become ready"
REPEAT_DEADLINE=$((SECONDS + EVENT_WAIT_SECONDS + 1))
REPEAT_BURST=0
while [ "$REPEAT_BURST" -lt 10 ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_BURST=$((REPEAT_BURST + 1))
done
while kill -0 "$REPEAT_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$REPEAT_DEADLINE" ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  sleep 0.05
done
if kill -0 "$REPEAT_WORKER_PID" 2>/dev/null; then
  kill -KILL "$REPEAT_WORKER_PID" 2>/dev/null || true
  wait "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_WORKER_PID=
  fail "the repeatedly signalled worker never finished its shutdown"
fi
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
assert_absent "$REPEAT_STATE/worker.lock" \
  "a repeatedly signalled shutdown left its ownership lock behind"
assert_absent "$REPEAT_STATE/worker.ready" \
  "a repeatedly signalled shutdown left its readiness heartbeat behind"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  >> "$TMP_ROOT/repeat-signal.out" 2>> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
wait_until test -f "$REPEAT_STATE/worker.ready" \
  || fail "the worker after a repeatedly signalled shutdown never reported ready"
kill -TERM "$REPEAT_WORKER_PID"
REPEAT_DEADLINE=$((SECONDS + EVENT_WAIT_SECONDS + 1))
while kill -0 "$REPEAT_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$REPEAT_DEADLINE" ]; do
  sleep 0.05
done
if kill -0 "$REPEAT_WORKER_PID" 2>/dev/null; then
  kill -KILL "$REPEAT_WORKER_PID" 2>/dev/null || true
  wait "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_WORKER_PID=
  fail "the replacement worker never finished its TERM shutdown"
fi
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
pass "a repeatedly signalled shutdown still releases ownership for the next worker"

# A child that stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears the
# consecutive-failure backoff, so a child that dies just past that threshold
# used to reset the only guard the supervisor had and restart forever. The
# fixture below is that worker: it exits non-zero after living just longer than
# the healthy window, so every restart is accounted as healthy-then-failed.
RESTART_ROOT="$TMP_ROOT/restart-root"
RESTART_HOME="$TMP_ROOT/restart-account"
RESTART_STATE="$TMP_ROOT/restart-state"
RESTART_CHILD_LOG="$TMP_ROOT/restart-children"
mkdir -p "$RESTART_ROOT/bin" "$RESTART_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$RESTART_ROOT/bin/"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh"
printf 'fixture\n' > "$RESTART_ROOT/AGENTS.md"
cat > "$RESTART_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
set -u
[ "${1:-}" = --serve ] || exit 2
printf '%s\n' "${BASHPID:-$$}" >> "$FM_TEST_SUPERVISOR_CHILD_LOG"
sleep "$FM_TEST_SUPERVISOR_CHILD_SECONDS"
exit "$FM_TEST_SUPERVISOR_CHILD_STATUS"
SH
chmod +x "$RESTART_ROOT/bin"/*.sh
HOME="$RESTART_HOME" FM_ROOT_OVERRIDE="$RESTART_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RESTART_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS=1 FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=3 \
  FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=0 FM_TEST_SUPERVISOR_CHILD_LOG="$RESTART_CHILD_LOG" \
  FM_TEST_SUPERVISOR_CHILD_SECONDS=1.1 FM_TEST_SUPERVISOR_CHILD_STATUS=1 \
  "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh" \
  > "$TMP_ROOT/restart-supervisor.out" 2> "$TMP_ROOT/restart-supervisor.err" &
RESTART_SUPERVISOR_PID=$!
wait_until process_gone "$RESTART_SUPERVISOR_PID" \
  || fail "workers dying just past the healthy threshold drove an unbounded restart loop"
set +e
wait "$RESTART_SUPERVISOR_PID"
RESTART_SUPERVISOR_RC=$?
set -e
RESTART_SUPERVISOR_PID=
[ "$RESTART_SUPERVISOR_RC" -ne 0 ] || fail "the exhausted restart guard reported success"
[ "$(wc -l < "$RESTART_CHILD_LOG" | tr -d ' ')" -eq 3 ] \
  || fail "the restart guard did not stop at the configured maximum"
assert_grep "remote job worker exited 3 times; stopping the supervisor" "$TMP_ROOT/restart-supervisor.err" \
  "the restart guard did not explain why it stopped"
pass "barely healthy worker failures remain bounded by the restart guard"

echo "ALL TESTS PASSED"
