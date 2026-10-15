. /tmp/fmwq.NJHD/defs.sh
n=0; ok=0; skipped=0; unsafe=0; other=0
while [ $n -lt ${REPS:-20} ]; do
  dir=$(make_case "c$n"); state="$dir/state"; pids=
  i=1; while [ $i -le 40 ]; do append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" & pids="$pids $!"; i=$((i+1)); done
  FM_STATUS_PRESENTATION_LOCK_TIMEOUT=${T:-1} FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/d.out" 2> "$dir/d.err"; rc=$?
  for p in $pids; do wait $p; done
  if [ $rc -eq 0 ] && grep -q "WAKE DRAIN SKIPPED" "$dir/d.out"; then skipped=$((skipped+1))
  elif [ $rc -eq 0 ]; then ok=$((ok+1))
  elif grep -q "could not be acquired safely" "$dir/d.err"; then unsafe=$((unsafe+1)); echo "rep $n: rc=$rc"; grep -E "INSTR|could not" $dir/d.err
  else other=$((other+1)); echo "rep $n: rc=$rc other: $(head -3 $dir/d.err)"; fi
  rm -rf "$dir"; n=$((n+1))
done
echo "reps=$n drained=$ok skipped_on_live_holder=$skipped unsafe_acquire_failure=$unsafe other=$other"
