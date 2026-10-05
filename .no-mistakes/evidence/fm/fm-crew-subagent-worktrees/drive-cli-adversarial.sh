#!/usr/bin/env bash
# Live CLI driver for bin/fm-subagent-worktree.sh adversarial scenarios.
# Builds a throwaway project + origin + linked task worktree + scratch root,
# then drives the real script exactly as Claude's WorktreeCreate hook and
# fm-teardown/fm-guard callers do. Usage: drive-cli-adversarial.sh <repo-root>
set -u
ROOT=$1
SWT="$ROOT/bin/fm-subagent-worktree.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-swt-adv.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null

step() { printf '\n$ %s\n' "$*"; }
run() { step "$*"; "$@"; printf '[exit %s]\n' "$?"; }

hook() {  # <task-wt> <scratch> <name>
  printf '{"session_id":"s1","hook_event_name":"WorktreeCreate","cwd":"%s","name":"%s"}' "$1" "$3" \
    | "$SWT" create "$1" "$2"
}

fresh() {  # <name>: project + origin + task worktree + scratch; sets P WT S
  local d="$LAB/$1"
  git init -q --bare -b main "$d/origin.git"
  git init -q -b main "$d/project"
  git -C "$d/project" commit -q --allow-empty -m init
  git -C "$d/project" remote add origin "$d/origin.git"
  git -C "$d/project" push -q -u origin main
  git -C "$d/project" remote set-head origin main >/dev/null
  git -C "$d/project" worktree add -q -b fm/task "$d/wt" main
  P="$d/project" WT="$d/wt" S="$d/scratch"
}

echo "=== A. Hook fails closed instead of placing a copy in the main checkout ==="
fresh a
step "hook with scratch root INSIDE the main checkout ($P/.claude)"
hook "$WT" "$P/.claude" agent-a; echo "[exit $?]"
step "anything created under the main checkout?"
ls -A "$P"; git -C "$P" status --porcelain --untracked-files=all; git -C "$P" worktree list
step "hook with scratch root INSIDE the task worktree"
hook "$WT" "$WT/tmp" agent-a; echo "[exit $?]"
step "hook with a relative scratch root"
hook "$WT" "rel/scratch" agent-a; echo "[exit $?]"
step "hook with a path-traversal name ../escape"
hook "$WT" "$S" ../escape; echo "[exit $?]"
step "hook with an empty payload"
printf '' | "$SWT" create "$WT" "$S"; echo "[exit $?]"
step "valid hook call (what Claude sends): prints the copy path on stdout"
out=$(hook "$WT" "$S" agent-ok 2>/dev/null); echo "[exit $?] stdout=$out"
git -C "$P" worktree list
step "same name again resumes the registered copy"
hook "$WT" "$S" agent-ok 2>/dev/null; echo "[exit $?]"

echo
echo "=== B. status.showUntrackedFiles=no cannot hide a copy's new file (review-r5-1) ==="
fresh b
git -C "$P" config status.showUntrackedFiles no
copy=$(hook "$WT" "$S" agent-b 2>/dev/null)
echo "precious subagent output" > "$copy/newfile.txt"
step "git status in the copy under the hiding config (what a naive test sees)"
git -C "$copy" status --porcelain; echo "[status printed nothing above]"
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"
step "file still on disk?"; ls -l "$copy/newfile.txt"

echo
echo "=== B2. showUntrackedFiles=no set INSIDE a populated submodule ==="
fresh b2
git init -q -b main "$LAB/b2/subsrc"; git -C "$LAB/b2/subsrc" commit -q --allow-empty -m s
git -C "$P" -c protocol.file.allow=always submodule add -q "$LAB/b2/subsrc" sub
git -C "$P" commit -q -m "add sub"; git -C "$P" push -q origin main
git -C "$WT" merge -q --ff-only main
copy=$(hook "$WT" "$S" agent-b2 2>/dev/null)
git -C "$copy" -c protocol.file.allow=always submodule update -q --init
git -C "$copy/sub" config status.showUntrackedFiles no
echo x > "$copy/sub/untracked-in-sub.txt"
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"
step "submodule file still on disk?"; ls -l "$copy/sub/untracked-in-sub.txt"

echo
echo "=== C. A copy whose .git file was deleted (review-r5-2) ==="
fresh c
copy=$(hook "$WT" "$S" agent-c 2>/dev/null)
echo "keep me" > "$copy/untracked.txt"
rm "$copy/.git"
step "git porcelain marks it prunable:"; git -C "$P" worktree list --porcelain | grep -A5 "agent-c"
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"
step "copy and file still on disk after a non-discard retire?"; ls -A "$copy"
run "$SWT" retire --discard "$WT" "$WT" "$S"
step "after --discard: on disk?"; ls -A "$copy" 2>&1
step "after --discard: still registered?"; git -C "$P" worktree list

echo
echo "=== D. Submodule-only commit merged into the task branch (review-r3-1) ==="
fresh d
git init -q -b main "$LAB/d/subsrc"; git -C "$LAB/d/subsrc" commit -q --allow-empty -m s
git -C "$P" -c protocol.file.allow=always submodule add -q "$LAB/d/subsrc" sub
git -C "$P" commit -q -m "add sub"; git -C "$P" push -q origin main
git -C "$WT" merge -q --ff-only main
copy=$(hook "$WT" "$S" agent-s 2>/dev/null)
git -C "$copy" -c protocol.file.allow=always submodule update -q --init
git -C "$copy/sub" commit -q --allow-empty -m "only here"
git -C "$copy" add sub; git -C "$copy" commit -q -m "bump sub"
git -C "$WT" merge -q --ff-only worktree-agent-s
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"
step "after the scratch root vanishes (reboot clears /tmp), the admin dir still holds the sub commit:"
rm -rf "$S"
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"

echo
echo "=== E. Landed copy is retired and its merged branch deleted ==="
fresh e
copy=$(hook "$WT" "$S" agent-e 2>/dev/null)
echo work > "$copy/f.txt"; git -C "$copy" add f.txt; git -C "$copy" commit -q -m "subagent work"
run "$SWT" list "$WT" "$WT" "$S"
git -C "$WT" merge -q --ff-only worktree-agent-e
run "$SWT" list "$WT" "$WT" "$S"
run "$SWT" retire "$WT" "$WT" "$S"
step "branch worktree-agent-e still present?"; git -C "$P" branch --list 'worktree-*'; echo "[none listed above]"
step "copy on disk?"; ls "$copy" 2>&1
