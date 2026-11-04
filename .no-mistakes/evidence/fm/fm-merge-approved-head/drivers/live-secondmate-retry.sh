#!/bin/bash
# Live validation, against real GitHub (https://github.com/hcho22/nodebase/pull/2),
# that in a secondmate home an approved-head refusal that only asks for a
# retry publishes nothing on the parent channel, while one that needs the
# captain again publishes the child's PR-ready line at the live head.
# Three marked lab homes (bin/fm-lab-home.sh): a parent P and secondmate homes
# A (attended) and B (away) bound to P with route=local, so each child's
# channel is P/state/<mate-id>.status.
# Real bin/fm-pr-check.sh, fm-approved-head.sh, fm-afk-contract.sh and
# fm-pr-merge.sh run in the child home; gh is the write-guard beside this
# script (reads reach GitHub, writes are refused, nothing is merged).
# Usage: live-secondmate-retry.sh <firstmate-worktree> <transcript-dir>
set -u
W=$1
OUT=$2
DRIVERS=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/hcho22/nodebase/pull/2
REMOTE=https://github.com/hcho22/nodebase.git
SHOWN_EARLIER=4d2a6261574bed47c79c52547d29fcb48e449be0
mkdir -p "$OUT"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
P=$ROOT/parent A=$ROOT/mate-a B=$ROOT/mate-b
for h in "$P" "$A" "$B"; do "$W/bin/fm-lab-home.sh" create "$h" >/dev/null || exit 1; done
mkdir -p "$ROOT/guardbin"
ln -s "$DRIVERS/gh-write-guard.sh" "$ROOT/guardbin/gh"
ln -s "$DRIVERS/gh-axi-write-guard.sh" "$ROOT/guardbin/gh-axi"
ln -s /usr/bin/jq "$ROOT/guardbin/jq"
export FM_LIVE_GH_LOG="$ROOT/gh-calls.log"
: > "$FM_LIVE_GH_LOG"
git clone --quiet --no-checkout "$REMOTE" "$ROOT/wt" || exit 1

# A mate home whose PR is registered before it is bound to the parent, so its
# channel starts empty (as when no ready line at the current head was ever
# published) and any line that appears comes from the merge being driven.
setup_mate() {  # <home> <task-id>
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$1/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$1/data/backlog.md"
  printf 'window=fm-%s\nworktree=%s\nproject=%s/projects/nodebase\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$2" "$ROOT/wt" "$1" > "$1/state/$2.meta"
  chmod 600 "$1/state/$2.meta"
}
bind_parent() {  # <home> <mate-id>
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$1/.fm-secondmate-parent"
}

step() {  # <home> <mate-id> <label> <script> <args...>
  local home=$1 mate=$2 label=$3 rc=0 f before
  shift 3
  f="$OUT/$label.txt"
  before=$(cat "$P/state/$mate.status" 2>/dev/null | wc -l | tr -d ' ')
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" PATH="$ROOT/guardbin:$PATH" \
    "$W/bin/$@" > "$ROOT/o" 2> "$ROOT/e" || rc=$?
  {
    printf '# %s\n' "$label"
    printf 'task worktree origin: %s\n' "$(git -C "$ROOT/wt" remote get-url origin)"
    printf 'child away-posture record: %s\n' "$(env -u FM_STATE_OVERRIDE FM_HOME="$home" "$W/bin/fm-afk-contract.sh" mode 2>/dev/null || printf 'none (attended)')"
    printf '$ FM_HOME=%s bin/%s\n' "$home" "$*"
    printf '## exit status: %s\n' "$rc"
    printf '## stdout\n'; cat "$ROOT/o"
    printf '## stderr (watcher banners from the lab home omitted)\n'; grep -v -e '^●' -e '^WARNING: watcher' "$ROOT/e"
    printf '## merge writes refused by the test guard so far\n'
    grep '^BLOCKED-WRITE' "$FM_LIVE_GH_LOG" || printf '(none)\n'
    printf '## parent channel %s (P/state/%s.status): %s line(s) before, now:\n' "$mate" "$mate" "$before"
    cat "$P/state/$mate.status" 2>/dev/null || printf '(no channel file)\n'
    printf '(end)\n'
  } | sed -e "s#$ROOT#\$LAB#g" -e "s#$W#<worktree>#g" > "$f"
  printf '%-52s exit=%s channel lines %s -> %s\n' "$label" "$rc" "$before" "$(cat "$P/state/$mate.status" 2>/dev/null | wc -l | tr -d ' ')"
}
offline() { git -C "$ROOT/wt" remote set-url origin https://github.invalid/hcho22/nodebase.git; }
online() { git -C "$ROOT/wt" remote set-url origin "$REMOTE"; }

# Attended child A.
setup_mate "$A" sm-a
step "$A" mate-a s01-register-before-binding fm-pr-check.sh sm-a "$URL"
bind_parent "$A" mate-a
step "$A" mate-a s02-mate-records-older-relayed-head fm-approved-head.sh record sm-a "$URL" "$SHOWN_EARLIER"
offline
step "$A" mate-a s03-merge-when-verify-fetch-fails fm-pr-merge.sh sm-a "$URL"
online
step "$A" mate-a s04-merge-refuses-and-republishes fm-pr-merge.sh sm-a "$URL"

# Away child B.
setup_mate "$B" sm-b
step "$B" mate-b s05-register-before-binding fm-pr-check.sh sm-b "$URL"
bind_parent "$B" mate-b
step "$B" mate-b s06-mate-records-older-relayed-head fm-approved-head.sh record sm-b "$URL" "$SHOWN_EARLIER"
step "$B" mate-b s07-child-goes-away fm-afk-contract.sh enter --words "merge nodebase PR 2 when green"
offline
step "$B" mate-b s08-away-merge-when-verify-fetch-fails fm-pr-merge.sh sm-b "$URL"
online
step "$B" mate-b s09-away-merge-refuses-and-republishes fm-pr-merge.sh sm-b "$URL"
