#!/bin/bash
# Live validation, against real GitHub, of a captain-approved head binding a
# merge under the away posture, the hold-for-return remedy, the retry remedy
# for a failed read, and the attended and quiet-mode contrasts.
# Usage: live-away-github.sh <firstmate-worktree> <transcript-dir>
# Drives the real bin/fm-pr-check.sh, bin/fm-afk-contract.sh,
# bin/fm-approved-head.sh and bin/fm-pr-merge.sh from <firstmate-worktree> in a
# disposable marked lab home (bin/fm-lab-home.sh) against
# https://github.com/hcho22/nodebase/pull/2 (open, CLEAN, MERGEABLE).
# The task worktree is a real clone, so verify fetches refs/pull/2/head and
# main from GitHub. gh is the write-guard beside this script: every read
# reaches real GitHub and every write is refused, so the PR is never merged or
# changed. The lab is removed on exit.
set -u
W=$1
OUT=$2
DRIVERS=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/hcho22/nodebase/pull/2
URL_OTHER=https://github.com/hcho22/nodebase/pull/1
REMOTE=https://github.com/hcho22/nodebase.git
LIVE=fcabedcbb6dbc0b21fdebc74345c89bfb65c17c7
SHOWN_EARLIER=4d2a6261574bed47c79c52547d29fcb48e449be0
ID=lab-aw1
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/guardbin" "$LAB/projects/nodebase"
ln -s "$DRIVERS/gh-write-guard.sh" "$LAB/guardbin/gh"
ln -s "$DRIVERS/gh-axi-write-guard.sh" "$LAB/guardbin/gh-axi"
ln -s /usr/bin/jq "$LAB/guardbin/jq"
export FM_LIVE_GH_LOG="$LAB/gh-calls.log"
: > "$FM_LIVE_GH_LOG"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
git clone --quiet --no-checkout "$REMOTE" "$LAB/wt" || exit 1

write_meta() {  # [extra meta line]
  {
    printf 'window=fm-%s\n' "$ID"
    printf 'worktree=%s\n' "$LAB/wt"
    printf 'project=%s\n' "$LAB/projects/nodebase"
    printf 'kind=ship\nmode=no-mistakes\nyolo=off\n'
    [ -z "${1-}" ] || printf '%s\n' "$1"
  } > "$LAB/state/$ID.meta"
  chmod 600 "$LAB/state/$ID.meta"
}

fm() {
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" PATH="$LAB/guardbin:$PATH" "$W/bin/$@"
}

posture() {
  if fm fm-afk-contract.sh mode >/dev/null 2>&1; then
    printf 'away-posture record: present, mode=%s\n' "$(fm fm-afk-contract.sh mode 2>/dev/null)"
  else
    printf 'away-posture record: none (attended)\n'
  fi
}

scenario() {  # <label> <script> <args...>
  local label=$1 f n rc=0
  shift
  f="$OUT/$label.txt"
  n=$(wc -l < "$FM_LIVE_GH_LOG")
  fm "$@" > "$LAB/o" 2> "$LAB/e" || rc=$?
  {
    printf '# %s\n' "$label"
    posture
    printf 'task worktree origin: %s\n' "$(git -C "$LAB/wt" remote get-url origin)"
    printf '$ FM_HOME=$LAB bin/%s\n' "$*"
    printf '## exit status: %s\n' "$rc"
    printf '## stdout\n'; cat "$LAB/o"
    printf '## stderr\n'; cat "$LAB/e"
    printf '## gh calls during this run (reads reach real GitHub; the test guard refuses writes)\n'
    tail -n +$((n + 1)) "$FM_LIVE_GH_LOG"
    printf '## task meta after\n'; cat "$LAB/state/$ID.meta"
    printf '## private verify refs left in the task worktree\n'
    git -C "$LAB/wt" for-each-ref refs/fm-approved-head
    printf '(end)\n'
  } | sed -e "s#$LAB#\$LAB#g" -e "s#$W#<worktree>#g" > "$f"
  printf '%-58s exit=%s forge-merge-writes=%s\n' "$label" "$rc" \
    "$(tail -n +$((n + 1)) "$FM_LIVE_GH_LOG" | grep -c '^BLOCKED-WRITE gh pr merge')"
}

write_meta
scenario a00-register-pr fm-pr-check.sh "$ID" "$URL"
scenario a00-captain-goes-away fm-afk-contract.sh enter --words "merge nodebase PR 2 when it is green"

# Away, nothing recorded for this PR: away authority, bound to no head.
scenario a01-away-merge-with-no-recorded-head fm-pr-merge.sh "$ID" "$URL"

# Away, a head recorded for another PR only: counts as none.
write_meta "approved_head=$LIVE $URL_OTHER"
fm fm-pr-check.sh "$ID" "$URL" >/dev/null 2>&1
scenario a02-away-merge-with-head-recorded-for-other-pr fm-pr-merge.sh "$ID" "$URL"

# Away, the captain approved the head shown before the worker's last push.
scenario a03-record-head-shown-before-away fm-approved-head.sh record "$ID" "$URL" "$SHOWN_EARLIER"
scenario a03-away-merge-after-worker-push fm-pr-merge.sh "$ID" "$URL"

# Away, a transient read failure: origin unreachable for the verify fetch.
git -C "$LAB/wt" remote set-url origin https://github.invalid/hcho22/nodebase.git
scenario a04-away-merge-when-verify-fetch-fails fm-pr-merge.sh "$ID" "$URL"
git -C "$LAB/wt" remote set-url origin "$REMOTE"

# Away, the captain's own away words explicitly cover the later head: the away
# session records the live head the refusal named, then merges.
scenario a05-captain-words-cover-later-head fm-afk-contract.sh enter --words "merge nodebase PR 2 once the worker's fix lands, at whatever head it is then"
live=$(sed -n 's/.*present the pull request again at head \([0-9a-f]*\) then.*/\1/p' "$OUT/a03-away-merge-after-worker-push.txt")
scenario a05-away-session-records-named-head fm-approved-head.sh record "$ID" "$URL" "${live:-missing}"
scenario a05-away-merge-at-recorded-later-head fm-pr-merge.sh "$ID" "$URL"

# Back to attended: the same older head refuses with the attended remedy.
scenario q00-captain-returns fm-afk-contract.sh archive
scenario q01-record-head-shown-earlier fm-approved-head.sh record "$ID" "$URL" "$SHOWN_EARLIER"
scenario q01-attended-merge-after-worker-push fm-pr-merge.sh "$ID" "$URL"
git -C "$LAB/wt" remote set-url origin https://github.invalid/hcho22/nodebase.git
scenario q02-attended-merge-when-verify-fetch-fails fm-pr-merge.sh "$ID" "$URL"
git -C "$LAB/wt" remote set-url origin "$REMOTE"

# Quiet mode is a present captain: no away allowance for an unrecorded head.
write_meta
fm fm-pr-check.sh "$ID" "$URL" >/dev/null 2>&1
FM_AFK_MODE=quiet scenario q03-captain-enters-quiet-mode fm-afk-contract.sh enter
scenario q03-quiet-merge-with-no-recorded-head fm-pr-merge.sh "$ID" "$URL"
scenario q04-record-head-shown-earlier fm-approved-head.sh record "$ID" "$URL" "$SHOWN_EARLIER"
scenario q04-quiet-merge-after-worker-push fm-pr-merge.sh "$ID" "$URL"
printf 'merge writes the guard refused across the whole run:\n'
grep '^BLOCKED-WRITE' "$FM_LIVE_GH_LOG" || printf '(none)\n'
