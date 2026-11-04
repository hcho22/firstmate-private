#!/bin/bash
# Live validation of captain-approved-head merges against real GitHub.
# Usage: live-github.sh <firstmate-worktree> <transcript-dir>
# Drives the real bin/fm-pr-check.sh, bin/fm-approved-head.sh and
# bin/fm-pr-merge.sh from <firstmate-worktree> in a disposable marked lab home
# (bin/fm-lab-home.sh) against https://github.com/hcho22/firstmate-private/pull/24.
# The task worktree is a real clone of that repository, so the verify fetches
# refs/pull/24/head and main from GitHub. gh is the write-guard beside this
# script: every read reaches real GitHub, every write is refused, so the PR is
# never merged or changed. The lab is removed on exit.
set -u
W=$1
OUT=$2
DRIVERS=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/hcho22/firstmate-private/pull/24
URL23=https://github.com/hcho22/firstmate-private/pull/23
SHOWN_EARLIER=617baf6f48c00da30eb9964a6f8a68e9d959c9c7
UNRELATED=e8f155c91e6d93d8c1b6a2a6396edd56e90b0895
ID=lab-ah1
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/guardbin" "$LAB/projects/firstmate-private"
ln -s "$DRIVERS/gh-write-guard.sh" "$LAB/guardbin/gh"
ln -s "$DRIVERS/gh-axi-write-guard.sh" "$LAB/guardbin/gh-axi"
export FM_LIVE_GH_LOG="$LAB/gh-calls.log"
: > "$FM_LIVE_GH_LOG"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
git clone --quiet --no-checkout https://github.com/hcho22/firstmate-private.git "$LAB/wt" || exit 1

write_meta() {  # <yolo> [extra meta line]
  {
    printf 'window=fm-%s\n' "$ID"
    printf 'worktree=%s\n' "$LAB/wt"
    printf 'project=%s\n' "$LAB/projects/firstmate-private"
    printf 'kind=ship\nmode=no-mistakes\nyolo=%s\n' "$1"
    [ -z "${2-}" ] || printf '%s\n' "$2"
  } > "$LAB/state/$ID.meta"
  chmod 600 "$LAB/state/$ID.meta"
}

fm() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" PATH="$LAB/guardbin:$PATH" "$W/bin/$@"
}

scenario() {  # <label> <script> <args...>
  local label=$1 f n rc=0
  shift
  f="$OUT/$label.txt"
  n=$(wc -l < "$FM_LIVE_GH_LOG")
  fm "$@" > "$LAB/o" 2> "$LAB/e" || rc=$?
  {
    printf '# %s\n' "$label"
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
  printf '%-44s exit=%s\n' "$label" "$rc"
}

write_meta off
scenario g01-register-pr fm-pr-check.sh "$ID" "$URL"
scenario g02-present-records-live-head fm-approved-head.sh record "$ID" "$URL"
scenario g03-merge-at-approved-head fm-pr-merge.sh "$ID" "$URL"
scenario g04-bound-merge-refuses-auto fm-pr-merge.sh "$ID" "$URL" --attended-override -- --auto --squash
scenario g05-record-head-shown-earlier fm-approved-head.sh record "$ID" "$URL" "$SHOWN_EARLIER"
scenario g05-merge-after-ci-fix-pushes fm-pr-merge.sh "$ID" "$URL"
live=$(sed -n 's/^error: present the pull request to the captain again at head \([0-9a-f]*\),.*/\1/p' "$OUT/g05-merge-after-ci-fix-pushes.txt")
scenario g06-represent-record-refused-head fm-approved-head.sh record "$ID" "$URL" "${live:-missing}"
scenario g06-merge-after-represent fm-pr-merge.sh "$ID" "$URL"
scenario g07-record-rewritten-history-head fm-approved-head.sh record "$ID" "$URL" "$UNRELATED"
scenario g07-merge-after-history-rewrite fm-pr-merge.sh "$ID" "$URL"
write_meta off
scenario g08-merge-with-no-recorded-head fm-pr-merge.sh "$ID" "$URL"
write_meta off "approved_head=91822114c812bdadc0c06bc7b34e6ff30893cea3 $URL23"
scenario g09-merge-with-head-recorded-for-other-pr fm-pr-merge.sh "$ID" "$URL"
write_meta on
scenario g10-yolo-merge-with-no-recorded-head fm-pr-merge.sh "$ID" "$URL"
printf 'merge writes the guard refused across the whole run:\n'
grep '^BLOCKED-WRITE' "$FM_LIVE_GH_LOG" || printf '(none)\n'
