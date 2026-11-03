#!/usr/bin/env bash
# S6a: arm a task's busy state with bin/fm-busy-event.sh, then fire W concurrent
# `apply` events for it. The writer lock serializes seq advancement, so the
# final record must read seq = 1 + (applies that exited 0). A lock two writers
# can both hold loses updates: the final seq comes out lower.
# usage: s6a-busy-event-lock.sh <tree> <mkdir-dir|host> [rounds] [writers]
set -u
root=$1 mk=$2 rounds=${3:-10} writers=${4:-16}
[ "$mk" = host ] || PATH="$mk:$PATH"; export PATH
echo "tree=$root mkdir=$(command -v mkdir) ($(mkdir --version 2>&1 | head -1)) rounds=$rounds writers=$writers"
lost=0
for r in $(seq 1 "$rounds"); do
  st=$(mktemp -d /tmp/fmnm-busy.XXXXXX)
  gen=$("$root/bin/fm-busy-event.sh" arm "$st" t1)
  for w in $(seq 1 "$writers"); do
    ( "$root/bin/fm-busy-event.sh" apply "$st" t1 idle --gen "$gen" --source drv --event e$w 2>/dev/null && echo ok ) &
  done > "$st.ok"
  wait
  okc=$(grep -c ok "$st.ok")
  seq=$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$st/t1.busy-state" 2>/dev/null)
  expected=$((okc + 1))
  verdict=consistent; [ "$seq" = "$expected" ] || { verdict=LOST-UPDATES; lost=$((lost + 1)); }
  printf 'round %2s: applies_ok=%s final_seq=%s expected=%s %s\n' "$r" "$okc" "$seq" "$expected" "$verdict"
  rm -rf "$st" "$st.ok"
done
echo "rounds with lost updates: $lost / $rounds"
