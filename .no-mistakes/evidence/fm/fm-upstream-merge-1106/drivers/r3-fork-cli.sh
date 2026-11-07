#!/usr/bin/env bash
# Re-drive the fork's merge-authority CLIs (#22-#25) at the gate HEAD in a disposable lab home.
# Usage: r3-fork-cli.sh <worktree>
set -u
W=$1; cd "$W" || exit 1
LAB=$(cd "$(mktemp -d /tmp/fm-lab.XXXXXX)" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
echo "HEAD=$(git rev-parse HEAD) lab=$LAB"
run() { echo "\$ $*"; "$@"; echo "rc=$?"; }
PR=https://github.com/hcho22/firstmate-private/pull/25
LIVE=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
printf 'pr=%s\n' "$PR" > "$LAB/state/ah-lab.meta"

echo "=== #25 approved head: captain-approved merge covers only the commit he was shown"
run bin/fm-approved-head.sh live ah-lab "$PR"
echo "--- no head recorded, captain present: refuse"
run bin/fm-approved-head.sh verify ah-lab "$PR" "$LIVE" main
echo "--- no head recorded, --away: proceed bound to no head (rc=3)"
run bin/fm-approved-head.sh verify ah-lab "$PR" "$LIVE" main --away
OLD=$(gh pr view "$PR" --json commits -q '.commits[-2].oid')
echo "--- adversarial: captain shown an earlier head $OLD, live head moved"
run bin/fm-approved-head.sh record ah-lab "$PR" "$OLD"
run bin/fm-approved-head.sh verify ah-lab "$PR" "$LIVE" main
run bin/fm-approved-head.sh verify ah-lab "$PR" "$LIVE" main --away
echo "--- captain shown the live head"
run bin/fm-approved-head.sh record ah-lab "$PR"
run bin/fm-approved-head.sh verify ah-lab "$PR" "$LIVE" main
echo "--- adversarial: head bound to another PR URL does not count"
run bin/fm-approved-head.sh verify ah-lab https://github.com/hcho22/firstmate-private/pull/24 "$LIVE" main

echo
echo "=== #24 low-risk merge tier, judged from live changed files"
source bin/fm-merge-tier-lib.sh
printf 'fmp low-risk docs/**\nfmp low-risk tests/**\nfmp always-ask tests/lib.sh\n' > "$LAB/config/merge-tiers"
cat "$LAB/config/merge-tiers"
judge() { fm_merge_tier_load "$LAB/config" fmp; echo "load rc=$? ${FM_MERGE_TIER_ERROR:-}"; if fm_merge_tier_judge; then echo "verdict: LOW-RISK ($FM_MERGE_TIER_JUDGED_COUNT files)"; else echo "verdict: WAITS FOR CAPTAIN ($FM_MERGE_TIER_BLOCKED_COUNT of $FM_MERGE_TIER_JUDGED_COUNT refused)"; printf '%s' "$FM_MERGE_TIER_BLOCKERS"; fi; }
for n in 27 23; do echo "--- PR #$n changed files read live from GitHub"; gh pr view $n -R hcho22/firstmate-private --json files -q '.files[].path' | judge; done
echo "--- docs/tests only"; printf 'docs/a.md\ntests/fm-x.test.sh\n' | judge
echo "--- adversarial: built-in always-ask paths under a low-risk pattern"; printf 'docs/.github/workflows/x.yml\ntests/AGENTS.md\ndocs/.CLAUDE/settings.json\ntests/lib.sh\n' | judge
echo "--- adversarial: malformed rule refuses every low-risk merge"; printf 'fmp low-risk docs/[a-z]*\n' > "$LAB/config/merge-tiers"; printf 'docs/a.md\n' | judge
echo "--- adversarial: no declaration"; rm -f "$LAB/config/merge-tiers"; printf 'docs/a.md\n' | judge

echo
echo "=== #23 captain scorebook"
run bin/fm-scorebook.sh grant merge
run bin/fm-scorebook.sh granted merge
for i in 1 2 3 4 5 6 7 8 9 10; do
  id=$(bin/fm-scorebook.sh ask --kind finding-scope --recommend "decline it" --question "q$i" 2>&1 | tail -1); echo "ask -> $id"
  bin/fm-scorebook.sh answer "$id" --matched yes --answer "decline it" >/dev/null 2>&1 || echo "answer $id failed rc=$?"
done
run bin/fm-scorebook.sh report
run bin/fm-scorebook.sh granted finding-scope
run bin/fm-scorebook.sh grant finding-scope
run bin/fm-scorebook.sh granted finding-scope
run bin/fm-scorebook.sh revoke finding-scope
run bin/fm-scorebook.sh granted finding-scope

echo
echo "=== #22 review fix-round cap"
run bin/fm-nm-rounds.sh report
