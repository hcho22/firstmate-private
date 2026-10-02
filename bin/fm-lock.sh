#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#        fm-lock.sh takeover --confirm-holder <pid>
#                             captain-confirmed takeover of a lock whose holder
#                             is still alive; exit 1 unless ownership is verified
#
# CONTRACT. state/.lock is ONE line, the holder's bare numeric pid. Every reader
# in the fleet, old or new, parses exactly that, so nothing else may ever be
# written into it. A holder whose pid is dead (or is no longer a verified
# harness) is stale and is reclaimed automatically. A holder whose pid is ALIVE
# is never displaced automatically, for any harness: a live process cannot prove
# whether it hosts a working session or is an idle background service that once
# ran one (an idle Codex app-server daemon is the reproduced case), and guessing
# wrong would put two sessions on one fleet. The refused session instead prints
# who holds the lock (pid, command, since when) and the one takeover command
# below, for the captain to confirm.
#
# TAKEOVER. `takeover --confirm-holder <pid>` is the only way to displace a live
# holder. It refuses unless ALL of these hold, checked under the same claim lock
# as acquisition:
#   - the confirmed pid is exactly the pid currently recorded as holder, so a
#     stale confirmation can never displace a different, newer holder;
#   - no watcher beat is fresh (FM_GUARD_GRACE, default 300s), because a fresh
#     beat means a live session is supervising this home right now;
#   - the takeover can be recorded.
# It appends one line to state/.lock-takeovers (who took over from whom, and
# when) and then writes the new holder pid. It never signals the previous holder:
# that process may be a shared background service. A previous holder that is
# still a firstmate session finds itself read-only at every lock-ownership check
# (this script, the Claude auto-arm, the Cursor park, the turn-end guard, and the
# locked startup sweeps), all of which compare the recorded pid with their own
# harness; docs/turnend-guard.md records which actions that does and does not
# cover.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
TAKEOVER_LOG="$STATE/.lock-takeovers"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old ($(fm_session_lock_holder_summary "$STATE" "$old"))"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

TAKEOVER=0
CONFIRM_HOLDER=
if [ "${1:-}" = "takeover" ]; then
  TAKEOVER=1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm-holder) CONFIRM_HOLDER=${2:-}; shift; [ "$#" -eq 0 ] || shift ;;
      *) echo "usage: fm-lock.sh takeover --confirm-holder <pid>" >&2; exit 2 ;;
    esac
  done
  case "$CONFIRM_HOLDER" in
    ''|*[!0-9]*)
      echo "error: takeover needs the explicit confirmation --confirm-holder <pid> naming the live holder; read it from 'fm-lock.sh status'" >&2
      exit 2
      ;;
  esac
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

# The refusal a session gets when it does not hold the lock. The first line is the
# stable diagnostic every consumer matches; the rest names the holder and the one
# way out, so the captain decides with the facts instead of a bare pid.
refuse_live_holder() {  # <pid>
  echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fm_session_lock_takeover_guidance "$STATE" "$1" "$SCRIPT_DIR/fm-lock.sh" "$FM_HOME" "$FM_ROOT" | sed 's/^/  /' >&2
}

# Publish this session's pid as the holder and verify it landed. Exits 1 with the
# read-only diagnostic when it cannot; callers hold the claim lock.
write_lock() {
  local written
  if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
  written=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
    exit 1
  }
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
    echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
    exit 1
  fi
}

if [ "$TAKEOVER" -eq 0 ] && [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    refuse_live_holder "$old"
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

old=
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
fi

if [ "$TAKEOVER" -eq 1 ]; then
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  case "$old" in
    ''|*[!0-9]*)
      echo "error: there is no live lock holder to take over; run $SCRIPT_DIR/fm-lock.sh to acquire the lock normally" >&2
      exit 1
      ;;
  esac
  if ! fm_harness_pid_alive "$old"; then
    echo "error: lock holder pid $old is not a live session, so no takeover is needed; run $SCRIPT_DIR/fm-lock.sh to acquire the lock normally" >&2
    exit 1
  fi
  if [ "$CONFIRM_HOLDER" != "$old" ]; then
    echo "error: the lock is now held by pid $old, not the confirmed pid $CONFIRM_HOLDER; re-read 'fm-lock.sh status' and confirm again" >&2
    exit 1
  fi
  fm_supervision_status "$STATE"
  if [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    echo "error: takeover refused: a watcher beat is fresh (last beat: $FM_SUP_BEACON_DESC), so a live session is supervising this home right now; retry only after the beat has gone stale" >&2
    exit 1
  fi
  # The record is part of the takeover: refuse up front when it cannot be kept,
  # and capture the previous holder's description before the new pid replaces the
  # lock file whose mtime says when it took the lock.
  if ! : >> "$TAKEOVER_LOG" 2>/dev/null; then
    echo "error: cannot record the takeover in $TAKEOVER_LOG; operate read-only until resolved" >&2
    exit 1
  fi
  prev_summary=$(fm_session_lock_holder_summary "$STATE" "$old")
  me_args=$(fm_session_lock_process_args "$me")
  write_lock
  if ! printf 'at=%s\tnew_pid=%s\tnew_command=%s\tprev_pid=%s\tprev_holder=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$me" "$me_args" "$old" "$prev_summary" >> "$TAKEOVER_LOG" 2>/dev/null; then
    echo "warning: lock taken over but the takeover record could not be appended to $TAKEOVER_LOG" >&2
  fi
  # Bound the record: takeovers are rare, so a short tail keeps full history.
  if [ "$(wc -l < "$TAKEOVER_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$TAKEOVER_LOG" > "$TAKEOVER_LOG.tmp.$$" 2>/dev/null \
      && mv -f "$TAKEOVER_LOG.tmp.$$" "$TAKEOVER_LOG" 2>/dev/null
    rm -f "$TAKEOVER_LOG.tmp.$$" 2>/dev/null || true
  fi
  release_claim_lock
  echo "lock taken over: harness pid $me replaced pid $old ($prev_summary)"
  echo "The previous holder was not signalled. If it is still a firstmate session it must stop acting on the fleet now: it is read-only and must not spawn, steer, merge, tear down, drain wakes, or arm the watcher, so tell it to stop. Run $SCRIPT_DIR/fm-session-start.sh now to complete the locked session start."
  exit 0
fi

if [ "$old" != "$me" ] && [ -n "$old" ] && fm_harness_pid_alive "$old"; then
  refuse_live_holder "$old"
  exit 1
fi
write_lock
release_claim_lock
echo "lock acquired: harness pid $me"
