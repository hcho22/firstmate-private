#!/usr/bin/env bash
# The exact state the 267c59f wake-lock fix handles, driven through the real
# bin/fm-wake-drain.sh: when the drain's bounded queue-lock wait hits its 1s
# deadline, the lock is mid-handover (its symlink points at an owner dir that
# records no pid yet). Kept fresh with FM_LOCK_STALE_AFTER=30 so nothing steals it.
#   between-holders  0.3s after the wait gives up, a live holder's pid appears
#   freed            0.3s after the wait gives up, the lock is released
#   never-resolves   the lock never shows an owner (a malformed lock)
# usage: wake-lock-between-holders.sh <label>=<root> [...]
set -u
NONGIT=$(mktemp -d /tmp/fmr2-nongit.XXXX)
for spec in "$@"; do
  l=${spec%%=*} root=${spec#*=}
  for mode in between-holders freed never-resolves; do
    S=$(mktemp -d /tmp/fmr2-wl.XXXX); S=$(cd "$S" && pwd -P)
    for k in 1 2 3; do FM_STATE_OVERRIDE="$S" bash -c '. "$1"; fm_wake_append signal "k$2" "signal: k$2"' _ "$root/bin/fm-wake-lib.sh" "$k"; done
    O=$(mktemp -d "$S/.wake-queue.lock.owner.XXXXXX")
    ln -s "$O" "$S/.wake-queue.lock"
    sleep 600 & H=$!
    if [ "$mode" != never-resolves ]; then
      (
        seen=0
        for _ in $(seq 1 400); do
          if pgrep -f "_fm_lock_acquire_wait_handoff.*$S/.wake-queue.lock" >/dev/null; then seen=1
          elif [ "$seen" = 1 ]; then break; fi
          sleep 0.02
        done
        sleep 0.3
        if [ "$mode" = between-holders ]; then printf '%s\n' "$H" > "$O/pid"; else rm -f "$S/.wake-queue.lock"; rm -rf "$O"; fi
      ) &
      W=$!
    fi
    start=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    FM_ROOT_OVERRIDE="$NONGIT" FM_LOCK_STALE_AFTER=30 FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 FM_STATE_OVERRIDE="$S" \
      "$root/bin/fm-wake-drain.sh" > "$S/d.out" 2> "$S/d.err"; rc=$?
    end=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    [ "$mode" = never-resolves ] || wait "$W" 2>/dev/null
    kill "$H" 2>/dev/null; wait "$H" 2>/dev/null
    msg=$(grep -h -E 'WAKE DRAIN SKIPPED|could not be acquired safely' "$S/d.out" "$S/d.err" | head -1)
    [ -n "$msg" ] || msg="$(awk -F '\t' 'NF == 5 { c++ } END { print c + 0 }' "$S/d.out") queued records presented"
    printf '%-7s %-16s exit=%s (%.1fs): %s\n' "$l" "$mode" "$rc" "$(echo "$end - $start" | bc)" "$msg"
    rm -rf "$S"
  done
done
rm -rf "$NONGIT"
