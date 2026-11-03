#!/usr/bin/env bash
# Live drive of bin/fm-pr-check.sh in a lab SECONDMATE home whose parent channel
# is the main lab home's state/<mate>.status, against the real GitHub PR #24
# (read-only gh pr view). Shows: registration publishes the child's PR-ready line
# with head=<live head>; a re-registration at the same head is not re-published;
# the merge-time registration (FM_PR_CHECK_MERGE=1, what fm-pr-merge.sh runs)
# publishes nothing.
# Usage: live-secondmate-ready-line.sh <repo-worktree> <main-lab-home>
set -u
REPO=$1 MAIN=$2 MATE=$2/mate
URL=https://github.com/hcho22/firstmate-private/pull/24
CHANNEL=$MAIN/state/mate-lab.status
labm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MATE" FM_PROCEVENT_CLAIM_ROOT="$MAIN/procevent-claims" PATH="$MAIN/pathfix:$PATH" "$@"; }
run() { printf '$ %s\n' "$(printf '%s ' "$@" | sed "s#$REPO/##g")"; local rc=0; labm "$@" 2>&1 | grep -v '^●' || true; }
channel() { printf -- '--- parent channel %s (%s lines)\n' "${CHANNEL#"$MAIN/"}" "$( [ -f "$CHANNEL" ] && wc -l < "$CHANNEL" | tr -d ' ' || echo 0)"; [ -f "$CHANNEL" ] && cat "$CHANNEL"; }

[ -d "$MATE" ] || "$REPO/bin/fm-lab-home.sh" create "$MATE" >/dev/null
printf 'mate-lab\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
T=child-24
printf 'window=fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$T" "$MAIN/wt" "$MAIN/wt" > "$MATE/state/$T.meta"
printf 'live head GitHub reports for %s: %s\n' "$URL" "$(gh pr view "$URL" --json headRefOid -q .headRefOid)"

printf '\n### the mate registers its child PR (worker reported ready)\n'
run "$REPO/bin/fm-pr-check.sh" "$T" "$URL"
channel
printf '\n### the same registration again at the same head (a replayed report)\n'
run "$REPO/bin/fm-pr-check.sh" "$T" "$URL"
channel
printf '\n### the merge-time registration fm-pr-merge.sh performs (FM_PR_CHECK_MERGE=1)\n'
run env FM_PR_CHECK_MERGE=1 "$REPO/bin/fm-pr-check.sh" "$T" "$URL"
channel
