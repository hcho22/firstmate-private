#!/bin/bash
# Round-2 live board driver: builds the real bearings board in a disposable
# marked lab home, serves it through a real lavish-axi server isolated by its
# own state dir and port (never the operator's Lavish), and leaves it up for a
# headless browser to drive. gh is the write-guard beside this script.
# Usage: live-board-r2.sh up <firstmate-worktree> <lab-dir> <out-dir>
#        live-board-r2.sh down <firstmate-worktree> <lab-dir>
set -u
CMD=$1 W=$2 LAB=$3
DRIVERS=$(cd "$(dirname "$0")" && pwd)
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT=4792 LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_HOST=127.0.0.1
export FM_LIVE_GH_LOG="$LAB/gh-calls.log"
fm() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$LAB" PATH="$LAB/guardbin:$PATH" "$W/bin/$@"
}
case "$CMD" in
  up)
    OUT=$4
    "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
    mkdir -p "$LAB/guardbin" "$LAB/lavish-state" "$LAB/projects/firstmate-private" "$OUT"
    ln -s "$DRIVERS/gh-write-guard.sh" "$LAB/guardbin/gh"
    ln -s "$DRIVERS/gh-axi-write-guard.sh" "$LAB/guardbin/gh-axi"
    : > "$FM_LIVE_GH_LOG"
    printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
    printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
    git clone --quiet --no-checkout https://github.com/hcho22/firstmate-private.git "$LAB/wt" || exit 1
    for t in bd-24:24 bd-22:22; do
      id=${t%%:*} n=${t#*:}
      printf 'window=fm-%s\nworktree=%s\nproject=%s/projects/firstmate-private\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
        "$id" "$LAB/wt" "$LAB" > "$LAB/state/$id.meta"
      chmod 600 "$LAB/state/$id.meta"
      fm fm-pr-check.sh "$id" "https://github.com/hcho22/firstmate-private/pull/$n" >/dev/null 2>&1
    done
    cp "$DRIVERS/../board/payload.json" "$LAB/payload.json"
    ;;
  down)
    board="$LAB/.lavish/bearings-board.html"
    [ ! -f "$board" ] || lavish-axi end "$board" >/dev/null 2>&1 || true
    fm fm-procevent.sh sweep-home >/dev/null 2>&1 || true
    lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
    ;;
esac
