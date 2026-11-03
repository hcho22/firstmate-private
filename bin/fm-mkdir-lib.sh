#!/usr/bin/env bash
# fm-mkdir-lib.sh - fm_mkdir_exclusive, the one owner of creating a directory
# that must fail when its path already exists, including when another process
# creates it at the same moment. Firstmate's claims and locks rely on that
# failure, so every directory that serves as a claim or lock is made here.
# It needs nothing beyond mkdir itself and has no source-time side effects.
#
# uutils (Rust) coreutils mkdir, the default mkdir from Ubuntu 25.10 on, checks
# for the path and then creates it, and exits 0 when another process created it
# in between (uutils/coreutils#14181), so two callers can both win one claim.
# Its -v line is printed only by the call that really created the directory,
# so on a uutils host a claim counts only when that line appears. Every other
# mkdir (GNU, BSD, BusyBox) already fails on an existing path and is used as is.

# fm_mkdir_exclusive <dir> [mode]: exits 0 only when this call created <dir>.
# With a mode, the directory gets that octal mode, as with mkdir -m.
fm_mkdir_exclusive() {
  local fm_mkdir_created
  if [ -z "${FM_MKDIR_EXCLUSIVE_VERIFY:-}" ]; then
    case "$(mkdir --version 2>/dev/null)" in
      *uutils*) FM_MKDIR_EXCLUSIVE_VERIFY=1 ;;
      *) FM_MKDIR_EXCLUSIVE_VERIFY=0 ;;
    esac
  fi
  if [ "$FM_MKDIR_EXCLUSIVE_VERIFY" = 0 ]; then
    if [ "$#" -ge 2 ]; then
      mkdir -m "$2" -- "$1"
    else
      mkdir -- "$1"
    fi
    return
  fi
  if [ "$#" -ge 2 ]; then
    fm_mkdir_created=$(mkdir -v -m "$2" -- "$1") || return 1
  else
    fm_mkdir_created=$(mkdir -v -- "$1") || return 1
  fi
  [ -n "$fm_mkdir_created" ] && return 0
  printf "mkdir: cannot create directory '%s': File exists\n" "$1" >&2
  return 1
}
