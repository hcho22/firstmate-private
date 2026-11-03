#!/usr/bin/env bash
# Regression, live: bin/fm-pipeline-spend.sh now attributes runs through the
# shared fm_nm_task_run_attribution. For the same real task copy, its record must
# name exactly the runs the rounds record names.
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
REP=/Users/hcho/.treehouse-fm-private/.treehouse/RepToday-ef4848/1/RepToday
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; : > "$LAB/config/pipeline-spend"  # spend recording is opt-in
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
printf 'worktree=%s\nproject=RepToday\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\npr=https://github.com/hcho22/RepToday/pull/221\n' "$REP" > "$LAB/state/rt.meta"
echo "\$ fm-pipeline-spend.sh record rt"; E "$WT/bin/fm-pipeline-spend.sh" record rt; echo "[exit $?]"
echo "\$ fm-nm-rounds.sh record rt"; E "$WT/bin/fm-nm-rounds.sh" record rt; echo "[exit $?]"
echo "spend  runs: $(jq -c '[.runs[].id]' "$LAB/data/pipeline-spend.jsonl")"
echo "spend  attribution: $(jq -c '{repo, branch, since, source}' "$LAB/data/pipeline-spend.jsonl")"
echo "rounds runs: $(jq -c '[.runs[].id]' "$LAB/data/pipeline-rounds.jsonl")"
echo "rounds attribution: $(jq -c '{repo, branch, since, source}' "$LAB/data/pipeline-rounds.jsonl")"
[ "$(jq -c '[.runs[].id]' "$LAB/data/pipeline-spend.jsonl")" = "$(jq -c '[.runs[].id]' "$LAB/data/pipeline-rounds.jsonl")" ] && echo "SAME RUNS: yes" || echo "SAME RUNS: NO"
