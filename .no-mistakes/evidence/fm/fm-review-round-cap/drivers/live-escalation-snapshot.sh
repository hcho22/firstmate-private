#!/usr/bin/env bash
# Live: the real check's escalation line in a lab task's status log surfaces in
# firstmate's fleet snapshot (hints.open_decisions) and bearings decisions_open
# exactly like an ask-user decision does (control task), and closes on resolve.
set -u
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB; WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
git init -q "$LAB/projects/demo" && git -C "$LAB/projects/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git -C "$LAB/projects/demo" worktree add -q -b fm/rt-cap "$LAB/copy"
printf 'worktree=%s\nproject=demo\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\n' "$LAB/copy" > "$LAB/state/rt-cap.meta"
grep '^escalation' -h "$EV/live-escalation/transcript.txt" | sed 's/^escalation: //' > "$LAB/state/rt-cap.status"
printf 'worktree=%s\nproject=demo\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\n' "$LAB/copy" > "$LAB/state/ctl.meta"
printf 'needs-decision [key=nm-01ABC-review]: ask-user findings=f1 file=/tmp/x\n' > "$LAB/state/ctl.status"
echo "# rt-cap.status (cap escalation printed by the live check):"; cat "$LAB/state/rt-cap.status"
echo "# ctl.status (control: rule 6 ask-user escalation):"; cat "$LAB/state/ctl.status"; echo
echo "# fleet snapshot hints.open_decisions"
E "$WT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null | jq -c '.tasks[] | {id, current_state: .current_state.state, open_decisions: .hints.open_decisions}'
echo "# bearings decisions_open"
E "$WT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -c '.decisions_open'
key=$(sed -n 's/.*\[key=\([^]]*\)\].*/\1/p' "$LAB/state/rt-cap.status")
printf 'resolved [key=%s]: captain: approve as is\n' "$key" >> "$LAB/state/rt-cap.status"
echo; echo "# after resolved [key=$key]"
E "$WT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null | jq -c '.tasks[] | {id, open_decisions: .hints.open_decisions}'
