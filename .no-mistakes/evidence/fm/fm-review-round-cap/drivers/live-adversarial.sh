#!/usr/bin/env bash
# Live, real no-mistakes CLI: check must fail closed to `unknown` (exit 1) when it
# cannot count, and refuse bad usage (exit 2) - never a silent under-cap.
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
R="$WT/bin/fm-nm-rounds.sh"
c() { local dir=$1; shift; echo "\$ (cd $dir && fm-nm-rounds.sh $*)"; (cd "$dir" && "$R" "$@"); echo "[exit $?]"; echo; }
echo "# a copy where no-mistakes is not set up (this gate worktree, detached HEAD)"
c "$WT" check --step review
echo "# a real registered repo whose real run never ran the review step (review skipped)"
c /Users/hcho/Developer/CompeteIntel check --step review
echo "# same run, a step that did run but took no fix round"
c /Users/hcho/Developer/CompeteIntel check --step rebase
echo "# bad usage"
c /tmp check
c /tmp check --step 'review;rm'
c /tmp check --step review --cap 0
c /tmp check --step review --cap 03
c /tmp check --step review --cap x
c /tmp check --step review --out-dir relative/dir
c /tmp check --step review --out-dir /nonexistent-dir-xyz
c /tmp check --step review --worktree /tmp
c /tmp report --project x
c /tmp record
