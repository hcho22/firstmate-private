#!/bin/bash
# Live board driver for this round: builds the real bearings board in a
# disposable marked lab home with one merge card for
# https://github.com/hcho22/nodebase/pull/2, served by a real lavish-axi isolated
# by its own state dir and port (never the operator's Lavish), and leaves it up
# for a headless browser to drive. gh is the write-guard beside this script.
# Usage: live-board-away.sh up <firstmate-worktree> <lab-dir> <out-dir>
#        live-board-away.sh fm <firstmate-worktree> <lab-dir> <script> <args...>
#        live-board-away.sh down <firstmate-worktree> <lab-dir>
set -u
CMD=$1 W=$2 LAB=$3
shift 3
DRIVERS=$(cd "$(dirname "$0")" && pwd)
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT=4793 LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_HOST=127.0.0.1
export FM_LIVE_GH_LOG="$LAB/gh-calls.log"
fm() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$LAB" PATH="$LAB/guardbin:$PATH" "$W/bin/$@"
}
case "$CMD" in
  up)
    OUT=$1
    "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
    mkdir -p "$LAB/guardbin" "$LAB/lavish-state" "$LAB/projects/nodebase" "$OUT"
    ln -s "$DRIVERS/gh-write-guard.sh" "$LAB/guardbin/gh"
    ln -s "$DRIVERS/gh-axi-write-guard.sh" "$LAB/guardbin/gh-axi"
    ln -s /usr/bin/jq "$LAB/guardbin/jq"
    : > "$FM_LIVE_GH_LOG"
    printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
    printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
    git clone --quiet --no-checkout https://github.com/hcho22/nodebase.git "$LAB/wt" || exit 1
    printf 'window=fm-bd-nb\nworktree=%s\nproject=%s/projects/nodebase\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
      "$LAB/wt" "$LAB" > "$LAB/state/bd-nb.meta"
    chmod 600 "$LAB/state/bd-nb.meta"
    fm fm-pr-check.sh bd-nb https://github.com/hcho22/nodebase/pull/2 >/dev/null 2>&1
    cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "fm-lab board",
  "generated": "2026-11-04T05:20Z",
  "prs_live": true,
  "captains_call": [
    {
      "key": "merge.bd-nb",
      "type": "merge",
      "repo": "nodebase",
      "title": "Merge: 03 - trpc_setup",
      "detail": "Mergeable and clean at the live head; no required checks.",
      "pr_url": "https://github.com/hcho22/nodebase/pull/2",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ]
    }
  ],
  "underway": [
    { "repo": "nodebase", "name": "bd-nb", "id": "bd-nb", "state": "pr-ready", "doing": "waiting for the merge word", "kind": "ship" }
  ],
  "landed": [],
  "charted": []
}
JSON
    ;;
  fm) fm "$@" ;;
  down)
    board="$LAB/.lavish/bearings-board.html"
    [ ! -f "$board" ] || lavish-axi end "$board" >/dev/null 2>&1 || true
    fm fm-procevent.sh sweep-home >/dev/null 2>&1 || true
    lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
    ;;
esac
