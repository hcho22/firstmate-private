#!/bin/bash
# Live validation that an away merge whose pre-lock approved-head verify ran
# under the away posture is verified again under the lock when the captain
# returns (the away record is archived) in between, so an unrecorded head that
# away authority let through refuses once the merge is attended.
# Real GitHub (https://github.com/hcho22/nodebase/pull/2) through the
# write-guard, a disposable marked lab home, and the real fm-pr-check.sh,
# fm-afk-contract.sh and fm-pr-merge.sh; gh-return-mid-merge.sh archives the
# away record with the real archive command at the merge's base-branch read.
# Usage: live-return-mid-merge.sh <firstmate-worktree> <transcript-dir>
set -u
W=$1
OUT=$2
DRIVERS=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/hcho22/nodebase/pull/2
ID=lab-rt1
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/guardbin" "$LAB/projects/nodebase"
ln -s "$DRIVERS/gh-return-mid-merge.sh" "$LAB/guardbin/gh"
ln -s "$DRIVERS/gh-axi-write-guard.sh" "$LAB/guardbin/gh-axi"
ln -s /usr/bin/jq "$LAB/guardbin/jq"
export FM_LIVE_GH_LOG="$LAB/gh-calls.log" FM_LIVE_RETURN_TRIGGER="$LAB/return-trigger" FM_LIVE_FM_BIN="$W/bin"
: > "$FM_LIVE_GH_LOG"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
git clone --quiet --no-checkout https://github.com/hcho22/nodebase.git "$LAB/wt" || exit 1
printf 'window=fm-%s\nworktree=%s\nproject=%s/projects/nodebase\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$ID" "$LAB/wt" "$LAB" > "$LAB/state/$ID.meta"
chmod 600 "$LAB/state/$ID.meta"
fm() {
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" PATH="$LAB/guardbin:$PATH" "$W/bin/$@"
}
scenario() {  # <label> <script> <args...>
  local label=$1 n rc=0
  shift
  n=$(wc -l < "$FM_LIVE_GH_LOG")
  fm "$@" > "$LAB/o" 2> "$LAB/e" || rc=$?
  {
    printf '# %s\n' "$label"
    printf 'away-posture record before: %s\n' "$PRE"
    printf '$ FM_HOME=$LAB bin/%s\n' "$*"
    printf '## exit status: %s\n' "$rc"
    printf '## stdout\n'; cat "$LAB/o"
    printf '## stderr (watcher banners from the lab home omitted)\n'; grep -v -e '^●' -e '^WARNING: watcher' "$LAB/e"
    printf '## gh calls and the return hook, in order (reads reach real GitHub; writes are refused)\n'
    tail -n +$((n + 1)) "$FM_LIVE_GH_LOG" | cut -c1-240
    printf '## away-posture record after: %s\n' "$(fm fm-afk-contract.sh mode 2>/dev/null || printf 'none (archived)')"
    printf '## archived records\n'; ls "$LAB/state/afk-contracts" 2>/dev/null || true
    printf '(end)\n'
  } | sed -e "s#$LAB#\$LAB#g" -e "s#$W#<worktree>#g" > "$OUT/$label.txt"
  printf '%-52s exit=%s forge-merge-writes=%s\n' "$label" "$rc" \
    "$(tail -n +$((n + 1)) "$FM_LIVE_GH_LOG" | grep -c '^BLOCKED-WRITE gh pr merge')"
}
PRE='none'
scenario r00-register-pr fm-pr-check.sh "$ID" "$URL"
scenario r00-captain-goes-away fm-afk-contract.sh enter --words "merge nodebase PR 2 when it is green"
PRE=$(fm fm-afk-contract.sh mode 2>/dev/null || printf none)
: > "$FM_LIVE_RETURN_TRIGGER"
scenario r01-captain-returns-mid-away-merge fm-pr-merge.sh "$ID" "$URL"
