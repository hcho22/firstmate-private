#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides the bounded runners below so no caller has
# to re-derive the coreutils/BSD/perl selection, and so every bounded call in
# this repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
#   fm_run_progress_bounded <idle-seconds> <backstop-seconds> <watch-file>
#                           <reason-file> <command> [args...]
#       Runs the command in its own process group and terminates the group
#       (TERM, then KILL 0.2 s later) once <watch-file> - where the caller
#       sends the command's output - has not grown for <idle-seconds>, or once
#       the command has run for <backstop-seconds> in total, whichever comes
#       first. It then writes "idle" or "backstop" to <reason-file> and returns
#       124. Otherwise it returns the command's own status, or 128 + n for a
#       command ended by signal n, and writes nothing. A missing watch file
#       counts as empty. It is a hang guard for commands that report progress
#       as they go (bin/fm-test-run.sh's automatic per-script bound): a command
#       that keeps producing output is never stopped for being slow, one that
#       goes silent is stopped as quickly as a flat bound would. A 0 for
#       <idle-seconds> or <backstop-seconds> disables that bound alone, and 0
#       for both runs the command unbounded but still in its own process group
#       (bin/fm-test-run.sh's unbounded scripts). It needs perl; without perl it
#       falls back to fm_run_timed with whichever bound is set, idle first, or
#       runs the command directly when neither is.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers of fm_run_timed must reject 0
# before calling.
#
# FM_TIMEOUT_GROUP_FILE, when set in the calling shell, names a file both
# runners write the bounded command's process-group id to as soon as that group
# exists, whatever the mechanism. A caller that is itself interrupted uses it to
# stop the command's whole group before it exits, since signalling the runner
# alone would leave the group running (bin/fm-test-run-reap.sh). It is read as
# a shell variable and never reaches the command's environment. Nothing is
# written when the command gets no group of its own (the no-perl fallback of an
# unbounded fm_run_progress_bounded).
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# fm_timeout_record_group <pgid>: publish the bounded command's process-group id
# to FM_TIMEOUT_GROUP_FILE, when the caller asked for it.
fm_timeout_record_group() {
  [ -n "${FM_TIMEOUT_GROUP_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_TIMEOUT_GROUP_FILE" 2>/dev/null || true
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    unset FM_TIMEOUT_GROUP_FILE
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  fm_timeout_record_group "$child_pid"
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    unset FM_TIMEOUT_GROUP_FILE
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" &
  runner_pid=$!
  fm_timeout_record_group "$runner_pid"
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl)
      # Both sides set the child's group so it exists before its id is
      # published, whichever of them runs first.
      perl -e 'my ($t, $g) = splice(@ARGV, 0, 2); delete $ENV{FM_TIMEOUT_GROUP_FILE}; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } setpgrp($pid, $pid); if (length $g && open(my $fh, ">", $g)) { print $fh "$pid\n"; close $fh } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "${FM_TIMEOUT_GROUP_FILE:-}" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}

fm_run_progress_bounded() {  # <idle-seconds> <backstop-seconds> <watch-file> <reason-file> <command...>
  local idle=$1 backstop=$2 watch=$3 reason=$4 rc
  shift 4
  rm -f "$reason" 2>/dev/null || true
  if ! command -v perl >/dev/null 2>&1; then
    if [ "$idle" -gt 0 ]; then
      fm_run_timed "$idle" "$@"
      rc=$?
      [ "$rc" -ne 124 ] || printf 'idle\n' > "$reason" 2>/dev/null || true
    elif [ "$backstop" -gt 0 ]; then
      fm_run_timed "$backstop" "$@"
      rc=$?
      [ "$rc" -ne 124 ] || printf 'backstop\n' > "$reason" 2>/dev/null || true
    else
      (unset FM_TIMEOUT_GROUP_FILE; "$@")
      rc=$?
    fi
    return "$rc"
  fi
  perl -e '
    use strict;
    use warnings;
    use POSIX ":sys_wait_h";
    use Time::HiRes qw(time sleep);
    my ($idle, $backstop, $watch, $reason, $group) = splice(@ARGV, 0, 5);
    delete $ENV{FM_TIMEOUT_GROUP_FILE};
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127; }
    # Set here too, so the group exists before its id is published.
    setpgrp($pid, $pid);
    if (length $group && open(my $fh, ">", $group)) { print $fh "$pid\n"; close $fh; }
    my $start = time;
    my $last = $start;
    my $size = -1;
    while (1) {
      if (waitpid($pid, WNOHANG) == $pid) {
        exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
      }
      my @st = stat($watch);
      my $now_size = @st ? $st[7] : 0;
      my $now = time;
      if ($now_size != $size) { $size = $now_size; $last = $now; }
      my $why = $idle > 0 && $now - $last >= $idle ? "idle"
        : $backstop > 0 && $now - $start >= $backstop ? "backstop" : "";
      if ($why ne "") {
        kill "TERM", -$pid;
        sleep 0.2;
        kill "KILL", -$pid;
        waitpid($pid, 0);
        if (open(my $fh, ">", $reason)) { print $fh "$why\n"; close $fh; }
        exit 124;
      }
      sleep 0.5;
    }
  ' "$idle" "$backstop" "$watch" "$reason" "${FM_TIMEOUT_GROUP_FILE:-}" "$@"
}
