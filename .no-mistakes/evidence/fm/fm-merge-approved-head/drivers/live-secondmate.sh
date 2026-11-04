#!/bin/bash
# Live validation of the secondmate parent channel for approved-head merges,
# against real GitHub (https://github.com/hcho22/firstmate-private/pull/24).
# Three marked lab homes (bin/fm-lab-home.sh): a parent P, and secondmate homes
# A and B bound to P with route=local, so each child's channel is
# P/state/<mate-id>.status. Real bin/fm-pr-check.sh, fm-approved-head.sh and
# fm-pr-merge.sh run in the child homes; gh is the write-guard beside this
# script (reads reach GitHub, writes are refused, nothing is merged).
#  A: registration publishes a ready line carrying head=; a relayed merge word
#     at that head proceeds to the forge and publishes no further ready line.
#  B: registered before it was bound to a parent, so its channel starts empty
#     (as when a line at the current head was never published); a relayed word
#     at an older head refuses, and only that refusal publishes a ready line,
#     at the live head, for the parent to present again.
# Usage: live-secondmate.sh <firstmate-worktree> <transcript-dir>
set -u
W=$1
OUT=$2
DRIVERS=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/hcho22/firstmate-private/pull/24
LIVE=91822114c812bdadc0c06bc7b34e6ff30893cea3
SHOWN_EARLIER=617baf6f48c00da30eb9964a6f8a68e9d959c9c7
mkdir -p "$OUT"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
P=$ROOT/parent A=$ROOT/mate-a B=$ROOT/mate-b
for h in "$P" "$A" "$B"; do "$W/bin/fm-lab-home.sh" create "$h" >/dev/null || exit 1; done
mkdir -p "$ROOT/guardbin"
ln -s "$DRIVERS/gh-write-guard.sh" "$ROOT/guardbin/gh"
ln -s "$DRIVERS/gh-axi-write-guard.sh" "$ROOT/guardbin/gh-axi"
export FM_LIVE_GH_LOG="$ROOT/gh-calls.log"
: > "$FM_LIVE_GH_LOG"
git clone --quiet --no-checkout https://github.com/hcho22/firstmate-private.git "$ROOT/wt" || exit 1

bind_parent() {  # <home> <mate-id>
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$1/.fm-secondmate-parent"
}
setup_home() {  # <home> <task-id>
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$1/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$1/data/backlog.md"
  printf 'window=fm-%s\nworktree=%s\nproject=%s/projects/p\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$2" "$ROOT/wt" "$1" > "$1/state/$2.meta"
  chmod 600 "$1/state/$2.meta"
}
step() {  # <home> <mate-id> <label> <script> <args...>
  local home=$1 mate=$2 label=$3 rc=0 f before
  shift 3
  f="$OUT/$label.txt"
  before=$(cat "$P/state/$mate.status" 2>/dev/null | wc -l | tr -d ' ')
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" PATH="$ROOT/guardbin:$PATH" \
    "$W/bin/$@" > "$ROOT/o" 2> "$ROOT/e" || rc=$?
  {
    printf '# %s\n' "$label"
    printf '$ FM_HOME=%s bin/%s\n' "$home" "$*"
    printf '## exit status: %s\n' "$rc"
    printf '## stdout\n'; cat "$ROOT/o"
    printf '## stderr (watcher banners from the lab home omitted)\n'; grep -v -e '^●' -e '^WARNING: watcher' "$ROOT/e"
    printf '## merge writes refused by the test guard in this step\n'
    grep -c '^BLOCKED-WRITE' "$FM_LIVE_GH_LOG" | sed 's/^/total so far: /'
    printf '## parent channel %s (P/state/%s.status): %s line(s) before, now:\n' "$mate" "$mate" "$before"
    cat "$P/state/$mate.status" 2>/dev/null || printf '(no channel file)\n'
    printf '(end)\n'
  } | sed -e "s#$ROOT#\$LAB#g" -e "s#$W#<worktree>#g" > "$f"
  printf '%-52s exit=%s channel lines %s -> %s\n' "$label" "$rc" "$before" "$(cat "$P/state/$mate.status" 2>/dev/null | wc -l | tr -d ' ')"
}

setup_home "$A" sm-a
bind_parent "$A" mate-a
step "$A" mate-a s01-child-registers-pr fm-pr-check.sh sm-a "$URL"
head_in_line=$(sed -n 's/.* head=\([0-9a-f]*\).*/\1/p' "$P/state/mate-a.status" | tail -1)
step "$A" mate-a s02-mate-records-relayed-head fm-approved-head.sh record sm-a "$URL" "${head_in_line:-missing}"
step "$A" mate-a s03-merge-at-relayed-head fm-pr-merge.sh sm-a "$URL"

setup_home "$B" sm-b
step "$B" mate-b s04-register-before-binding fm-pr-check.sh sm-b "$URL"
bind_parent "$B" mate-b
step "$B" mate-b s05-mate-records-older-relayed-head fm-approved-head.sh record sm-b "$URL" "$SHOWN_EARLIER"
step "$B" mate-b s06-merge-refuses-and-republishes fm-pr-merge.sh sm-b "$URL"
