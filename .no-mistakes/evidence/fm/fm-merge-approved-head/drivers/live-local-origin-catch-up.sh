#!/usr/bin/env bash
# Live drive of bin/fm-approved-head.sh verify with real git against a local
# bare origin laid out like GitHub (main + refs/pull/<n>/head). Each case
# plays the worker (author clone) pushing to the PR after the captain's word.
# Usage: live-local-origin-catch-up.sh <repo-worktree> <lab-home>
set -u
REPO=$1 LAB=$2
ROOT=$LAB/local-forge
rm -rf "$ROOT"; mkdir -p "$ROOT"
lab() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$LAB/pathfix:$PATH" "$@"; }
run() { printf '$ %s\n' "${*#"$REPO/"}"; local rc=0; lab "$@" 2>&1 || rc=$?; printf '[exit %s]\n' "$rc"; }
g() { git -C "$ROOT/$CASE/author" "$@"; }
new_case() {  # <case> <pr-number>  -> sets CASE N URL APPROVED T
  CASE=$1 N=$2 URL=https://github.com/example/repo/pull/$2 T=appr-$1
  local c=$ROOT/$CASE
  mkdir -p "$c"; git init -q --bare -b main "$c/origin.git"
  git init -q -b main "$c/author"; g config user.email lab@example.com; g config user.name Lab
  printf 'one\ntwo\nthree\nfour\nfive\n' > "$c/author/shared.txt"; g add shared.txt; g commit -qm 'base: add shared'
  g remote add origin "$c/origin.git"; g push -q origin main
  g checkout -q -b feature
  printf 'one\nTWO from the pull request\nthree\nfour\nfive\n' > "$c/author/shared.txt"; printf 'feature\n' > "$c/author/feature.txt"
  g add -A; g commit -qm 'feat: the approved change'; g push -q origin "HEAD:refs/pull/$N/head"
  git clone -q "$c/origin.git" "$c/wt"
  APPROVED=$(g rev-parse HEAD)
  printf 'window=fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\npr=%s\n' "$T" "$c/wt" "$c/wt" "$URL" > "$LAB/state/$T.meta"
  printf '\n### case %s: the captain says merge at %s (recorded by the chat ask)\n' "$CASE" "$APPROVED"
  run "$REPO/bin/fm-approved-head.sh" record "$T" "$URL" "$APPROVED"
}
base_commit() { g checkout -q main; printf '%s\n' "$2" > "$ROOT/$CASE/author/$1"; g add "$1"; g commit -qm "$3"; g push -q origin main; g checkout -q feature; }
push_pr() { g push -q -f origin "HEAD:refs/pull/$N/head"; LIVE=$(g rev-parse HEAD); }
verify() { printf 'history the worker pushed after approval:\n'; g log --graph --format='%h %s' "$LIVE" -6 | sed 's/^/    /'; run "$REPO/bin/fm-approved-head.sh" verify "$T" "$URL" "$LIVE" main; }

new_case update-branch 101
printf -- '-- base moves (a neighbouring-line edit + an unrelated file), then the worker or GitHub "Update branch" merges main in, conflict-free\n'
base_commit shared.txt $'one\ntwo\nthree\nfour changed on main\nfive' 'base: touch a neighbouring line'
base_commit other.txt other 'base: an unrelated change'
g merge -q --no-edit main; push_pr; verify

new_case ci-fix-push 102
printf -- '-- an agent pushes a CI fix after approval, then merges main in\n'
printf 'fixed\n' > "$ROOT/$CASE/author/ci.txt"; g add ci.txt; g commit -qm 'fix: pipeline tweak after approval'
base_commit other.txt other 'base: an unrelated change'; g merge -q --no-edit main; push_pr; verify

new_case hand-resolved 103
printf -- '-- main changes the same line, the merge conflicts, and the worker resolves it by hand\n'
base_commit shared.txt $'one\nTWO from main\nthree\nfour\nfive' 'base: change the same line'
g merge -q --no-edit main >/dev/null 2>&1 && echo "fixture did not conflict"
printf 'one\nTWO resolved by hand\nthree\nfour\nfive\n' > "$ROOT/$CASE/author/shared.txt"; g add shared.txt; g commit -q --no-edit
push_pr; verify

new_case evil-merge 104
printf -- '-- a conflict-free merge of main that slips in an edit of its own (amended merge)\n'
base_commit other.txt other 'base: an unrelated change'; g merge -q --no-edit main
printf 'slipped in\n' >> "$ROOT/$CASE/author/feature.txt"; g commit -q -a --amend --no-edit; push_pr; verify

new_case force-push 105
printf -- '-- the worker rebases onto main and force-pushes\n'
base_commit other.txt other 'base: an unrelated change'; g rebase -q main; push_pr; verify

new_case moved-during-verify 106
printf -- '-- the merge verified head X, but the PR ref on origin already moved on (a racing push)\n'
base_commit other.txt other 'base: an unrelated change'; g merge -q --no-edit main; push_pr
VERIFIED=$LIVE
printf 'race\n' > "$ROOT/$CASE/author/race.txt"; g add race.txt; g commit -qm 'racing push'; g push -q origin "HEAD:refs/pull/$N/head"
LIVE=$VERIFIED; verify
printf '\nprivate refs/fm-approved-head refs left in any task worktree: [%s]\n' \
  "$(for c in "$ROOT"/*/wt; do git -C "$c" for-each-ref refs/fm-approved-head; done)"
