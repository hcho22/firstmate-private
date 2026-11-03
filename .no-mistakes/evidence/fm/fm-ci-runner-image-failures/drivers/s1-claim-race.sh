#!/usr/bin/env bash
# S1: race N callers on one claim directory, R rounds, and count winners per round.
# usage: s1-claim-race.sh <worktree> <mkdir-bin-dir-or-host> <mode: plain|exclusive> [rounds] [racers]
set -u
wt=$1 mk=$2 mode=$3 rounds=${4:-40} racers=${5:-12}
[ "$mk" = host ] || PATH="$mk:$PATH"
export PATH
work=$(mktemp -d /tmp/fmnm-race.XXXXXX)
echo "mkdir under test: $(command -v mkdir) -> $(mkdir --version 2>&1 | head -1)"
echo "claim primitive: $mode   rounds=$rounds racers/round=$racers"
multi=0 zero=0
for r in $(seq 1 "$rounds"); do
  out=$(bash -c '
    . "$1/bin/fm-mkdir-lib.sh"
    for i in $(seq 1 "$4"); do
      if [ "$3" = plain ]; then (mkdir "$2" 2>/dev/null && echo won) &
      else (fm_mkdir_exclusive "$2" 2>/dev/null && echo won) & fi
    done
    wait' _ "$wt" "$work/claim-$r" "$mode" "$racers")
  w=$(printf '%s\n' "$out" | grep -c won)
  [ "$w" -gt 1 ] && multi=$((multi + 1))
  [ "$w" -eq 0 ] && zero=$((zero + 1))
  printf '%s ' "$w"
done
echo
echo "rounds with more than one winner: $multi / $rounds ; rounds with no winner: $zero / $rounds"
rm -rf "$work"
