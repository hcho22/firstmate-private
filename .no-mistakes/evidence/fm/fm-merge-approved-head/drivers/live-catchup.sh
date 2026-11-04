#!/bin/bash
# Live validation of the clean catch-up rule in bin/fm-approved-head.sh with
# real git. Each case builds a real origin repository that serves the pull
# request head at refs/pull/7/head (GitHub's layout), a task worktree cloned
# from it, and a marked lab home task record, then runs the real
# `fm-approved-head.sh record` and `verify` exactly as bin/fm-pr-merge.sh calls
# verify. No forge is contacted: verify reads only git.
# Usage: live-catchup.sh <firstmate-worktree> <transcript-dir>
set -u
W=$1
OUT=$2
mkdir -p "$OUT"
URL=https://github.com/lab-owner/lab-repo/pull/7
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

fm() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$W/bin/$@"; }

# setup <case>: origin + author on feature at the approved head + task worktree + meta.
setup() {
  C=$LAB/$1
  mkdir -p "$C"
  git init -q --bare -b main "$C/origin.git"
  git init -q -b main "$C/author"
  git -C "$C/author" remote add origin "$C/origin.git"
  printf 'one\ntwo\nthree\nfour\nfive\n' > "$C/author/shared.txt"
  git -C "$C/author" add shared.txt && git -C "$C/author" commit -qm 'base: initial'
  git -C "$C/author" push -q origin main
  git -C "$C/author" checkout -qb feature
  printf 'feature work\n' > "$C/author/feature.txt"
  git -C "$C/author" add feature.txt && git -C "$C/author" commit -qm 'feat: the change the captain reviewed'
  APPROVED=$(push_head)
  git clone -q "$C/origin.git" "$C/wt"
  { printf 'window=fm-%s\nworktree=%s\nkind=ship\nmode=no-mistakes\nyolo=off\npr=%s\n' "$1" "$C/wt" "$URL"; } > "$LAB/state/$1.meta"
  chmod 600 "$LAB/state/$1.meta"
  fm fm-approved-head.sh record "$1" "$URL" "$APPROVED" > "$C/record.out" 2>&1
}
push_head() { git -C "$C/author" push -q -f origin HEAD:refs/heads/feature HEAD:refs/pull/7/head; git -C "$C/author" rev-parse HEAD; }
main_commit() {  # <file> <content> <subject>
  git -C "$C/author" checkout -q main
  printf '%s\n' "$2" > "$C/author/$1"
  git -C "$C/author" add "$1" && git -C "$C/author" commit -qm "$3"
  git -C "$C/author" push -q origin main
  git -C "$C/author" checkout -q feature
}

verify() {  # <case> <label> <live> <what happened>
  local id=$1 label=$2 live=$3 what=$4 rc=0 f="$OUT/$2.txt"
  fm fm-approved-head.sh verify "$id" "$URL" "$live" main > "$C/v.out" 2> "$C/v.err" || rc=$?
  {
    printf '# %s\n' "$label"
    printf 'what happened after the captain approved: %s\n' "$what"
    printf 'captain-approved head (recorded): %s\n' "$APPROVED"
    printf '%s\n' "$(cat "$C/record.out")"
    printf 'pull request history now (git log --graph of refs/pull/7/head):\n'
    git -C "$C/author" log --graph --format='%h %s' "$live" 2>/dev/null | sed 's/^/  /'
    printf '$ FM_HOME=$LAB bin/fm-approved-head.sh verify %s %s %s main\n' "$id" "$URL" "$live"
    printf '## exit status: %s\n' "$rc"
    printf '## stdout\n'; cat "$C/v.out"
    printf '## stderr\n'; cat "$C/v.err"
    printf '## private refs left in the task worktree\n'; git -C "$C/wt" for-each-ref refs/fm-approved-head 2>/dev/null || printf '(task worktree absent)\n'
    printf '(end)\n'
  } | sed -e "s#$LAB#\$LAB#g" -e "s#$W#<worktree>#g" > "$f"
  printf '%-48s exit=%s\n' "$label" "$rc"
}

setup c01
verify c01 c01-unchanged-head "$APPROVED" "nothing; the head is the one shown"

setup c02
main_commit shared.txt $'one\ntwo\nthree\nfour changed on main\nfive' 'base: touch a neighbouring line'
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" merge -q --no-edit main
verify c02 c02-clean-catch-up-with-main "$(push_head)" "main moved twice and the branch was caught up with an automatic merge (an update-branch)"

setup c03
main_commit other.txt 'other' 'base: first change'
git -C "$C/author" merge -q --no-edit main
main_commit more.txt 'more' 'base: second change'
git -C "$C/author" merge -q --no-edit main
verify c03 c03-two-successive-clean-catch-ups "$(push_head)" "two automatic catch-up merges with main in a row"

setup c04
printf 'fixed\n' > "$C/author/ci.txt"; git -C "$C/author" add ci.txt; git -C "$C/author" commit -qm 'fix: a CI tweak after approval'
verify c04 c04-agent-pushes-ci-fix "$(push_head)" "the worker pushed a CI fix commit"

setup c05
main_commit shared.txt $'one\nTWO from main\nthree\nfour\nfive' 'base: change line two'
printf 'one\nTWO from feature\nthree\nfour\nfive\n' > "$C/author/shared.txt"; git -C "$C/author" add shared.txt; git -C "$C/author" commit -qm 'feat: also edit line two'
APPROVED=$(push_head); fm fm-approved-head.sh record c05 "$URL" "$APPROVED" > "$C/record.out" 2>&1
git -C "$C/author" merge -q --no-edit main >/dev/null 2>&1 || true
printf 'one\nTWO resolved by hand\nthree\nfour\nfive\n' > "$C/author/shared.txt"; git -C "$C/author" add shared.txt; git -C "$C/author" commit -qm 'Merge main, resolving the line-two conflict by hand' --no-edit
verify c05 c05-merge-with-hand-resolved-conflict "$(push_head)" "the catch-up merge with main conflicted and the conflict was resolved by hand"

setup c06
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" merge -q --no-edit main
printf 'sneaked in\n' > "$C/author/extra.txt"; git -C "$C/author" add extra.txt; git -C "$C/author" commit -q --amend --no-edit
verify c06 c06-catch-up-merge-carrying-its-own-edit "$(push_head)" "a catch-up merge was amended to carry an extra file (an evil merge)"

setup c07
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" rebase -q main
verify c07 c07-rebase-and-force-push "$(push_head)" "the branch was rebased onto main and force-pushed"

setup c08
git -C "$C/author" checkout -q -b side main; printf 's\n' > "$C/author/side.txt"; git -C "$C/author" add side.txt; git -C "$C/author" commit -qm 'side work'; git -C "$C/author" checkout -q feature
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" merge -q --no-edit main side
verify c08 c08-octopus-merge "$(push_head)" "an octopus merge of main and another branch"

setup c09
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" merge -q --no-edit main
read_live=$(push_head)
printf 'later\n' > "$C/author/later.txt"; git -C "$C/author" add later.txt; git -C "$C/author" commit -qm 'fix: pushed while the merge was verifying'
moved=$(push_head)
verify c09 c09-head-moves-while-verifying "$read_live" "the merge read live head $read_live (a clean catch-up), then a push moved refs/pull/7/head to $moved before the verify fetched it"

setup c10
main_commit other.txt 'other' 'base: an unrelated change'
git -C "$C/author" merge -q --no-edit main
live=$(push_head)
rm -rf "$C/wt"
verify c10 c10-task-worktree-gone "$live" "a clean catch-up, but the task worktree that verify reads commits from is gone"
