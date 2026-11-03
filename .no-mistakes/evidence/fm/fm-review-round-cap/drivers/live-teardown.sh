#!/usr/bin/env bash
# Live: the real bin/fm-teardown.sh cleans up a finished no-mistakes ship task in
# a disposable lab home (private tmux socket, lab project + origin, and a task
# copy leased from a lab-rooted pool by the real treehouse)
# and leaves a rounds-to-pass record in the lab's data/pipeline-rounds.jsonl,
# read before it removes the task branch and state/<id>.meta. The lab copy is not
# a no-mistakes repo (this gate may not init one), so the record must say
# `unavailable` with the CLI's reason - and cleanup must still complete.
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB/live-teardown
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
E() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
G() { git -c user.email=lab@lab -c user.name=lab "$@"; }
ID=${1:-lab-rounds-zz9}
git init -q --bare "$LAB/origin.git"
G init -q -b main "$LAB/projects/demo"; G -C "$LAB/projects/demo" commit -q --allow-empty -m init
G -C "$LAB/projects/demo" remote add origin "$LAB/origin.git"; G -C "$LAB/projects/demo" push -q origin main
export TREEHOUSE_ROOT="$LAB/pool"
COPY=$(cd "$LAB/projects/demo" && treehouse get --lease -b "fm/$ID" 2>/dev/null)
[ -d "$COPY" ] || { echo "treehouse get failed"; exit 1; }
echo "# treehouse leased task copy: ${COPY#$LAB/}"
G -C "$COPY" commit -q --allow-empty -m "shippable work"
G -C "$COPY" push -q origin "fm/$ID"; G -C "$LAB/projects/demo" fetch -q origin
tmux new-session -d -s firstmate -n anchor "sleep 600"
tmux new-window -d -t firstmate -n "fm-$ID" "sleep 600"
printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=%s\nspawn_gen=lab-g1\npr=https://github.com/lab/demo/pull/1\n' \
  "$ID" "$ID" "$COPY" "$LAB/projects/demo" "${MODE:-no-mistakes}" > "$LAB/state/$ID.meta"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
tasks-axi add "$ID" "lab rounds teardown" --kind ship --file "$LAB/data/backlog.md" >/dev/null && tasks-axi start "$ID" --file "$LAB/data/backlog.md" >/dev/null
echo "# before: meta=$(test -f "$LAB/state/$ID.meta" && echo present) branch=$(git -C "$LAB/projects/demo" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null && echo present) window=$(tmux list-windows -t firstmate -F '#W' | tr '\n' ' ')"
echo "\$ FM_HOME=<lab> bin/fm-teardown.sh $ID   (mode=${MODE:-no-mistakes})"
E "$WT/bin/fm-teardown.sh" "$ID" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed "s#$LAB#<lab>#g"; echo "[exit ${PIPESTATUS[0]}]"
echo "# after: meta=$(test -f "$LAB/state/$ID.meta" && echo present || echo removed) branch=$(git -C "$LAB/projects/demo" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null && echo present || echo deleted) copy=$(test -d "$COPY" && echo present || echo removed) windows=$(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')"
echo "# data/pipeline-rounds.jsonl:"
if [ -f "$LAB/data/pipeline-rounds.jsonl" ]; then sed "s#$LAB#<lab>#g" "$LAB/data/pipeline-rounds.jsonl" | jq .; else echo "(absent)"; fi
echo "# backlog:"; tasks-axi show "$ID" --file "$LAB/data/backlog.md" 2>&1 | head -4
