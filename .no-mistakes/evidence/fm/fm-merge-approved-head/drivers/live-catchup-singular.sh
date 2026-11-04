#!/bin/bash
# Round-2 singular-count case of the clean catch-up rule (setup copied from live-catchup.sh)
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

# Round 2: the singular wording of the verified line, for a catch-up with exactly
# one commit from main and one clean merge commit.
setup c11
main_commit other.txt 'other' 'base: one unrelated change'
git -C "$C/author" merge -q --no-edit main
verify c11 c11-clean-catch-up-with-one-main-commit "$(push_head)" "main moved once and the branch was caught up with one automatic merge"
