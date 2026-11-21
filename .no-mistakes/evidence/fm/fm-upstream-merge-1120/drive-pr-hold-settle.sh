#!/usr/bin/env bash
# Drives opt-in PR hold settlement live in a marked lab home against a real merged GitHub PR (read-only gh calls).
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M7YT4J4C4G24DNJ60RG4KYT1
LAB=$1; ID=pr-question; URL=https://github.com/hcho22/firstmate-private/pull/28
cd "$WT" || exit 1
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
step() { printf '\n===== %s\n' "$*"; }
step "0. opt in: config/hold-pr-settle"; touch "$LAB/config/hold-pr-settle"
step "1. backlog task for project demo linked to a real merged PR"
bin/fm-tasks-axi.sh add "$ID" 'Decide whether PR 28 should land' --repo demo --pr "$URL"; echo "exit=$?"
step "2. hold it for the captain"
bin/fm-captain-hold.sh hold "$ID" --reason 'Decide whether PR 28 should land'; echo "exit=$?"
bin/fm-captain-hold.sh open "$ID"; echo "open exit=$? (0 = open captain hold)"
step "3. declare the PR policy: merged -> close"
bin/fm-captain-hold.sh pr-policy "$ID" "$URL" merged close; echo "exit=$?"
step "3b. where the policy landed"
find "$LAB/data" -name hold-pr-policy.json; ls -d "$LAB/data/$ID" 2>&1
cat "$LAB/data/demo/$ID/hold-pr-policy.json" 2>&1; echo
step "4. contribution poll observes the real PR (gh) and settles"
bin/fm-contributions.sh poll; echo "poll exit=$?"
step "4b. records after poll"
ls -la "$LAB/data/demo/$ID/" 2>&1; ls -d "$LAB/data/$ID" 2>&1
jq '.records[] | {url,kind,state:.observation.state}' "$LAB/data/demo/$ID/contributions.json" 2>&1
step "5. hold state after settlement"
bin/fm-captain-hold.sh open "$ID"; echo "open exit=$? (non-zero = no longer an open captain hold)"
bin/fm-tasks-axi.sh show "$ID" --full
echo DRIVER-DONE
