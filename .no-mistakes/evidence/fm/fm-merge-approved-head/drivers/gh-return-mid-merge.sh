#!/bin/bash
# The write-guard (gh-write-guard.sh beside this script) plus one timing hook:
# when $FM_LIVE_RETURN_TRIGGER exists and the call is the merge's base-branch
# read (`gh api repos/<o>/<r>/branches/<base>`, its last GitHub read before the
# first approved-head verify), the captain "returns": the real
# `fm-afk-contract.sh archive` runs in the lab home before the read is
# answered, and the trigger is consumed so it fires once.
DIR=$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)
if [ -n "${FM_LIVE_RETURN_TRIGGER-}" ] && [ -f "$FM_LIVE_RETURN_TRIGGER" ] \
  && [ "${1-}" = api ] && case "${2-}" in repos/*/branches/*) true ;; *) false ;; esac; then
  rm -f "$FM_LIVE_RETURN_TRIGGER"
  printf 'HOOK captain returns: fm-afk-contract.sh archive -> %s\n' \
    "$("$FM_LIVE_FM_BIN/fm-afk-contract.sh" archive 2>&1 | tr '\n' ' ')" >> "$FM_LIVE_GH_LOG"
fi
exec "$DIR/gh-write-guard.sh" "$@"
