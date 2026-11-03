#!/usr/bin/env bash
# Live: the escalation line the real check prints (from a real task copy whose
# real run took a fix round, cap lowered to 1 so the real run is at the cap) is
# appended to a lab task's status log exactly as the brief says; firstmate's
# status fold and the bearings/fleet snapshots must show it as one open keyed
# needs-decision, and a resolved line for that key must close it.
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB/live-escalation
REP=/Users/hcho/.treehouse-fm-private/.treehouse/RepToday-ef4848/1/RepToday
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
mkdir -p "$LAB/gone"
ID=rt-cap
printf 'worktree=%s\nproject=RepToday\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-g1\n' "$LAB/gone" > "$LAB/state/$ID.meta"
echo "# 1. worker side: real check from the real RepToday task copy, cap 1"
out=$(cd "$REP" && "$WT/bin/fm-nm-rounds.sh" check --step test --cap 1 --out-dir "$EV"); rc=$?
printf '%s\n[exit %s]\n\n' "$out" "$rc"
esc=$(printf '%s\n' "$out" | sed -n 's/^escalation: //p')
printf 'working: validating\n' >> "$LAB/state/$ID.status"
printf '%s\n' "$esc" >> "$LAB/state/$ID.status"
echo "# 2. state/$ID.status after the worker appended the escalation verbatim"; cat "$LAB/state/$ID.status"; echo
echo "# 3. firstmate's status fold (fm-classify-lib.sh status_open_decisions)"
E bash -c ". '$WT/bin/fm-classify-lib.sh'; status_open_decisions '$LAB/state/$ID.status' ship" | tr '\t' '|'; echo; echo
echo "# 4. bearings snapshot decisions_open"
E "$WT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -c '.decisions_open'
echo
echo "# 5. a later unrelated event does not mask it"
printf 'note: waiting on firstmate\n' >> "$LAB/state/$ID.status"
E bash -c ". '$WT/bin/fm-classify-lib.sh'; status_open_decisions '$LAB/state/$ID.status' ship" | tr '\t' '|'; echo; echo
key=$(printf '%s\n' "$esc" | sed -n 's/.*\[key=\([^]]*\)\].*/\1/p')
echo "# 6. firstmate answers with --resolve-key $key (resolved line for that key)"
printf 'resolved [key=%s]: captain allowed one more round (--cap 2)\n' "$key" >> "$LAB/state/$ID.status"
open=$(E bash -c ". '$WT/bin/fm-classify-lib.sh'; status_open_decisions '$LAB/state/$ID.status' ship")
printf 'open decisions after resolve: [%s]\n' "$open"
echo
echo "# 7. worker relays with the captain's --cap 2: check is under the cap again"
(cd "$REP" && "$WT/bin/fm-nm-rounds.sh" check --step test --cap 2); echo "[exit $?]"
