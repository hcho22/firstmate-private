#!/usr/bin/env bash
# Wake-queue lock contention, live: the real bin/fm-wake-drain.sh racing 40
# concurrent fm_wake_append writers (tests/fm-wake-queue.test.sh
# test_concurrent_append_and_drain), drain deadline forced to 1s so the bounded
# lock wait times out under churn. Alternates the given bin roots per rep.
# usage: wake-stress.sh <reps> <label>=<root> [<label>=<root> ...]
set -u
REPS=$1; shift
T=$(mktemp -d /tmp/fmr2-wake.XXXX)
NONGIT=$(mktemp -d /tmp/fmr2-nongit.XXXX)
RES="$T/results"; : > "$RES"
n=0
while [ $n -lt "$REPS" ]; do
  for spec in "$@"; do
    l=${spec%%=*} root=${spec#*=}
    dir="$T/$l-$n"; state="$dir/state"; mkdir -p "$state"; pids=
    i=1
    while [ $i -le 40 ]; do
      FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$root/bin/fm-wake-lib.sh" signal "status-$i" "signal: $state/status-$i.status" &
      pids="$pids $!"; i=$((i+1))
    done
    FM_ROOT_OVERRIDE="$NONGIT" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 FM_STATE_OVERRIDE="$state" "$root/bin/fm-wake-drain.sh" > "$dir/d.out" 2> "$dir/d.err"; rc=$?
    for p in $pids; do wait "$p"; done
    if [ $rc -eq 0 ] && grep -q "WAKE DRAIN SKIPPED" "$dir/d.out" "$dir/d.err"; then r=skipped_on_live_holder
    elif [ $rc -eq 0 ]; then r=drained
    elif grep -q "could not be acquired safely" "$dir/d.err"; then r=unsafe_acquire_failure; echo "  $l rep $n: rc=$rc $(grep 'could not' "$dir/d.err")"
    else r=other; echo "  $l rep $n: rc=$rc other: $(head -2 "$dir/d.err" | tr '\n' ' ')"; fi
    # Every appended record must still be durable after the race.
    FM_ROOT_OVERRIDE="$NONGIT" FM_STATE_OVERRIDE="$state" "$root/bin/fm-wake-drain.sh" > "$dir/d2.out" 2>/dev/null
    c=$(awk -F '\t' 'NF == 5 { c++ } END { print c + 0 }' "$dir/d2.out")
    [ "$c" -eq 40 ] || { echo "  $l rep $n: only $c of 40 records durable after the race"; r="$r,lost"; }
    printf '%s %s\n' "$l" "$r" >> "$RES"
    rm -rf "$dir"
  done
  n=$((n+1))
done
for spec in "$@"; do l=${spec%%=*}
  awk -v l="$l" -v reps="$REPS" '$1 == l { c[$2]++ } END { printf "%s: reps=%d drained=%d skipped_on_live_holder=%d unsafe_acquire_failure=%d other=%d lost_records=%d\n", l, reps, c["drained"], c["skipped_on_live_holder"], c["unsafe_acquire_failure"], c["other"], c["drained,lost"] + c["skipped_on_live_holder,lost"] + c["unsafe_acquire_failure,lost"] + c["other,lost"] }' "$RES"
done
rm -rf "$T" "$NONGIT"
