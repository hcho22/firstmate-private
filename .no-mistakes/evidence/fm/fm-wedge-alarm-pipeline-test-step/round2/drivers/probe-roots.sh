#!/usr/bin/env bash
# Diagnostic: while a long command runs in the run's copy, list the pre-window
# roots the process probe finds (same ps+awk as _crew_fresh_tree_under), their
# cwd, and command, plus the probe's verdict, for a window of <secs>.
# usage: probe-roots.sh <secs-window> <samples> <interval>
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
RUN=01M4Z2NDNVFJXVP6PM2K4SF305
W=$1 N=$2 I=$3
a=$(mktemp /tmp/fmr2-anchor.XXXX)
k=0
while [ $k -lt $N ]; do
  touch -t "$(date -v-${W}S +%Y%m%d%H%M.%S)" "$a"
  now=$(date +%s)
  echo "[$(date +%T)] window ${W}s"
  LC_ALL=C ps -A -o pid= -o ppid= -o etime= | awk -v w="$W" '
    NF >= 3 { e=$3; d=0; if (index(e,"-")) { split(e,dp,"-"); d=dp[1]; e=dp[2] }
      n=split(e,t,":"); s=0; for(i=1;i<=n;i++) s=s*60+t[i]; ppid[$1]=$2; age[$1]=s+d*86400 }
    END { for (p in age) { if (age[p] >= w) continue; q=ppid[p]; hops=0
        if (!(q in age) || age[q] >= w) continue
        while ((q in age) && age[q] < w && hops < 64) { q=ppid[q]; hops++ }
        if ((q in age) && !(q in seen)) { seen[q]=1; cnt[q]=0 } if (q in seen) cnt[q]++ }
      for (q in seen) print q, cnt[q] }' | while read -r q c; do
    cwd=$(lsof -a -d cwd -p "$q" -Fn 2>/dev/null | sed -n 's/^n//p')
    case "$cwd" in "$WT"|"$WT"/*) tag=IN-RUN-COPY ;; *) tag=elsewhere ;; esac
    printf '  root %s (%s fresh) %s cwd=%s cmd=%s\n' "$q" "$c" "$tag" "$cwd" "$(ps -o command= -p "$q" | cut -c1-90)"
  done | grep -E 'IN-RUN-COPY|fm-test|crew-state|watch-triage' 
  v=$(bash -c '. "$1/bin/fm-classify-lib.sh"; crew_run_step_process_started_since "$2" "$3" 0 && echo evidence || echo none' _ "$WT" "$RUN" "$a")
  echo "  probe verdict (crew_run_step_process_started_since): $v"
  k=$((k+1)); sleep "$I"
done
rm -f "$a"
