#!/usr/bin/env bash
# Diagnostic: the watcher's exact escalation-time call, crew_progress_evidence
# over the real bin/fm-crew-state.sh (axi status through forwarder-quiet.sh), with
# a <secs>-old anchor, repeated; logs the crew-state line, verdict, and timing.
# usage: probe-evidence.sh <fixture-dir with fakebin+state> <secs> <samples> <interval>
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
F=$1 W=$2 N=$3 I=$4
export PATH="$F/fakebin:$PATH" FM_LIVE_RUN_ID=01M4Z2NDNVFJXVP6PM2K4SF305 FM_STATE_OVERRIDE="$F/state" TMUX_TMPDIR="$F/tmux"
export FM_QUIET_SINCE=${FM_QUIET_SINCE:-$(( $(date +%s) - 180 ))}
a=$(mktemp /tmp/fmr2-anchor.XXXX)
k=0
while [ $k -lt $N ]; do
  touch -t "$(date -v-${W}S +%Y%m%d%H%M.%S)" "$a"
  t0=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  line=$("$WT/bin/fm-crew-state.sh" wedgelive 2>&1)
  t1=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  ev=$(bash -c '. "$1/bin/fm-classify-lib.sh"; crew_progress_evidence wedgelive "$2" "$3" "$4"; echo " rc=$?"' _ "$WT" "$F/state" "$a" "$W")
  t2=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  printf '[%s] crew-state (%.1fs): %s\n           crew_progress_evidence (%.1fs): %s\n' "$(date +%T)" "$(echo "$t1 - $t0" | bc)" "$line" "$(echo "$t2 - $t1" | bc)" "$ev"
  k=$((k+1)); sleep "$I"
done
rm -f "$a"
