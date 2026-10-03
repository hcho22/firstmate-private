#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

test_lock_held_by_other_and_displaced_record_decisions() {
  local dir fakebin
  dir="$TMP_ROOT/held-by-other"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' codex ;;
  600:args=) printf '%s\n' 'codex app-server --listen unix:// --managed-daemon' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' "${FM_TEST_LEAF_PARENT:-650}" ;;
esac
SH
  chmod +x "$fakebin/ps"

  # held_by_other: a live foreign harness holds the lock, and this process's own
  # harness (650) is not it.
  printf '600\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'" \
    || fail "a live foreign holder was not reported as holding the lock against this session"
  printf '650\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'"; then
    fail "the session's own lock was reported as held by another"
  fi
  printf '777\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'"; then
    fail "a holder that is not a live harness was reported as holding the lock against this session"
  fi
  printf 'junk\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'"; then
    fail "a malformed lock was reported as held by another"
  fi
  rm -f "${dir:?}/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'"; then
    fail "an absent lock was reported as held by another"
  fi
  # Uncertainty keeps the guard: with no harness anywhere in this process's
  # ancestry the session cannot prove it is the one locked out.
  printf '600\n' > "$dir/state/.lock"
  if FM_TEST_LEAF_PARENT=1 lib_eval "$fakebin" "fm_session_lock_held_by_other '$dir/state'"; then
    fail "a session with no locatable harness ancestry was treated as lock-refused"
  fi

  # displaced_record: only the session that descends from the displaced pid, and
  # only while the takeover's new pid still holds the lock.
  printf '600\n' > "$dir/state/.lock"
  printf 'at=2026-10-01T20:00:00Z\tnew_pid=600\tnew_command=codex\tprev_pid=650\tprev_holder=command: claude\n' > "$dir/state/.lock-takeovers"
  lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state' | grep -q 'new_pid=600'" \
    || fail "the displaced session did not find the takeover record that displaced it"
  printf 'at=2026-10-01T20:00:00Z\tnew_pid=600\tnew_command=codex\tprev_pid=111\tprev_holder=command: claude\n' > "$dir/state/.lock-takeovers"
  if lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state'"; then
    fail "a session that was not the displaced pid was told it was displaced"
  fi
  printf 'at=2026-10-01T20:00:00Z\tnew_pid=999\tnew_command=codex\tprev_pid=650\tprev_holder=command: claude\n' > "$dir/state/.lock-takeovers"
  if lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state'"; then
    fail "a takeover whose new pid no longer holds the lock was reported as the current displacement"
  fi
  pass "session-lock: lock-refused and displaced decisions follow the lock holder and this session's own harness"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-}
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- takeover layer: a live holder is never displaced automatically ---------
#
# The reproduced incident: an idle `codex app-server --managed-daemon` held the
# lock after its conversation had stopped supervising, and every later session
# started read-only. A live pid cannot prove whether it hosts a working session or
# an idle service, so these cases pin the captain-decided contract with REAL
# processes: a refused session is told who holds the lock and the one takeover
# command, nothing displaces a live holder without the explicit confirmation, and
# a displaced session finds itself read-only. Each "session" is a long-lived
# process named like its harness that runs commands handed to it over a fifo, so
# the same pid acts on its home more than once, exactly like a real session.

CODEX_BIN="$FAKEBIN/codex"
ln -sf /bin/bash "$CODEX_BIN"

# Every fake session this suite starts, so a failing case can never leave one
# running (a leftover session keeps the suite's output pipe open for ever).
SESSION_PIDS=()
cleanup_sessions() {
  local pid
  for pid in "${SESSION_PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_sessions; fm_test_cleanup' EXIT
trap 'cleanup_sessions; fm_test_cleanup; exit 130' INT
trap 'cleanup_sessions; fm_test_cleanup; exit 143' TERM

# The loop every fake session runs: take one command line at a time from its
# fifo, run it inside this very process, and publish its output and status.
SESSION_LOOP_FILE="$TMP_ROOT/session-loop.sh"
cat > "$SESSION_LOOP_FILE" <<'SH'
while :; do
  IFS= read -r cmd < "$SESSION_FIFO" || exit 0
  [ "$cmd" != exit ] || exit 0
  rm -f "${SESSION_BASE:?}.done"
  eval "$cmd" > "$SESSION_BASE.out" 2>&1
  echo "$?" > "$SESSION_BASE.rc"
  : > "$SESSION_BASE.done"
done
SH

# session_start <dir> <name> <harness-bin> [extra argv shown in ps]
# Sets SESSION_PID. The process is started by a short relative path with a short
# script so its ps command line stays readable, and the extra argv lets the
# idle-daemon case carry the real daemon's command line (app-server --listen
# unix:// --managed-daemon).
session_start() {
  local dir=$1 name=$2 bin=$3 back=$PWD
  shift 3
  mkfifo "$dir/$name.fifo"
  cd "$(dirname "$bin")" || fail "cannot enter the fake harness directory"
  FM_HOME="$dir" SESSION_FIFO="$dir/$name.fifo" SESSION_BASE="$dir/$name" SESSION_LOOP="$SESSION_LOOP_FILE" \
    "./$(basename "$bin")" -c '. "$SESSION_LOOP"' session "$@" >/dev/null 2>&1 &
  SESSION_PID=$!
  cd "$back" || fail "cannot return to the suite directory"
  SESSION_PIDS+=("$SESSION_PID")
}

# session_run <dir> <name> <command>: run it inside that session's process.
# Sets SESSION_OUT and SESSION_RC.
session_run() {
  local dir=$1 name=$2 cmd=$3 i=0
  rm -f "${dir:?}/${name:?}.done"
  printf '%s\n' "$cmd" > "$dir/$name.fifo"
  while [ "$i" -lt 400 ] && [ ! -e "$dir/$name.done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/$name.done" ] || fail "session $name never finished: $cmd"
  SESSION_OUT=$(cat "$dir/$name.out")
  SESSION_RC=$(tr -d '[:space:]' < "$dir/$name.rc")
}

session_stop() {  # <dir> <name> <pid>
  printf 'exit\n' > "$1/$2.fifo" 2>/dev/null || true
  wait "$3" 2>/dev/null || true
}

# A home with an idle codex app-server daemon holding the lock, and a second
# session (a claude) that has not yet tried to take it. Sets DAEMON_PID and
# CLAUDE_PID; the caller stops both.
make_idle_daemon_home() {  # <dir>
  local dir=$1
  make_primary_home "$dir"
  rm -f "${dir:?}/state/task.meta"
  session_start "$dir" daemon "$CODEX_BIN" app-server --listen unix:// --managed-daemon
  DAEMON_PID=$SESSION_PID
  session_run "$dir" daemon '"$FM_HOME/bin/fm-lock.sh"'
  [ "$SESSION_RC" = 0 ] || fail "the daemon-hosted session could not take the lock: $SESSION_OUT"
  # The conversation is long gone: the lock is hours old and nothing beats.
  touch -t 202610010900 "$dir/state/.lock"
  session_start "$dir" claude "$NAMED_CLAUDE"
  CLAUDE_PID=$SESSION_PID
}

stop_idle_daemon_home() {  # <dir>
  session_stop "$1" claude "$CLAUDE_PID"
  session_stop "$1" daemon "$DAEMON_PID"
}

test_live_idle_holder_is_named_and_never_displaced_automatically() {
  local dir
  dir="$TMP_ROOT/takeover-refusal"
  make_idle_daemon_home "$dir"
  session_run "$dir" claude '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 1 "$SESSION_RC" "a live holder must refuse a second session, however idle it looks"
  assert_contains "$SESSION_OUT" "another live firstmate session holds the lock (pid $DAEMON_PID)" "the stable first diagnostic line changed"
  assert_contains "$SESSION_OUT" "holder: pid $DAEMON_PID, command:" "the refusal did not name the holder's pid and command"
  assert_contains "$SESSION_OUT" "app-server --listen unix:// --managed-daemon" "the refusal did not show what the holder is running"
  assert_contains "$SESSION_OUT" "holding the lock since 2026-" "the refusal did not say when the holder took the lock"
  assert_contains "$SESSION_OUT" "fm-lock.sh takeover --confirm-holder $DAEMON_PID" "the refusal did not print the one explicit takeover command"
  assert_contains "$SESSION_OUT" "Only with the captain's OK" "the refusal must say the takeover needs the captain's OK"
  [ "$(cat "$dir/state/.lock")" = "$DAEMON_PID" ] || fail "an idle live holder was displaced without a takeover"
  session_run "$dir" claude '"$FM_HOME/bin/fm-lock.sh" status'
  assert_contains "$SESSION_OUT" "lock: held by live harness pid $DAEMON_PID (command:" "status lost its stable prefix or the holder's command"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: a live idle holder is named with its command and age and is never displaced automatically"
}

test_takeover_requires_explicit_confirmation_of_the_current_holder() {
  local dir
  dir="$TMP_ROOT/takeover-confirmation"
  make_idle_daemon_home "$dir"
  session_run "$dir" claude '"$FM_HOME/bin/fm-lock.sh" takeover'
  expect_code 2 "$SESSION_RC" "takeover without the confirmation flag must be refused as a usage error"
  assert_contains "$SESSION_OUT" "--confirm-holder" "the refusal did not name the confirmation flag"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder=$DAEMON_PID"
  expect_code 2 "$SESSION_RC" "only the documented --confirm-holder <pid> spelling may confirm a takeover"
  assert_contains "$SESSION_OUT" "usage: fm-lock.sh takeover --confirm-holder <pid>" "an undocumented spelling did not get the usage line"
  [ "$(cat "$dir/state/.lock")" = "$DAEMON_PID" ] || fail "an undocumented confirmation spelling displaced the holder"
  session_run "$dir" claude '"$FM_HOME/bin/fm-lock.sh" takeover --confirm-holder 1'
  expect_code 1 "$SESSION_RC" "a confirmation naming a different pid must not displace the holder"
  assert_contains "$SESSION_OUT" "not the confirmed pid 1" "the stale-confirmation refusal did not explain itself"
  [ "$(cat "$dir/state/.lock")" = "$DAEMON_PID" ] || fail "an unconfirmed takeover displaced the holder"
  assert_absent "$dir/state/.lock-takeovers" "a refused takeover left a record"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: refuses without the flag, for an undocumented spelling, and when the confirmed pid is not the current holder"
}

test_takeover_refuses_while_a_watcher_beat_is_fresh() {
  local dir
  dir="$TMP_ROOT/takeover-fresh-beat"
  make_idle_daemon_home "$dir"
  touch "$dir/state/.last-watcher-beat"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  expect_code 1 "$SESSION_RC" "a fresh watcher beat means a live session is supervising; takeover must refuse"
  assert_contains "$SESSION_OUT" "watcher beat is fresh" "the refusal did not name the fresh watcher beat"
  [ "$(cat "$dir/state/.lock")" = "$DAEMON_PID" ] || fail "takeover displaced a holder whose watcher was beating"
  assert_absent "$dir/state/.lock-takeovers" "a refused takeover left a record"
  # A beat older than the grace window no longer protects the holder.
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  expect_code 0 "$SESSION_RC" "a stale beat must not block a confirmed takeover: $SESSION_OUT"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: a fresh watcher beat blocks it and a stale beat does not"
}

test_confirmed_takeover_records_who_replaced_whom_and_keeps_the_lock_format() {
  local dir record
  dir="$TMP_ROOT/takeover-record"
  make_idle_daemon_home "$dir"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  expect_code 0 "$SESSION_RC" "a confirmed takeover of an idle holder must succeed: $SESSION_OUT"
  assert_contains "$SESSION_OUT" "lock taken over: harness pid $CLAUDE_PID replaced pid $DAEMON_PID" "the takeover did not report who replaced whom"
  assert_contains "$SESSION_OUT" "was not signalled" "the takeover must state that it never signals the previous holder"
  assert_contains "$SESSION_OUT" "must stop acting on the fleet now" "the takeover must tell the captain the displaced session has to stop acting"
  # Backward compatibility: the lock is still ONE bare numeric line that every
  # older reader parses unchanged, and the previous holder was left running.
  [ "$(cat "$dir/state/.lock")" = "$CLAUDE_PID" ] || fail "the lock does not name the new holder"
  [ "$(wc -l < "$dir/state/.lock" | tr -d ' ')" = 1 ] || fail "the lock file is no longer a single line"
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "takeover signalled or killed the previous holder"
  [ "$(wc -l < "$dir/state/.lock-takeovers" | tr -d ' ')" = 1 ] || fail "expected exactly one takeover record"
  record=$(cat "$dir/state/.lock-takeovers")
  assert_contains "$record" "new_pid=$CLAUDE_PID" "the record did not name the new holder"
  assert_contains "$record" "prev_pid=$DAEMON_PID" "the record did not name the previous holder"
  assert_contains "$record" "app-server --listen unix:// --managed-daemon" "the record did not keep what the previous holder was running"
  assert_contains "$record" "at=20" "the record did not carry a timestamp"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  expect_code 0 "$SESSION_RC" "repeating a takeover the session already completed must be a no-op"
  [ "$(wc -l < "$dir/state/.lock-takeovers" | tr -d ' ')" = 1 ] || fail "a repeated takeover appended a second record"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: records who replaced whom, keeps the one-line lock, and never signals the previous holder"
}

# The captain's own terminal: an ordinary shell with no firstmate session in its
# ancestry. The process is orphaned before it runs the takeover, so the ancestry
# walk cannot escape into the session running this suite.
test_takeover_outside_any_session_says_where_to_run_it() {
  local dir i out
  dir="$TMP_ROOT/takeover-plain-terminal"
  make_idle_daemon_home "$dir"
  cat > "$dir/terminal.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
"$FM_HOME/bin/fm-lock.sh" takeover --confirm-holder "$1" > "$FM_HOME/terminal.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/terminal.rc"
SH
  FM_HOME="$dir" bash -c 'bash "$0" "$1" &' "$dir/terminal.sh" "$DAEMON_PID"
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/terminal.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/terminal.rc" ] || { stop_idle_daemon_home "$dir"; fail "the plain-terminal takeover never finished"; }
  out=$(cat "$dir/terminal.out")
  expect_code 1 "$(tr -d '[:space:]' < "$dir/terminal.rc")" "a takeover with no firstmate session to hand the lock to must refuse"
  assert_contains "$out" "a takeover must be run by the firstmate session that will take the lock" "the refusal did not say where the takeover must run"
  [ "$(cat "$dir/state/.lock")" = "$DAEMON_PID" ] || fail "a takeover from outside any session displaced the holder"
  assert_absent "$dir/state/.lock-takeovers" "a refused takeover left a record"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: run outside any firstmate session it refuses and says the session that will take the lock must run it"
}

test_displaced_session_is_read_only_at_its_next_lock_checks() {
  local dir
  dir="$TMP_ROOT/takeover-displaced"
  make_idle_daemon_home "$dir"
  : > "$dir/state/task.meta"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $DAEMON_PID"
  expect_code 0 "$SESSION_RC" "setup takeover failed: $SESSION_OUT"
  # The displaced session re-checks the lock the only ways the fleet's guarded
  # paths do today: it is refused on re-acquiring, no longer recognizes itself as
  # the owner, and its Stop auto-arm stays inert instead of arming or rewaking.
  session_run "$dir" daemon '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 1 "$SESSION_RC" "the displaced session must be refused when it re-checks the lock"
  assert_contains "$SESSION_OUT" "holds the lock (pid $CLAUDE_PID)" "the displaced session was not told who holds the lock now"
  session_run "$dir" daemon '. "$FM_HOME/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$FM_HOME/state"'
  expect_code 1 "$SESSION_RC" "the displaced session still recognizes itself as the lock owner"
  session_run "$dir" daemon '"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null'
  expect_code 0 "$SESSION_RC" "a displaced session's Stop auto-arm must exit silently"
  [ ! -e "$dir/state/arm-ran" ] || fail "a displaced session armed supervision"
  [ "$(cat "$dir/state/.lock")" = "$CLAUDE_PID" ] || fail "the displaced session took the lock back"
  stop_idle_daemon_home "$dir"
  pass "session-lock takeover: a displaced session is refused, stops recognizing itself as owner, and its auto-arm stays inert"
}

test_dead_holder_is_still_reclaimed_automatically() {
  local dir dead
  dir="$TMP_ROOT/takeover-dead-holder"
  make_primary_home "$dir"
  rm -f "${dir:?}/state/task.meta"
  dead=999991
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$dir/state/.lock"
  session_start "$dir" claude "$NAMED_CLAUDE"
  session_run "$dir" claude '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 0 "$SESSION_RC" "a dead holder's lock must still be reclaimed with no flag: $SESSION_OUT"
  [ "$(cat "$dir/state/.lock")" = "$SESSION_PID" ] || fail "the stale lock was not replaced by the new session"
  assert_absent "$dir/state/.lock-takeovers" "an automatic stale-lock reclaim was recorded as a takeover"
  session_run "$dir" claude "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $dead"
  expect_code 0 "$SESSION_RC" "takeover over our own lock should be a harmless no-op"
  session_stop "$dir" claude "$SESSION_PID"
  pass "session-lock takeover: a dead holder's stale lock is reclaimed automatically exactly as before"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_lock_held_by_other_and_displaced_record_decisions
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_live_idle_holder_is_named_and_never_displaced_automatically
test_takeover_requires_explicit_confirmation_of_the_current_holder
test_takeover_refuses_while_a_watcher_beat_is_fresh
test_confirmed_takeover_records_who_replaced_whom_and_keeps_the_lock_format
test_takeover_outside_any_session_says_where_to_run_it
test_displaced_session_is_read_only_at_its_next_lock_checks
test_dead_holder_is_still_reclaimed_automatically
