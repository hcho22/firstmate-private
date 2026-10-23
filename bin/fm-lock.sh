#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. Line 1 keeps its whole-line pid format because
# every other reader takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation keeps a live line 1 that is in this session's harness ancestry,
# because bin/fm-startup-network.sh compares that pid across its deferred
# sweeps; a dead recorded pid is reclaimed and rewritten to this session's
# anchor. A live line 1 outside the ancestry, owned only through the trusted
# id, is rewritten to the anchor under the claim lock and then the
# lease-command lock, and task leases recorded against the old pid move to the
# anchor in that same section (fm_lease_rekey_holder in bin/fm-lease-lib.sh),
# as does a Claude auto-arm rewake bound to the old pid, under
# state/.claude-autoarm.lock (fm_autoarm_rekey_session in bin/fm-wake-lib.sh).
# A later /clear re-key in the same process is then still proven by ancestry
# after the id changes, a held lease stays live, and the mid-turn guard still
# accepts that rewake. A lease or rewake that cannot be moved, including when
# the auto-arm lock stays busy past LEASE_LOCK_WAIT seconds, is reported as a
# warning and the re-anchor still completes. When the lease-command
# lock stays busy past LEASE_LOCK_WAIT seconds, the confirmation only refreshes
# the sidecar, as for a line 1 in the ancestry, and a later acquisition
# re-anchors.
#
# LIVE HOLDER. A holder whose recorded pid is dead (or is no longer a verified
# harness) is stale and is reclaimed automatically. A live holder that this
# session does not own is never displaced automatically, for any harness: a
# live process cannot prove whether it hosts a working session or is an idle
# background service that once ran one (an idle Codex app-server daemon is the
# reproduced case), and guessing wrong would put two sessions on one fleet. The
# refused session instead gets the stable first diagnostic line, then who holds
# the lock (pid, command, since when) and the one takeover command below, for
# the captain to confirm (fm_session_lock_takeover_guidance in
# bin/fm-session-lock-lib.sh owns that wording).
#
# TAKEOVER. `takeover --confirm-holder <pid>` is the only way to displace a live
# holder. It refuses unless ALL of these hold, checked under the same claim lock
# as acquisition, after the same-session confirmation above has had its say (a
# lock this session already owns is confirmed or re-anchored, never taken over):
#   - the confirmed pid is exactly the pid currently recorded as holder, so a
#     stale confirmation can never displace a different, newer holder;
#   - no watcher beat is fresh (FM_GUARD_GRACE, default 300s), because a fresh
#     beat means a live session is supervising this home right now;
#   - the takeover can be recorded.
# It must run inside the firstmate session that will hold the lock, because the
# new holder is that session's anchor pid; run anywhere else it refuses and says
# so. The prior-session-sweep-is-finishing refusal applies to it exactly as to
# an acquisition. It publishes the new holder through the same sidecar-first
# write as an acquisition, so the displaced session's id no longer backs the
# lock, appends one line to state/.lock-takeovers (who took over from whom, both
# sessions' recorded ids when they have them, and when), and never signals the
# previous holder: that process may be a shared background service. Task
# leases and a Claude auto-arm rewake recorded against the previous holder are
# left as they are and read as stale, because they belong to that session.
# A previous holder that is still a firstmate session finds itself read-only at
# every lock-ownership check (this script, the Claude auto-arm, the Cursor
# park, the turn-end guard, and the locked startup sweeps);
# docs/turnend-guard.md records which actions that does and does not cover.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
#        fm-lock.sh takeover --confirm-holder <pid>
#                             captain-confirmed takeover of a lock whose holder
#                             is still alive; exit 1 unless ownership is verified
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
TAKEOVER_LOG="$STATE/.lock-takeovers"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# fm-wake-lib.sh owns the lock primitives below and fm_path_mtime, which the
# holder summary in the status line and in every refusal reads.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID ($(fm_session_lock_holder_summary "$STATE" "$FM_LOCK_INSPECT_PID"))" ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
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

if ! me=$(fm_session_lock_anchor_pid); then
  if [ "$TAKEOVER" -eq 1 ]; then
    echo "error: cannot locate harness process in ancestry: a takeover must be run by the firstmate session that will take the lock, and this command is not running inside one; ask firstmate in that session to run it" >&2
  else
    echo "error: cannot locate harness process in ancestry" >&2
  fi
  exit 1
fi
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
LEASE_LOCK="$STATE/.fm-lease-command.lock"
LEASE_LOCK_HELD=0
LEASE_LOCK_WAIT=5
AUTOARM_LOCK="$STATE/.claude-autoarm.lock"
AUTOARM_LOCK_HELD=0
# The live line-1 pid a same-session confirmation is moving off, or empty.
REANCHOR=
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_autoarm_lock() {
  if [ "$AUTOARM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$AUTOARM_LOCK"
    AUTOARM_LOCK_HELD=0
  fi
}
release_lease_lock() {
  if [ "$LEASE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LEASE_LOCK"
    LEASE_LOCK_HELD=0
  fi
}
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_autoarm_lock
  release_lease_lock
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive and in this session's ancestry; only the
# sidecar is refreshed, under the claim lock, so a /clear re-key inside the same
# process replaces the old id. A live line 1 outside the ancestry is re-anchored
# as the header describes: REANCHOR records it and the caller keeps both locks
# for the guarded write below.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal guards replacing another session's
# lock (a reclaim or an explicit takeover) and does not apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded pids waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    if [ "$recorded" != "$me" ] && pids=$(fm_harness_ancestry_pids) \
      && ! fm_harness_pid_listed "$recorded" "$pids" \
      && fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_LOCK_WAIT"; then
      LEASE_LOCK_HELD=1
      REANCHOR=$recorded
      return 0
    fi
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

# The refusal a session gets when it does not hold the lock. The first line is the
# stable diagnostic every consumer matches; the rest names the holder and the one
# way out, so the captain decides with the facts instead of a bare pid.
refuse_live_owner() {  # <recorded-pid>
  local recorded
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  fm_session_lock_takeover_guidance session "$STATE" "$1" "$SCRIPT_DIR/fm-lock.sh" "$FM_HOME" "$FM_ROOT" | sed 's/^/  /' >&2
  exit 1
}

# Validate a takeover of live holder $1 under the claim lock, or exit with the
# refusal. On success it leaves the previous holder's description in
# TAKEOVER_PREV_SUMMARY and its recorded session id, if any, in
# TAKEOVER_PREV_SESSION, captured before the write replaces the lock whose
# mtime says when that holder took it.
TAKEOVER_PREV=
TAKEOVER_PREV_SUMMARY=
TAKEOVER_PREV_SESSION=
takeover_preflight() {  # <recorded-pid>
  local old=$1
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
  # The record is part of the takeover: refuse up front when it cannot be kept.
  if ! : >> "$TAKEOVER_LOG" 2>/dev/null; then
    echo "error: cannot record the takeover in $TAKEOVER_LOG; operate read-only until resolved" >&2
    exit 1
  fi
  TAKEOVER_PREV=$old
  TAKEOVER_PREV_SUMMARY=$(fm_session_lock_holder_summary "$STATE" "$old")
  TAKEOVER_PREV_SESSION=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
}

# Append the takeover record and bound the log. The new holder's session id is
# the one the sidecar-first write just published (empty for a session that
# proves none). A record that cannot be appended after the write is reported but
# does not undo the takeover.
record_takeover() {
  local me_args me_session
  me_args=$(fm_session_lock_process_args "$me")
  me_session=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
  if ! printf 'at=%s\tnew_pid=%s\tnew_session=%s\tnew_command=%s\tprev_pid=%s\tprev_session=%s\tprev_holder=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$me" "$me_session" "$me_args" "$TAKEOVER_PREV" "$TAKEOVER_PREV_SESSION" "$TAKEOVER_PREV_SUMMARY" >> "$TAKEOVER_LOG" 2>/dev/null; then
    echo "warning: lock taken over but the takeover record could not be appended to $TAKEOVER_LOG" >&2
  fi
  # Bound the record: takeovers are rare, so a short tail keeps full history.
  if [ "$(wc -l < "$TAKEOVER_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$TAKEOVER_LOG" > "$TAKEOVER_LOG.tmp.$$" 2>/dev/null \
      && mv -f "$TAKEOVER_LOG.tmp.$$" "$TAKEOVER_LOG" 2>/dev/null
    rm -f "$TAKEOVER_LOG.tmp.$$" 2>/dev/null || true
  fi
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if [ "$TAKEOVER" -eq 0 ] && [ -z "$REANCHOR" ] && fm_harness_pid_alive "$old"; then
    refuse_live_owner "$old"
  fi
fi

if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
      echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
      exit 1
    fi
    fm_lock_acquire_wait "$CLAIM_LOCK"
  fi
  CLAIM_LOCK_HELD=1
fi

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  # A re-anchor decided above has held the claim lock since, so line 1 is the
  # pid it recorded and needs no second verdict.
  if [ -z "$REANCHOR" ] && [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ "$TAKEOVER" -eq 0 ] && [ -z "$REANCHOR" ] && [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# A takeover reaches here holding the claim lock. A lock this session already
# owns was confirmed or re-anchored above; anything else must be the confirmed
# live holder.
if [ "$TAKEOVER" -eq 1 ] && [ -z "$REANCHOR" ]; then
  old=
  if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if [ "$old" = "$me" ]; then
    confirm_own_lock "$old"
  fi
  takeover_preflight "$old"
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place, except on the re-anchor path:
# there a HUP, INT, or TERM during the lease move or the bounded
# .claude-autoarm.lock wait, before commit_lock_session, still runs
# restore_uncommitted_lock_session with phase 2 and removes the sidecar.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
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
if [ -n "$REANCHOR" ] && ! fm_lease_rekey_holder "$REANCHOR" "$me"; then
  echo "warning: a task lease recorded against pid $REANCHOR could not be moved to pid $me, so it reads as stale" >&2
fi
if [ -n "$REANCHOR" ] && fm_autoarm_ledger_read "$STATE" && [ "$FM_AUTOARM_SESSION" = "$REANCHOR" ]; then
  if fm_lock_acquire_wait_max "$AUTOARM_LOCK" "$LEASE_LOCK_WAIT"; then
    AUTOARM_LOCK_HELD=1
  fi
  if [ "$AUTOARM_LOCK_HELD" -ne 1 ] || ! fm_autoarm_rekey_session "$STATE" "$REANCHOR" "$me"; then
    echo "warning: the Claude auto-arm rewake recorded against pid $REANCHOR could not be moved to pid $me, so a mid-turn guard can report supervision off until the next Stop" >&2
  fi
  release_autoarm_lock
fi
commit_lock_session
if [ -n "$TAKEOVER_PREV" ]; then
  record_takeover
  release_claim_lock
  echo "lock taken over: harness pid $me replaced pid $TAKEOVER_PREV ($TAKEOVER_PREV_SUMMARY)"
  echo "The previous holder was not signalled. If it is still a firstmate session it must stop acting on the fleet now: it is read-only and must not spawn, steer, merge, tear down, drain wakes, or arm the watcher, so tell it to stop. Run $SCRIPT_DIR/fm-session-start.sh now to complete the locked session start."
  exit 0
fi
release_lease_lock
release_claim_lock
echo "lock acquired: harness pid $me"
