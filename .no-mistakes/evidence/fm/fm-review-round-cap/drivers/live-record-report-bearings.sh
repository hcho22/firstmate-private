#!/usr/bin/env bash
# Live record -> report -> bearings in a disposable lab home. Task records point
# at REAL fleet task copies (read only): the real no-mistakes CLI resolves their
# repository, and the real state database (opened mode=ro) supplies the runs.
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB/live-record
REP=/Users/hcho/.treehouse-fm-private/.treehouse/RepToday-ef4848/1/RepToday
NMC=/Users/hcho/.treehouse/no-mistakes-2ccc85/1/no-mistakes
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
printf 'worktree=%s\nproject=RepToday\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\npr=https://github.com/hcho22/RepToday/pull/221\n' "$REP" > "$LAB/state/reptoday-hands-free-sessions.meta"
printf 'worktree=%s\nproject=no-mistakes\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\n' "$NMC" > "$LAB/state/no-mistakes-evidence-import-authority-us004.meta"
printf 'worktree=%s\nproject=Calm\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\n' "$LAB/gone-copy" > "$LAB/state/calm-gone.meta"
printf 'worktree=%s\nkind=secondmate\n' "$LAB" > "$LAB/state/sm-one.meta"
run() { echo "\$ $*"; env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; echo "[exit $?]"; echo; }
R="$WT/bin/fm-nm-rounds.sh"
echo "# lab home: $LAB (removed on exit)"; echo
run "$R" record reptoday-hands-free-sessions
run "$R" record no-mistakes-evidence-import-authority-us004
run "$R" record calm-gone
echo "# retried cleanup: the same task incarnation must not be counted twice"
run "$R" record reptoday-hands-free-sessions
echo "# adversarial: a secondmate and an unknown id are refused"
run "$R" record sm-one
run "$R" record no-such-task
echo "# ledger lines: $(wc -l < "$LAB/data/pipeline-rounds.jsonl")"
cp "$LAB/data/pipeline-rounds.jsonl" "$EV/pipeline-rounds.jsonl"
jq . "$LAB/data/pipeline-rounds.jsonl" > "$EV/pipeline-rounds.pretty.json"
echo "# rounds_to_pass per record"; jq -c '{task, source, reason, since, runs: [.runs[] | {id, status, steps: [.steps[] | select(.fix_rounds > 0)]}], rounds_to_pass}' "$LAB/data/pipeline-rounds.jsonl"; echo
run "$R" report
run "$R" report --json --limit 1
echo "# bearings snapshot (real bin/fm-bearings-snapshot.sh) - rounds surfaces only"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_BEARINGS_ROUNDS=2 "$WT/bin/fm-bearings-snapshot.sh" > "$EV/bearings.toon" 2> "$EV/bearings.stderr"; echo "[toon exit $?]"
sed -n '/^rounds_by_project/,/^[a-z_]*[\[:]/p' "$EV/bearings.toon" | sed '$d'
sed -n '/^rounds_per_pr/,/^[a-z_]*[\[:]/p' "$EV/bearings.toon" | sed '$d'
sed -n '/^omitted/,$p' "$EV/bearings.toon"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_BEARINGS_ROUNDS=2 "$WT/bin/fm-bearings-snapshot.sh" --json > "$EV/bearings.json" 2>>"$EV/bearings.stderr"; echo "[json exit $?]"
jq '{rounds_by_project, rounds_per_pr, omitted: [.omitted[] | select(.surface | test("round"))]}' "$EV/bearings.json"
echo; echo "# adversarial: the ledger is unreadable (a directory in its place)"
mv "$LAB/data/pipeline-rounds.jsonl" "$LAB/data/ledger.bak"; mkdir "$LAB/data/pipeline-rounds.jsonl"
run "$R" report
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq '{rounds_by_project, rounds_per_pr, omitted: [.omitted[] | select(.surface | test("round"))]}'
