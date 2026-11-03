#!/bin/bash
# Drive one live bin/fm-pr-merge.sh run in a marked lab home against a real
# GitHub pull request, with the read-only gh guard first on PATH.
# Usage: run-live-scenario.sh <lab> <worktree-root> <out-file> <slug> <title> <pr-url> <project-name> <merge-tiers-file|ABSENT> [merge args...]
set -u
LAB=$1 ROOT=$2 OUT=$3 SLUG=$4 TITLE=$5 URL=$6 PROJECT=$7 TIERS=$8
shift 8
DRIVERS=$(cd "$(dirname "$0")" && pwd)
ID="lr-$SLUG"
GUARDBIN="$LAB/guardbin"
mkdir -p "$GUARDBIN" "$LAB/wt/$ID" "$LAB/projects/$PROJECT"
ln -sf "$DRIVERS/gh-readonly-guard.sh" "$GUARDBIN/gh"
ln -sf "$DRIVERS/gh-axi-readonly-guard.sh" "$GUARDBIN/gh-axi"
printf '%s\n' "window=fm-$ID" "worktree=$LAB/wt/$ID" "project=$LAB/projects/$PROJECT" "kind=ship" "mode=no-mistakes" > "$LAB/state/$ID.meta"
chmod 600 "$LAB/state/$ID.meta"
if [ "$TIERS" = ABSENT ]; then rm -f "$LAB/config/merge-tiers"; else cp "$TIERS" "$LAB/config/merge-tiers"; fi
GHLOG="$LAB/gh-$ID.log"
: > "$GHLOG"
RUN_PATH="$GUARDBIN:${FM_LIVE_JQ_DIR:+$FM_LIVE_JQ_DIR:}$PATH"
{
  echo "### $TITLE"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)   jq on PATH: $(PATH="$RUN_PATH" command -v jq) ($(PATH="$RUN_PATH" jq --version))"
  echo "pull request (real, read live from github.com): $URL"
  echo
  echo "\$LAB/config/merge-tiers:"
  if [ "$TIERS" = ABSENT ]; then echo "  (file absent)"; else sed 's/^/  /' "$LAB/config/merge-tiers"; fi
  echo
  echo "\$ FM_HOME=\$LAB bin/fm-pr-merge.sh $ID $URL $*"
} > "$OUT"
set +e
(
  cd "$ROOT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_LIVE_REAL_GH="$(command -v gh)" FM_LIVE_REAL_GH_AXI="$(command -v gh-axi)" \
    FM_LIVE_GH_LOG="$GHLOG" PATH="$RUN_PATH" \
    bin/fm-pr-merge.sh "$ID" "$URL" "$@"
) > "$LAB/out-$ID" 2>&1
rc=$?
{
  sed 's/^/  /' "$LAB/out-$ID"
  echo "exit status: $rc"
  echo
  echo "GitHub calls fm-pr-merge.sh made (through the read-only guard):"
  if [ -s "$GHLOG" ]; then sed 's/^/  /' "$GHLOG"; else echo "  (none)"; fi
  echo
  echo "task meta after the run:"
  sed 's/^/  /' "$LAB/state/$ID.meta"
  echo
} >> "$OUT"
echo "$SLUG rc=$rc"
