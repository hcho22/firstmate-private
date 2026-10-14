#!/usr/bin/env bash
# Diagnose what crew_worktree_process_started_since sees while a worker runs the
# repo's own test command (bin/fm-test-run.sh) in the foreground of its
# worktree. Every <step> seconds, with a quiet window of <window> seconds, it
# calls the REAL probe and lists the probe's candidate roots (the nearest
# pre-window ancestor of each young process whose parent is also young) with
# each root's current directory.
#   diag-fg-probe.sh <code-root> <window> <step> <duration> <test-script>...
set -u
CODE=$1 WINDOW=$2 STEP=$3 DUR=$4; shift 4
T=$(mktemp -d /tmp/fmlvd.XXXXXX); T=$(cd "$T" && pwd -P); cd "$T" || exit 1
WT="$T/wt"; mkdir -p "$WT" "$T/state"
(cd "$CODE" && tar --exclude ./.git -cf - .) | (cd "$WT" && tar -xf -)
git -C "$WT" init -q -b fm/lv && git -C "$WT" -c user.name=t -c user.email=t@t add -A && git -C "$WT" -c user.name=t -c user.email=t@t commit -qm seed
printf 'window=x:fm-lv\nkind=ship\nworktree=%s\n' "$WT" > "$T/state/lv.meta"
(cd "$WT" && unset TMUX TMUX_PANE && exec bin/fm-test-run.sh "$@") > "$T/run.log" 2>&1 &
RUNNER=$!
trap 'kill $RUNNER 2>/dev/null; sleep 2; rm -rf "$T"' EXIT
# shellcheck disable=SC1091
. "$CODE/bin/fm-classify-lib.sh"
START=$(date +%s)
sleep "$WINDOW"
while [ $(( $(date +%s) - START )) -lt "$DUR" ] && kill -0 "$RUNNER" 2>/dev/null; do
  touch -t "$(date -r $(( $(date +%s) - WINDOW )) +%Y%m%d%H%M.%S)" "$T/anchor"
  if crew_worktree_process_started_since lv "$T/state" "$T/anchor"; then v=EVIDENCE; else v=none; fi
  cur=$(grep -E '^FM_TEST_BEGIN' "$T/run.log" | tail -1 | awk '{print $3}')
  roots=$(LC_ALL=C ps -A -o pid= -o ppid= -o etime= | awk -v w="$WINDOW" '
    NF >= 3 { e = $3; d = 0; if (index(e, "-")) { split(e, dp, "-"); d = dp[1]; e = dp[2] }
      n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; ppid[$1] = $2; age[$1] = s + d * 86400 }
    END { for (p in age) { if (age[p] >= w) continue; q = ppid[p]; hops = 0
        if (!(q in age) || age[q] >= w) continue
        while ((q in age) && age[q] < w && hops < 64) { q = ppid[q]; hops++ }
        if ((q in age) && !(q in seen)) { seen[q] = 1; print q } } }')
  printf '[t+%3ss] probe=%-8s running=%s\n' "$(( $(date +%s) - START ))" "$v" "$cur"
  for r in $roots; do
    cwd=$(lsof -a -d cwd -p "$r" -Fn 2>/dev/null | sed -n 's/^n//p')
    case "$cwd" in "$WT"|"$WT"/*) tag=IN-WT ;; *) tag=elsewhere ;; esac
    case "$(ps -o command= -p "$r")" in *"$WT"*|*fm-test-run*|*tests/*) printf '    root %s %-9s cwd=%s cmd=%s\n' "$r" "$tag" "${cwd/#$T/<T>}" "$(ps -o command= -p "$r" | cut -c1-70)" ;; esac
  done
  sleep "$STEP"
done
