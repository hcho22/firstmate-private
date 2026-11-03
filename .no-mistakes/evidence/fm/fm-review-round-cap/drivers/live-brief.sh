#!/usr/bin/env bash
# Live: scaffold real ship briefs in a lab home and read the emitted no-mistakes
# contract the worker receives; run the counter command exactly as the brief names it.
set -u
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB/live-brief; WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
for mode in no-mistakes direct-PR; do
  echo "\$ FM_HOME=<lab> bin/fm-brief.sh cap-$mode-b1 demo --mode $mode"
  E "$WT/bin/fm-brief.sh" "cap-$mode-b1" demo --mode "$mode"; echo "[exit $?]"
done
nm=$(find "$LAB/data" -path '*cap-no-mistakes-b1/brief.md' | head -1)
dp=$(find "$LAB/data" -path '*cap-direct-PR-b1/brief.md' | head -1)
cp "$nm" "$EV/no-mistakes-brief.md"; cp "$dp" "$EV/direct-PR-brief.md"
echo; echo "# no-mistakes brief: firstmate-specific rules block"
awk '/firstmate-specific rules layer on top/{on=1} on{print} /banned fleet-wide/{exit}' "$nm"
echo; echo "# direct-PR brief mentions of the cap: $(grep -c 'Fix rounds are capped' "$dp")"
cmd=$(sed -n 's/.*run `\([^`]*fm-nm-rounds\.sh\) check --step <step>.*/\1/p' "$nm" | head -1)
echo; echo "# the counter the brief names: $cmd"
echo "\$ $cmd check --step review   (from a copy with no initialized pipeline)"
(cd "$LAB" && "$cmd" check --step review); echo "[exit $?]"
