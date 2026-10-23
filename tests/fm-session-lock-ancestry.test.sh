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
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
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

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
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
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
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

# The lock-refused verdict the turn-end guard stands down on
# (fm_session_lock_foreign_owner_live) and the displaced-session record, behind a
# process table with an idle codex daemon (600) holding the lock, this session's
# own claude (650), and, under FM_TEST_CLAUDE_PARENT=660, a non-harness gap (660)
# between 650 and an outer claude (670).
test_foreign_owner_and_displaced_record_decisions() {
  local dir fakebin got
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
  650:ppid=) printf '%s\n' "${FM_TEST_CLAUDE_PARENT:-1}" ;;
  660:comm=) printf '%s\n' bash ;;
  660:args=) printf '%s\n' 'bash wrapper.sh' ;;
  660:ppid=) printf '%s\n' 670 ;;
  670:comm=) printf '%s\n' claude ;;
  670:args=) printf '%s\n' claude ;;
  670:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' "${FM_TEST_LEAF_PARENT:-650}" ;;
esac
SH
  chmod +x "$fakebin/ps"

  # A live foreign harness holds the lock, and this process's own harness (650)
  # is not it.
  printf '600\n' > "$dir/state/.lock"
  got=$(foreign_owner "$fakebin" "$dir/state") \
    || fail "a live foreign holder was not reported as holding the lock against this session"
  [ "$got" = 600 ] || fail "the foreign owner pid was '$got', expected 600"
  printf '650\n' > "$dir/state/.lock"
  if foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "the session's own lock was reported as held by another"
  fi
  printf '777\n' > "$dir/state/.lock"
  if foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "a holder that is not a live harness was reported as holding the lock against this session"
  fi
  printf 'junk\n' > "$dir/state/.lock"
  if foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "a malformed lock was reported as held by another"
  fi
  rm -f "${dir:?}/state/.lock"
  if foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "an absent lock was reported as held by another"
  fi
  # Uncertainty keeps the guard: with no harness anywhere in this process's
  # ancestry the session cannot prove it is the one locked out.
  printf '600\n' > "$dir/state/.lock"
  if FM_TEST_LEAF_PARENT=1 foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "a session with no locatable harness ancestry was treated as lock-refused"
  fi
  # A holder above a non-harness gap is outside the contiguous run, so it does
  # not own this session's lock, but it is still an ancestor of this process and
  # therefore never silences this session's guard.
  printf '670\n' > "$dir/state/.lock"
  if FM_TEST_CLAUDE_PARENT=660 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a holder beyond a non-harness gap was accepted as this session's owner"
  fi
  if FM_TEST_CLAUDE_PARENT=660 foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "an ancestor beyond a non-harness gap was reported as a foreign owner"
  fi

  # displaced_record: only the session that descends from the displaced pid (or
  # proves the displaced session's trusted id), and only while the takeover's new
  # pid still holds the lock.
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
  # The session that took over re-anchored line 1 onto a new pid of its own: the
  # id recorded beside the lock still names it, so the displacement is current;
  # a different recorded id means another session holds the lock now.
  printf '999\n' > "$dir/state/.lock"
  printf 'S9\n' > "$dir/state/.lock-session"
  printf 'at=2026-10-01T20:00:00Z\tnew_pid=600\tnew_session=S9\tnew_command=claude\tprev_pid=650\tprev_holder=command: claude\n' > "$dir/state/.lock-takeovers"
  lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state' | grep -q 'new_session=S9'" \
    || fail "a re-anchor by the session that took over hid the displacement from the displaced session"
  printf 'S8\n' > "$dir/state/.lock-session"
  if lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state'"; then
    fail "a lock now held under another session id was reported as the current displacement"
  fi
  rm -f "$dir/state/.lock-session"
  printf '600\n' > "$dir/state/.lock"
  # A displaced Claude session whose recorded pid is no longer an ancestor (its
  # helper chain was recycled) still recognizes itself through the recorded id,
  # and only through a trusted one.
  printf 'at=2026-10-01T20:00:00Z\tnew_pid=600\tnew_command=codex\tprev_pid=111\tprev_session=S1\tprev_holder=command: claude\n' > "$dir/state/.lock-takeovers"
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=650 lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state' | grep -q 'prev_session=S1'" \
    || fail "the displaced session's own trusted id did not find the takeover that displaced it"
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=650 lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state'"; then
    fail "a different session id was told it was displaced"
  fi
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=600 lib_eval "$fakebin" "fm_session_lock_displaced_record '$dir/state'"; then
    fail "an untrusted id was told it was displaced"
  fi
  pass "session-lock: lock-refused and displaced decisions follow the lock holder and this session's own harness"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
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
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-lease-lib.sh" "$dir/bin/fm-lease-lib.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
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
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
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
# The suite's traps, set once below beside the background fixture's reaper, run
# cleanup_sessions too.

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
# unix:// --managed-daemon). The suite may itself run inside a Claude session, so
# its CLAUDE_CODE_SESSION_ID and CLAUDE_PID are scrubbed; a case that needs a
# trusted id exports its own inside the session.
session_start() {
  local dir=$1 name=$2 bin=$3 back=$PWD
  shift 3
  mkfifo "$dir/$name.fifo"
  cd "$(dirname "$bin")" || fail "cannot enter the fake harness directory"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" SESSION_FIFO="$dir/$name.fifo" SESSION_BASE="$dir/$name" SESSION_LOOP="$SESSION_LOOP_FILE" \
    "./$(basename "$bin")" -c '. "$SESSION_LOOP"' session "$@" >/dev/null 2>&1 &
  SESSION_PID=$!
  cd "$back" || fail "cannot return to the suite directory"
  SESSION_PIDS+=("$SESSION_PID")
}

# session_run <dir> <name> <command>: run it inside that session's process.
# Sets SESSION_OUT and SESSION_RC.
session_run() {
  local dir=$1 name=$2 cmd=$3 deadline
  rm -f "${dir:?}/${name:?}.done"
  printf '%s\n' "$cmd" > "$dir/$name.fifo"
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$dir/$name.done" ]; do
    sleep 0.05
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
  local dir out deadline
  dir="$TMP_ROOT/takeover-plain-terminal"
  make_idle_daemon_home "$dir"
  cat > "$dir/terminal.sh" <<'SH'
#!/usr/bin/env bash
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
done
"$FM_HOME/bin/fm-lock.sh" takeover --confirm-holder "$1" > "$FM_HOME/terminal.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/terminal.rc"
SH
  FM_HOME="$dir" bash -c 'bash "$0" "$1" &' "$dir/terminal.sh" "$DAEMON_PID"
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -s "$dir/terminal.rc" ]; do
    sleep 0.05
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

# Two Claude sessions that each prove a trusted id: the takeover publishes the new
# holder's id beside the lock, so the displaced session's id no longer owns it,
# and records the displaced id so that session can still recognize itself.
test_takeover_of_a_trusted_session_moves_the_sidecar_and_records_its_id() {
  local dir holder taker record
  dir="$TMP_ROOT/takeover-trusted-session"
  make_primary_home "$dir"
  rm -f "${dir:?}/state/task.meta"
  session_start "$dir" holder "$NAMED_CLAUDE"
  holder=$SESSION_PID
  session_run "$dir" holder 'export CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$; "$FM_HOME/bin/fm-lock.sh"'
  expect_code 0 "$SESSION_RC" "the first trusted session could not take the lock: $SESSION_OUT"
  [ "$(cat "$dir/state/.lock-session")" = S1 ] || fail "the first session did not record its trusted id"
  session_start "$dir" taker "$NAMED_CLAUDE"
  taker=$SESSION_PID
  session_run "$dir" taker 'export CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$; "$FM_HOME/bin/fm-lock.sh"'
  expect_code 1 "$SESSION_RC" "a different trusted session acquired a live holder's lock"
  assert_contains "$SESSION_OUT" "holds the lock (pid $holder, session S1)" "the refusal lost the holder's pid and recorded id"
  assert_contains "$SESSION_OUT" "takeover --confirm-holder $holder" "the refusal did not print the takeover command"
  session_run "$dir" taker "\"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $holder"
  expect_code 0 "$SESSION_RC" "a confirmed takeover of a trusted session failed: $SESSION_OUT"
  [ "$(cat "$dir/state/.lock")" = "$taker" ] || fail "the lock does not name the new holder"
  [ "$(cat "$dir/state/.lock-session")" = S2 ] || fail "the takeover left the displaced session's id beside the lock"
  record=$(cat "$dir/state/.lock-takeovers")
  assert_contains "$record" "prev_session=S1" "the record did not keep the displaced session's id"
  assert_contains "$record" "new_session=S2" "the record did not keep the new holder's session id"
  session_run "$dir" holder '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 1 "$SESSION_RC" "the displaced trusted session took its lock back through its old id"
  assert_contains "$SESSION_OUT" "holds the lock (pid $taker, session S2)" "the displaced session was not told who holds the lock now"
  session_run "$dir" holder '. "$FM_HOME/bin/fm-session-lock-lib.sh"; fm_session_lock_displaced_record "$FM_HOME/state"'
  expect_code 0 "$SESSION_RC" "the displaced session did not recognize the takeover that displaced it"
  session_stop "$dir" taker "$taker"
  session_stop "$dir" holder "$holder"
  pass "session-lock takeover: a trusted session's takeover moves the sidecar to the new id and records the displaced one"
}

# A captain-confirmed takeover holds against the displaced session only while the
# taker's recorded pid lives. Once that pid is dead the lock is stale like any
# other, so the displaced session reclaims it automatically, even with the
# taker's id still beside it and the takeover record still naming the displaced
# session.
test_displaced_session_reclaims_once_the_takers_recorded_pid_is_dead() {
  local dir displaced taker
  dir="$TMP_ROOT/takeover-dead-taker"
  make_primary_home "$dir"
  rm -f "${dir:?}/state/task.meta"
  session_start "$dir" displaced "$NAMED_CLAUDE"
  displaced=$SESSION_PID
  session_run "$dir" displaced 'export CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$; "$FM_HOME/bin/fm-lock.sh"'
  expect_code 0 "$SESSION_RC" "the first trusted session could not take the lock: $SESSION_OUT"
  session_start "$dir" taker "$NAMED_CLAUDE"
  taker=$SESSION_PID
  session_run "$dir" taker "export CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=\$\$; \"\$FM_HOME/bin/fm-lock.sh\" takeover --confirm-holder $displaced"
  expect_code 0 "$SESSION_RC" "the confirmed takeover failed: $SESSION_OUT"
  session_run "$dir" displaced '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 1 "$SESSION_RC" "the displaced session took the lock from a live taker"
  assert_contains "$SESSION_OUT" "holds the lock (pid $taker, session S2)" "the displaced session was not told the live taker holds the lock"
  [ "$(cat "$dir/state/.lock")" = "$taker" ] || fail "the live taker lost the lock to the displaced session"
  session_stop "$dir" taker "$taker"
  if kill -0 "$taker" 2>/dev/null; then fail "the taker session is still running"; fi
  [ "$(cat "$dir/state/.lock-session")" = S2 ] || fail "the taker's id is no longer beside the lock after it exited"
  session_run "$dir" displaced '"$FM_HOME/bin/fm-lock.sh"'
  expect_code 0 "$SESSION_RC" "the displaced session did not reclaim the dead taker's lock automatically: $SESSION_OUT"
  [ "$(cat "$dir/state/.lock")" = "$displaced" ] || fail "the reclaim did not anchor the lock on the displaced session"
  [ "$(cat "$dir/state/.lock-session")" = S1 ] || fail "the reclaim did not record the displaced session's id"
  [ "$(wc -l < "$dir/state/.lock-takeovers" | tr -d ' ')" = 1 ] || fail "the automatic reclaim was recorded as a takeover"
  session_stop "$dir" displaced "$displaced"
  pass "session-lock takeover: a live taker holds against the displaced session, which reclaims automatically once the taker's recorded pid is dead"
}

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
# One set of traps covers both fixture kinds: the fake takeover sessions above
# and the background fixture here.
trap 'cleanup_sessions; reap_background_fixture; fm_test_cleanup' EXIT
trap 'cleanup_sessions; reap_background_fixture; fm_test_cleanup; exit 130' INT
trap 'cleanup_sessions; reap_background_fixture; fm_test_cleanup; exit 143' TERM

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -s "$1" ]; do
    sleep 0.05
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 naming <expected-lock-pid>, and the sidecar either
# byte-identical to the one the owner wrote or, when <expected-session-id> is
# given, re-keyed to that id. An owned actionable close records two arm
# invocations - the foreground arm plus the handling successor the hook starts
# before the rewake - so the cumulative <expected-arms> grows by two for every
# owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label> [<expected-session-id>]
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5 session_id=${6:-}
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  if [ -n "$session_id" ]; then
    [ "$(phase_value "$dir" "$n" session-after)" = "$session_id" ] \
      || fail "$label: the session sidecar names $(phase_value "$dir" "$n" session-after), expected $session_id"
  else
    cmp -s "$dir/state/phase-$n/session-after" "$dir/sidecar-initial" \
      || fail "$label: the session sidecar is not byte-identical to the one the owner wrote"
  fi
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare deadline
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phases 2-4: before the spare proves anything, a different id, the right id
  # from a CLAUDE_PID outside the run, and no id at all are each a non-owner
  # over the broken chain.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so these phases prove nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_foreign "$dir" 2 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 3 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 4 ''
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, no id"

  # Phase 5: the same session id over the broken chain - the reported drift. The
  # confirmation re-anchors line 1 from the live non-ancestor front-end onto the
  # spare - the model-loop process - not onto the outermost pty-host.
  fire_phase "$dir" 5 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 5 4 "$spare" "recycled chain, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end exited, so the re-anchor was not over a live owner"

  # Phase 6: /clear - the same spare under a new id while the front-end that
  # first recorded the lock is still alive. Ancestry still proves ownership and
  # the sidecar is re-keyed.
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "same process after a session-id change" S2

  : > "$dir/state/stop-frontend"
  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain and a same-process session-id change"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

# fm-lint-waits: allow a deliberate one-second head start, so the confirmation is already waiting on the claim lock when the holder changes the lock under it
i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

# fm-lint-waits: allow a deliberate one-second head start, so the confirmation is already waiting on the claim lock when the holder changes the lock under it
i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

# A re-anchor moves leases recorded against the old live line 1 onto the new
# anchor, so the other supervision actor still cannot claim a held task.
test_reanchor_keeps_task_leases_live() {
  local dir front_pid model_pid lease_rc
  dir="$TMP_ROOT/reanchor-leases"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'branch\t%s\t100\n' "$front_pid" > "$dir/state/.lease-t1"
  printf 'main\t%s\t200\n' "$front_pid" > "$dir/state/.lease-t2"
  printf 'branch\t%s\t300\n' "$$" > "$dir/state/.lease-t3"
  cp "$dir/state/.lease-t3" "$dir/state/lease-t3-before"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$model_pid")" ] \
    || fail "the branch lease was not moved to the new anchor: $(cat "$dir/state/.lease-t1")"
  [ "$(cat "$dir/state/.lease-t2")" = "$(printf 'main\t%s\t200' "$model_pid")" ] \
    || fail "the main lease was not moved to the new anchor: $(cat "$dir/state/.lease-t2")"
  cmp -s "$dir/state/lease-t3-before" "$dir/state/.lease-t3" \
    || fail "a lease recorded against another pid changed: $(cat "$dir/state/.lease-t3")"
  env -u FM_SUPERVISION_ACTOR -u FM_LEASE_HOLDER_PID FM_HOME="$dir" \
    "$ROOT/bin/fm-lease.sh" claim t1 > "$dir/state/main-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "main claimed the branch's task after the re-anchor: $(cat "$dir/state/main-claim.out")"
  env -u FM_SUPERVISION_ACTOR FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$model_pid" \
    "$ROOT/bin/fm-lease.sh" claim t2 > "$dir/state/branch-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "the branch claimed main's task after the re-anchor: $(cat "$dir/state/branch-claim.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor keeps both supervision actors' task leases live"
}

autoarm_midturn_healthy() {  # <state-dir>
  FM_STATE_OVERRIDE="$1" bash -c '. "$0"; fm_autoarm_midturn_healthy "$FM_STATE_OVERRIDE" 300' "$ROOT/bin/fm-wake-lib.sh"
}

# A re-anchor during a rewake handling turn that has outrun grace moves the
# auto-arm ledger's session_pid with line 1 and keeps the ledger's other bytes
# and mtime, so the mid-turn guard still sees healthy supervision.
test_reanchor_keeps_autoarm_midturn_healthy() {
  local dir front_pid model_pid
  dir="$TMP_ROOT/reanchor-autoarm"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1\n' \
    "$front_pid" > "$dir/state/.claude-autoarm-epoch"
  printf 'acked:handling:g1\n' > "$dir/state/.watcher-down"
  touch -t 201901010000 "$dir/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch" "$dir/state/epoch-mtime"
  autoarm_midturn_healthy "$dir/state" || fail "the rewake fixture is not healthy before the re-anchor, so this case proves nothing"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$(printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1' "$model_pid")" ] \
    || fail "the rewake was not moved to the new anchor intact: $(cat "$dir/state/.claude-autoarm-epoch")"
  if [ "$dir/state/.claude-autoarm-epoch" -nt "$dir/state/epoch-mtime" ] \
    || [ "$dir/state/.claude-autoarm-epoch" -ot "$dir/state/epoch-mtime" ]; then
    fail "the rewake move changed the ledger mtime"
  fi
  autoarm_midturn_healthy "$dir/state" \
    || fail "the mid-turn guard rejects the rewake after the re-anchor: $(cat "$dir/state/reanchor.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor during a rewake turn keeps the mid-turn auto-arm proof healthy"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_foreign_owner_and_displaced_record_decisions
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
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
test_takeover_of_a_trusted_session_moves_the_sidecar_and_records_its_id
test_displaced_session_reclaims_once_the_takers_recorded_pid_is_dead
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
test_reanchor_keeps_task_leases_live
test_reanchor_keeps_autoarm_midturn_healthy
