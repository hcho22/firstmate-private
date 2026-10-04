#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_startup_timeout_releases_an_acquired_lock() {
  local home fakebin out err status real_ln
  home=$(make_home startup-timeout)
  fakebin="$home/fakebin"
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir -p "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
"$REAL_LN" "$@"
for last do :; done
case "$last" in
  */.watch.lock) sleep 3 ;;
esac
SH
  chmod 0700 "$fakebin/ln"

  status=0
  REAL_LN="$real_ln" PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "startup-timeout checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "startup-timeout checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" \
    "watch lock pid survived an interruption during acquisition"
  pass "startup timeout releases a lock acquired before watcher initialization completes"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  # The wake is written once the watcher has begun polling, however long a loaded
  # host takes to start it, and the checkpoint's bound is only a hang guard.
  (
    deadline=$((SECONDS + 60))
    while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 60 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 60 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# Hosts with neither timeout nor gtimeout (stock macOS) use the perl fallback. GNU
# timeout never follows TERM with KILL, so the watcher always finishes its exit
# cleanup; the fallback used to KILL it 0.2 s after TERM, which cut the cleanup
# short on a slow host and left the watch lock behind. A stub watcher whose
# cleanup deliberately takes a full second shows the difference without depending
# on how fast the host is.
test_perl_fallback_lets_the_watcher_finish_its_cleanup() {
  local home root toolbin tool real status out
  home=$(make_home perl-fallback)
  root="$home/root"
  toolbin="$home/toolbin"
  out="$home/out.txt"
  mkdir -p "$root/bin" "$toolbin"
  cp "$CHECKPOINT" "$root/bin/fm-watch-checkpoint.sh"
  cat > "$root/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --warm ] || exit 0
trap 'sleep 1; : > "$FM_FIXTURE/cleaned"; exit 143' TERM
: > "$FM_FIXTURE/started"
while :; do sleep 0.05; done
SH
  chmod +x "$root/bin/fm-watch-checkpoint.sh" "$root/bin/fm-watch.sh"
  # The first run of a freshly written executable is slow on macOS (about a second
  # and a half); run the stub once now so the checkpoint's own bound cannot expire
  # before the stub has started.
  "$root/bin/fm-watch.sh" --warm
  for tool in bash env mktemp grep cat rm dirname perl sleep; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for the perl-fallback path: $tool"
    ln -s "$real" "$toolbin/$tool"
  done
  [ ! -e "$toolbin/timeout" ] && [ ! -e "$toolbin/gtimeout" ] || fail "the fixture PATH still offers a timeout command"
  status=0
  PATH="$toolbin" FM_FIXTURE="$home" "$root/bin/fm-watch-checkpoint.sh" --seconds 15 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "perl-fallback checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 15s" "perl-fallback checkpoint line missing"
  assert_present "$home/started" "the stub watcher never started"
  assert_present "$home/cleaned" "the perl fallback ended the watcher before its exit cleanup finished"
  pass "the perl fallback lets the watcher finish its exit cleanup after TERM"
}

test_quiet_checkpoint_exits_124_cleanly
test_startup_timeout_releases_an_acquired_lock
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_perl_fallback_lets_the_watcher_finish_its_cleanup
