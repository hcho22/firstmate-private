#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake;
# bin/fm-turnend-guard.sh uses it to tell a lock-refused (read-only) session,
# which must not be held to a repair it may not perform, from the lock holder.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Print the numeric holder pid recorded in state dir $1's session lock, or fail
# when the lock is absent or malformed.
fm_session_lock_holder_pid() {
  local lock_pid
  lock_pid=$(cat "$1/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$lock_pid"
}

# True when pid $2, recorded in state dir $1's session lock, still holds a LIVE
# firstmate session. THE single owner of the question every lock reader asks
# before it defers to, or reclaims from, a recorded holder: bin/fm-lock.sh, the
# Claude Stop auto-arm, the Cursor park, and the turn-end guard all call it, so
# no caller can drift into a looser or stricter test of its own.
fm_session_holder_live() {  # <state> <pid>
  fm_harness_pid_alive "$2"
}

# Print pid $1's command line as one printable line capped at 300 characters
# (a harness launched with a whole brief on its command line stays readable), or
# a placeholder when ps cannot report it.
fm_session_lock_process_args() {  # <pid>
  local args
  args=$(ps -o args= -p "$1" 2>/dev/null | head -n 1 | tr -c '[:print:]' ' ' | cut -c1-300 | sed 's/[[:space:]]*$//')
  [ -n "$args" ] || args='(command unavailable)'
  printf '%s' "$args"
}

# Print one plain fragment naming WHAT holds state dir $1's session lock (pid
# $2): its command and when it took the lock. A bare pid tells a refused
# session nothing about whether the holder is a working session or an idle
# background service (an idle Codex app-server daemon looks exactly like a live
# Codex session by name alone), so the captain needs the command and the age to
# decide. Time taken is the lock file's mtime: only acquisition rewrites it.
# Needs fm_path_mtime from bin/fm-wake-lib.sh in the caller.
fm_session_lock_holder_summary() {  # <state> <pid>
  local state=$1 pid=$2 args since now age taken
  args=$(fm_session_lock_process_args "$pid")
  since=$(fm_path_mtime "$state/.lock" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*) printf 'command: %s, lock acquisition time unknown' "$args"; return 0 ;;
  esac
  now=$(date +%s)
  age=$(( (now - since) / 60 ))
  taken=$(date -u -r "$since" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d "@$since" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf 'epoch %s' "$since")
  if [ "$age" -ge 120 ]; then
    age="$((age / 60))h $((age % 60))m"
  elif [ "$age" -ge 1 ]; then
    age="${age}m"
  else
    age='under 1m'
  fi
  printf 'command: %s, holding the lock since %s (%s ago)' "$args" "$taken" "$age"
}

# True when pid $1 is this process or ANY ancestor of it, at any depth (up to 64
# hops). Wider than the contiguous harness run fm_session_lock_owned_by_self
# uses: the stand-down decisions below silence a guard, so they must treat a
# holder anywhere above this process as "this is the holder's own session" and
# silence it only for a holder that is provably not an ancestor.
fm_session_lock_pid_in_ancestry() {  # <pid>
  local want=$1 pid=$$ _
  for _ in $(seq 1 64); do
    [ "$pid" = "$want" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
  done
  [ "$pid" = "$want" ]
}

# True when state dir $1's session lock is held by a DIFFERENT live firstmate
# session: the lock names a live holder that is not this process or any ancestor
# of it. This is exactly the lock-refused (read-only) session. An absent or
# malformed lock, a dead holder, and an ancestry in which no harness can be
# located are all "cannot tell" and return false, so a session that never
# acquired the lock, or whose hook cannot be tied to a harness, keeps its guard
# rather than being silenced by uncertainty.
fm_session_lock_held_by_other() {
  local state=$1 lock_pid
  lock_pid=$(fm_session_lock_holder_pid "$state") || return 1
  fm_session_holder_live "$state" "$lock_pid" || return 1
  fm_harness_ancestry_pids >/dev/null || return 1
  ! fm_session_lock_pid_in_ancestry "$lock_pid"
}

# Print the newest takeover record (bin/fm-lock.sh appends one to
# state/.lock-takeovers per explicit takeover) when THIS process descends from the
# very pid that takeover displaced and the takeover's new pid is still the
# recorded lock holder; fail otherwise. This is how a displaced session that is
# still running learns it was replaced instead of merely observing a foreign lock.
fm_session_lock_displaced_record() {
  local state=$1 record holder prev_pid new_pid
  record=$(tail -n 1 "$state/.lock-takeovers" 2>/dev/null) || return 1
  [ -n "$record" ] || return 1
  holder=$(fm_session_lock_holder_pid "$state") || return 1
  new_pid=$(printf '%s\n' "$record" | tr '\t' '\n' | sed -n 's/^new_pid=//p')
  prev_pid=$(printf '%s\n' "$record" | tr '\t' '\n' | sed -n 's/^prev_pid=//p')
  [ -n "$prev_pid" ] && [ "$new_pid" = "$holder" ] || return 1
  fm_harness_ancestry_pids >/dev/null || return 1
  fm_session_lock_pid_in_ancestry "$prev_pid" || return 1
  printf '%s\n' "$record"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(fm_session_lock_holder_pid "$state") || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
