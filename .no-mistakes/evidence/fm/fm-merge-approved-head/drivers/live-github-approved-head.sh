#!/usr/bin/env bash
# Live drive of bin/fm-approved-head.sh against a REAL GitHub pull request
# (hcho22/firstmate-private#24), read-only: gh pr view and git fetch only.
# The task lives in a marked lab home; its worktree is a fresh clone of the
# real GitHub origin, so verify fetches refs/pull/24/head and main from GitHub.
# Usage: live-github-approved-head.sh <repo-worktree> <lab-home>
set -u
REPO=$1 LAB=$2
URL=https://github.com/hcho22/firstmate-private/pull/24
OTHER=https://github.com/hcho22/firstmate-private/pull/23
lab() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" PATH="$LAB/pathfix:$PATH" "$@"; }
step() { printf '\n### %s\n' "$*"; }
show_meta() { printf -- '--- %s\n' "$LAB/state/$1.meta"; cat "$LAB/state/$1.meta"; }
run() { printf '$ %s\n' "${*#"$REPO/"}"; local rc=0; lab "$@" 2>&1 || rc=$?; printf '[exit %s]\n' "$rc"; }

T=appr-chat
printf 'window=fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$T" "$LAB/wt" "$LAB/wt" > "$LAB/state/$T.meta"
step "Register the real PR the way a worker's ready report does (fm-pr-check.sh, main home)"
run "$REPO/bin/fm-pr-check.sh" "$T" "$URL"
show_meta "$T"
LIVE=$(gh pr view "$URL" --json headRefOid -q .headRefOid)
printf 'GitHub reports the live head of %s as %s\n' "$URL" "$LIVE"

step "S1 chat ask: firstmate runs record before asking the captain for the merge word"
run "$REPO/bin/fm-approved-head.sh" record "$T" "$URL"
show_meta "$T"

step "S2 merge word at the head shown: verify with the live head GitHub reports now"
run "$REPO/bin/fm-approved-head.sh" verify "$T" "$URL" "$LIVE" main

step "S3 a commit pushed after approval: the captain was shown the PR one commit earlier"
EARLIER=$(git -C "$LAB/wt" fetch -q origin "+refs/pull/24/head:refs/lab/pr24" && git -C "$LAB/wt" rev-parse refs/lab/pr24~1)
git -C "$LAB/wt" update-ref -d refs/lab/pr24
git -C "$LAB/wt" log -2 --format='%H %s' "$LIVE" | sed 's/^/  real PR commit: /'
run "$REPO/bin/fm-approved-head.sh" record "$T" "$URL" "$EARLIER"
run "$REPO/bin/fm-approved-head.sh" verify "$T" "$URL" "$LIVE" main
printf 'private fetch refs left behind: [%s]\n' "$(git -C "$LAB/wt" for-each-ref refs/fm-approved-head)"

step "S4 guard: no head recorded and yolo=off refuses, and never offers to record the live head"
T2=appr-norec
printf 'window=fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\npr=%s\n' "$T2" "$LAB/wt" "$LAB/wt" "$URL" > "$LAB/state/$T2.meta"
run "$REPO/bin/fm-approved-head.sh" verify "$T2" "$URL" "$LIVE" main
step "S4b same task under yolo=on (an autonomous merge with no captain word) proceeds with a notice"
sed -i '' 's/^yolo=off$/yolo=on/' "$LAB/state/$T2.meta"
run "$REPO/bin/fm-approved-head.sh" verify "$T2" "$URL" "$LIVE" main

step "S5 guard: an approved head recorded for a DIFFERENT PR does not authorize this one"
T3=appr-foreign
OTHER_HEAD=$(gh pr view "$OTHER" --json headRefOid -q .headRefOid)
printf 'window=fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\napproved_head=%s %s\npr=%s\n' "$T3" "$LAB/wt" "$LAB/wt" "$LIVE" "$OTHER" "$URL" > "$LAB/state/$T3.meta"
show_meta "$T3"
run "$REPO/bin/fm-approved-head.sh" verify "$T3" "$URL" "$LIVE" main
step "S5b guard: record refuses a PR the task does not own"
run "$REPO/bin/fm-approved-head.sh" record "$T" "$OTHER" "$OTHER_HEAD"
show_meta "$T"
