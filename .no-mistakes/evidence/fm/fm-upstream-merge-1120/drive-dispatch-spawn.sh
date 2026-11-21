#!/usr/bin/env bash
# Drives the per-project dispatch record path live in a marked lab home.
# Run inside a window of the lab's private tmux server (so $TMUX names the lab socket).
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M7YT4J4C4G24DNJ60RG4KYT1
LAB=$1; ID=dispatch-scout
cd "$WT" || exit 1
export FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/treehouse"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
unset FM_DISPATCH_PROVIDER FM_DISPATCH_MODEL TYPESAFE_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY
step() { printf '\n===== %s\n' "$*"; }
step "TMUX=$TMUX"
step "1. scaffold a scout brief with bin/fm-brief.sh"
bin/fm-brief.sh "$ID" demo --scout; echo "exit=$?"
B="$LAB/data/demo/$ID/brief.md"
python3 - "$B" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('{TASK}','Read calc.py in the demo project and say in two sentences what it does.',1)
s=s.replace('{FIRSTMATE_SPEC}','Open calc.py, describe its single function, and write the two-sentence report. No code changes.',1)
open(p,'w').write(s)
PY
grep -c '{TASK}\|{FIRSTMATE_SPEC}' "$B"
step "2. activate config/crew-dispatch.json"
printf '%s\n' '{"rules":[{"when":"reading and summarizing small code files","use":{"harness":"claude","model":"sonnet","effort":"low"}}],"default":{"harness":"claude"}}' > "$LAB/config/crew-dispatch.json"
cat "$LAB/config/crew-dispatch.json"
step "3. spawn BEFORE any resolution is recorded (must refuse, naming the per-project brief path)"
bin/fm-spawn.sh "$ID" "$LAB/projects/demo" --scout --harness claude; echo "exit=$?"
step "4. bin/fm-dispatch-resolve.sh on the per-project brief (no provider configured -> off)"
bin/fm-dispatch-resolve.sh "$B" --project demo; echo "exit=$?"
step "4b. task record location"
ls -la "$LAB/data/demo/$ID/"; cat "$LAB/data/demo/$ID/dispatch-resolution.json"; echo
ls -d "$LAB/data/$ID" 2>&1
step "5. adversarial: a clear record selecting codex must make a claude spawn refuse (spawn reads the per-project record)"
cp "$LAB/data/demo/$ID/dispatch-resolution.json" /tmp/fm-lab-dispatch-off.json
jq -cn --arg id "$ID" '{task:$id,status:"clear",profile:{harness:"codex",model:"gpt-5",effort:"medium"}}' > "$LAB/data/demo/$ID/dispatch-resolution.json"
bin/fm-spawn.sh "$ID" "$LAB/projects/demo" --scout --harness claude; echo "exit=$?"
ls -d "$LAB/data/$ID" 2>&1
step "6. restore the resolver's own record and spawn a real claude scout"
bin/fm-dispatch-resolve.sh "$B" --project demo >/dev/null; echo "resolve exit=$?"; cat "$LAB/data/demo/$ID/dispatch-resolution.json"; echo
bin/fm-spawn.sh "$ID" "$LAB/projects/demo" --scout --harness claude; echo "exit=$?"
step "7. state after spawn"
cat "$LAB/state/$ID.meta" 2>&1
ls -d "$LAB/data/$ID" 2>&1
echo DRIVER-DONE
