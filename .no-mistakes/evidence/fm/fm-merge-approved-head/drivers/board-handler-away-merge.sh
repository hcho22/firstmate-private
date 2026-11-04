#!/bin/bash
# The board-wake handler path after a real Merge now click: read the answer and
# the head the card showed from the captured Lavish result, record that head,
# then the captain goes away and the away merge runs (gh writes refused).
# Usage: board-handler-away-merge.sh <firstmate-worktree> <lab-dir> <result-file>
set -u
W=$1 LAB=$2 R=$3
D="$(cd "$(dirname "$0")" && pwd)/live-board-away.sh"
URL=https://github.com/hcho22/nodebase/pull/2
run() { local rc=0; printf '$ bin/%s\n' "$*"; $D fm "$W" "$LAB" "$@" > "$LAB/run.out" 2>&1 || rc=$?; grep -v -e '^●' -e '^WARNING: watcher' "$LAB/run.out"; printf '(exit %s)\n' "$rc"; }
{
printf '# b06: the Merge now click on the board, recorded as the head the card showed; the captain then goes away, and the away merge lands only that head\n'
printf '## wake queued for firstmate (state/.wake-queue)\n'; cat "$LAB/state/.wake-queue"
run fm-procevent-lavish.sh answers "$R"
run fm-procevent-lavish.sh heads "$R"
H=$(awk -F'\t' '$1=="merge.bd-nb"{print $2}' "$LAB/run.out")
run fm-approved-head.sh record bd-nb "$URL" "$H"
printf '## bd-nb meta after the handler recorded the card head\n'; grep -E '^(approved_head|pr|pr_head)=' "$LAB/state/bd-nb.meta"
run fm-afk-contract.sh enter --words "merge the nodebase PR I just clicked Merge now on"
n=$(wc -l < "$LAB/gh-calls.log")
run fm-pr-merge.sh bd-nb "$URL"
printf '## gh writes the guard refused during the merge (where the real merge would happen)\n'
tail -n +$((n + 1)) "$LAB/gh-calls.log" | grep '^BLOCKED-WRITE' || printf '(none)\n'
} 2>&1 | sed -e "s#$LAB#\$LAB#g" -e "s#$W#<worktree>#g"
