#!/usr/bin/env bash
# fm-test-run-reap.sh - stop what a bin/fm-test-run.sh script left running and
# remove its private sandbox.
#
# Usage:
#   fm-test-run-reap.sh --script <work-dir>
#   fm-test-run-reap.sh --run <run-root>
#
# bin/fm-test-run.sh gives every script a private work directory under its run
# root, runs the script in its own process group, and records that group's id
# in <work-dir>/script.pgid. A script that is interrupted, killed by the
# per-script hang guard, or simply exits without cleaning up can leave
# processes behind: members of its own group, and processes that moved
# themselves into another group on purpose. A remote job worker
# (bin/fm-remote-job-worker.sh) is the second kind, because its Linux start
# path isolates the worker tree, so neither the hang guard's group kill nor a
# Ctrl-C reaches it, and it would keep polling its fixture for as long as that
# fixture exists.
#
# --script stops the recorded group (TERM, then KILL for a member still alive
# after FM_TEST_RUN_REAP_GRACE_SECONDS, default 10, which is the time a script's
# own TERM trap gets to clean up), removes <work-dir>/tmp (the script's TMPDIR),
# and then stops every remote job worker whose code root lay inside
# <work-dir> through bin/fm-remote-job-reap-orphans.sh scoped to it. Nothing is
# chosen by a name alone: the group by the id the runner recorded, a worker by
# a code root inside this script's private directory that is now gone, which no
# real home's worker can have.
#
# --run does the same for every work directory under <run-root>, then removes
# <run-root>. The runner calls it from its EXIT trap, and the sentinel the
# runner starts in a process group of its own calls it when the runner dies
# without running that trap (SIGKILL), so even a hard abort leaves nothing
# running once the sentinel has finished.
#
# Both modes refuse a directory that is not the runner's: <run-root>, or the
# parent of <work-dir>, must be an absolute directory carrying the runner's
# .fm-test-run-root marker, so a wrong argument can never delete another tree.
#
# Prints one line per group or worker it had to stop, and nothing otherwise.
# Exits 0 after a sweep, and 2 for an invalid argument or directory.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
RUN_ROOT_MARKER=.fm-test-run-root

reap_grace_seconds() {
  case "${FM_TEST_RUN_REAP_GRACE_SECONDS:-}" in
    ''|*[!0-9]*) printf '10\n' ;;
    *) printf '%s\n' "$FM_TEST_RUN_REAP_GRACE_SECONDS" ;;
  esac
}

reap_die() { printf 'fm-test-run-reap: %s\n' "$1" >&2; exit 2; }

reap_is_run_root() { # <dir>
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/$RUN_ROOT_MARKER" ] && [ ! -L "$1/$RUN_ROOT_MARKER" ]
}

# Stop whatever is left of the script's recorded process group. The id is used
# only while the group still has a member: a process-group id is not reused
# while any member lives, and the runner calls this as soon as the script's
# guard returns, so the id still names the script's own group.
reap_stop_group() { # <work-dir>
  local file="$1/script.pgid" pgid own_pgid waited=0 limit
  [ -f "$file" ] && [ ! -L "$file" ] || { rm -f -- "$file" 2>/dev/null; return 0; }
  pgid=$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*) rm -f -- "$file"; return 0 ;; esac
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')
  if [ "$pgid" -gt 1 ] && [ "$pgid" != "$own_pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    limit=$(( $(reap_grace_seconds) * 10 ))
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -KILL -- "-$pgid" 2>/dev/null || true
    printf 'stopped the processes still running in the script'"'"'s process group %s\n' "$pgid"
  fi
  rm -f -- "$file"
}

reap_remove_tree() { # <path>
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    find "$1" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  fi
  rm -rf -- "$1" 2>/dev/null || true
}

# Stop every remote job worker whose code root was inside <work-dir>. One ps
# scan decides whether any process names this directory at all, so a script
# that started no worker costs no full reaper pass.
reap_workers() { # <work-dir>
  local work=$1 physical uid
  physical=$(CDPATH='' cd "$work" 2>/dev/null && pwd -P) || physical=$work
  uid=$(id -u 2>/dev/null) || return 0
  ps -u "$uid" -o command= 2>/dev/null | awk -v a="$work/" -v b="$physical/" '
    index($0, "fm-remote-job-worker.sh") && (index($0, a) || index($0, b)) { found = 1 }
    END { exit !found }
  ' || return 0
  FM_REMOTE_JOB_REAP_SCOPE="$work" "$SCRIPT_DIR/fm-remote-job-reap-orphans.sh" || true
}

reap_script() { # <work-dir>
  local work=$1
  reap_stop_group "$work"
  reap_remove_tree "$work/tmp"
  reap_workers "$work"
  # A worker that was still writing its state could keep the first removal
  # from finishing.
  reap_remove_tree "$work/tmp"
}

case "${1:-}" in
  --script)
    [ "$#" -eq 2 ] || reap_die "usage: fm-test-run-reap.sh --script <work-dir> | --run <run-root>"
    work=${2%/}
    case "$work" in /*) ;; *) reap_die "work directory must be absolute: $work" ;; esac
    reap_is_run_root "$(dirname "$work")" || reap_die "not a fm-test-run work directory: $work"
    [ -d "$work" ] && [ ! -L "$work" ] || exit 0
    reap_script "$work"
    ;;
  --run)
    [ "$#" -eq 2 ] || reap_die "usage: fm-test-run-reap.sh --script <work-dir> | --run <run-root>"
    run_root=${2%/}
    [ -e "$run_root" ] || exit 0
    reap_is_run_root "$run_root" || reap_die "not a fm-test-run root: $run_root"
    for work in "$run_root"/*/; do
      work=${work%/}
      [ -d "$work" ] && [ ! -L "$work" ] || continue
      [ -e "$work/tmp" ] || [ -e "$work/script.pgid" ] || continue
      reap_script "$work"
    done
    reap_remove_tree "$run_root"
    ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    ;;
  *) reap_die "usage: fm-test-run-reap.sh --script <work-dir> | --run <run-root>" ;;
esac
