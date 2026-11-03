#!/usr/bin/env bash
# Adversarial follow-up to live-secondmate-ready-line.sh: with the parent channel
# emptied (so no dedup can hide a line), the merge-time registration must publish
# nothing, while an ordinary registration (control) publishes the ready line.
# Usage: live-secondmate-merge-time-quiet.sh <repo-worktree> <main-lab-home>
set -u
REPO=$1 MAIN=$2 MATE=$2/mate
URL=https://github.com/hcho22/firstmate-private/pull/24
CHANNEL=$MAIN/state/mate-lab.status
labm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MATE" PATH="$MAIN/pathfix:$PATH" "$@"; }
run() { printf '$ %s\n' "$(printf '%s ' "$@" | sed "s#$REPO/##g")"; labm "$@" 2>&1 | grep -v -e '^●' -e '^WARNING: watcher' || true; }
channel() { printf -- '--- parent channel: %s line(s)\n' "$( [ -f "$CHANNEL" ] && wc -l < "$CHANNEL" | tr -d ' ' || echo 0)"; [ -f "$CHANNEL" ] && cat "$CHANNEL"; }
mv "$CHANNEL" "$CHANNEL.earlier"
printf '### parent channel cleared (earlier line kept aside)\n'; channel
printf '\n### merge-time registration (FM_PR_CHECK_MERGE=1)\n'
run env FM_PR_CHECK_MERGE=1 "$REPO/bin/fm-pr-check.sh" child-24 "$URL"; channel
printf '\n### control: an ordinary registration publishes the ready line\n'
run "$REPO/bin/fm-pr-check.sh" child-24 "$URL"; channel
