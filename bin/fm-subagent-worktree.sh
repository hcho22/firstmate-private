#!/usr/bin/env bash
# fm-subagent-worktree.sh - single owner of where a worker's isolated-subagent
# git worktrees live, of the landed-work test for them, and of retiring them.
#
# Why this exists: a task worktree is a LINKED git worktree that shares the
# project's git common dir. Claude Code resolves that common dir back to the
# repository's MAIN checkout and, by default, creates every worktree it
# isolates work into (Agent `isolation: "worktree"`, `--worktree`,
# EnterWorktree) under `<main checkout>/.claude/worktrees/<name>` on a
# `worktree-<name>` branch. Launched from a task worktree, that copy lands
# outside the worker's own isolated copy: registered in the shared repository
# and untracked in the primary checkout. For firstmate-on-itself the main
# checkout is the primary firstmate home, which must never hold project work.
#
# The structural fix: bin/fm-spawn.sh writes `create` below as a Claude
# worker's WorktreeCreate hook in the task worktree's
# `.claude/settings.local.json`. A configured WorktreeCreate hook
# replaces Claude's own placement, so the copy lands in the task's own scratch
# root instead: `<scratch-root>/worktrees/<slug>`, where <scratch-root> is the
# task's tasktmp (`/tmp/fm-<id>`). Outside every checkout, such a copy never
# shows up in `git status`, can never be staged into a commit as an embedded
# repository, and never touches the primary. bin/fm-teardown.sh inventories
# and retires these copies through `list` and `retire`, and
# bin/fm-tangle-lib.sh reports any registered worktree that still appears
# inside a primary checkout.
#
# Claude facts this depends on (verified 2026-10-03 on Claude Code 2.1.284;
# tests/fm-subagent-worktree-live-e2e.test.sh re-proves them against the
# installed binary):
#   - The hook fires for Agent isolation from the task worktree's
#     `.claude/settings.local.json`, and Claude uses the absolute path the
#     command prints on stdout; exit 0 with no path, or any non-zero exit,
#     fails the creation, so this hook fails closed and never falls back to the
#     primary checkout.
#   - The input names the worktree in `name`; Claude's published hook docs say
#     `worktree_name` plus `base_ref`, so both spellings are read.
#   - The printed path must be absolute and dot-free; the canonical path is
#     printed because Claude screens symlinked components.
#   - Claude keeps every hook-created agent worktree when its subagent ends, and
#     a print-mode `--worktree` session's copy at exit, without dispatching
#     WorktreeRemove, so no WorktreeRemove hook is wired: these copies
#     accumulate in the scratch root until teardown retires them.
#
# Usage:
#   fm-subagent-worktree.sh create <task-worktree> <scratch-root>   < hook JSON
#   fm-subagent-worktree.sh list <anchor> [<dir>...]
#   fm-subagent-worktree.sh retire [--discard] <anchor> [<dir>...]
#
# create  WorktreeCreate hook. Reads `.worktree_name // .name` and optional
#         `.base_ref` from stdin. The name must be a git-branch-safe slug; `/`
#         maps to `+` exactly as Claude does. The copy is created at
#         <scratch-root>/worktrees/<slug> on branch `worktree-<slug>`, based on
#         `base_ref` when Claude supplies one, otherwise on the remote default
#         branch (`origin/HEAD`, mirroring Claude's own default) and, without
#         one, on the task worktree's HEAD. No fetch runs: the hook stays
#         offline and bounded, and the task's spawn already refreshed that base.
#         An existing `worktree-<slug>` branch is attached, never reset, so no
#         commit is ever discarded. An existing registered copy at the
#         destination is resumed. Prints the canonical destination on stdout;
#         every git message goes to stderr. Refuses (exit 1), before creating
#         anything, a destination inside the repository's main checkout or the
#         task worktree, a missing or relative scratch root, a task worktree
#         that is not a git work tree, an invalid name or payload, or missing jq.
# list    Prints one `<state>\t<path>\t<branch>` line per registered worktree of
#         <anchor>'s repository whose path lies inside one of the <dir>s
#         (default: <anchor>), excluding the main checkout and each <dir>
#         itself. Each <dir> is resolved through symlinks even after it is
#         gone, so a vanished scratch root still matches its copies. Exits 1
#         when git cannot list the repository's worktrees. <state> is:
#           landed    clean (ignored files allowed; submodules are checked
#                     whatever their `ignore` setting), every populated
#                     submodule's HEAD and local branches, recursively, are on
#                     that submodule's remote-tracking refs, and its HEAD is
#                     contained in <anchor>'s HEAD or in any remote-tracking
#                     ref - no work would be lost by removing it;
#           unlanded  uncommitted or untracked changes, commits found nowhere
#                     else, or a copy that cannot be inspected - including a
#                     vanished copy whose git admin dir still holds submodule
#                     git dirs, or whose detached HEAD is the only ref to a
#                     commit that fails the landed test;
#           locked    git-locked, so it is never removed without --discard;
#           missing   registered but its directory is gone, and its admin
#                     dir holds no work of its own.
#         <branch> is the checked-out branch name, or `detached`.
# retire  Removes every listed `landed` copy, with --force so populated
#         submodules cannot block a copy just verified clean, and deregisters
#         every `missing` one even when it is locked. Every `unlanded` or
#         `locked` copy is refused with a REFUSED line on stderr, exiting 1
#         when anything was refused or failed. --discard is for callers that
#         already hold discard authority (teardown --force, or a scout's
#         declared-scratch copy): it force-removes every listed copy whatever
#         its state. After every removal, the copy's `worktree-*` branch is
#         deleted only while its tip is contained in <anchor>'s HEAD or in a
#         remote-tracking ref, so a branch holding commits found nowhere else
#         is always kept. Prints `retired: <path>` per removed copy on stdout.
#
# bin/fm-teardown.sh uses `<task-worktree>` (or the project checkout when that
# copy is gone) as <anchor> and both the task worktree and its scratch root as
# <dir>s. The primary-checkout report uses `retire <primary>` as its remedy.
set -u

# The hook inherits the harness's environment. Any of these would redirect the
# `git -C` calls below away from the paths this script was given.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

usage() {
  sed -n '/^# Usage:/,/^# create /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

die() {
  printf 'fm-subagent-worktree: %s\n' "$1" >&2
  exit 1
}

canonical_dir() {
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# Canonicalize an absolute path that may not exist yet: resolve its deepest
# existing ancestor and re-append the rest.
canonical_path() {
  local path=${1%/} rest='' parent
  while [ -n "$path" ] && [ ! -d "$path" ]; do
    rest="/${path##*/}$rest"
    parent=${path%/*}
    [ "$parent" != "$path" ] || return 1
    path=$parent
  done
  path=$(canonical_dir "${path:-/}") || return 1
  printf '%s%s\n' "${path%/}" "$rest"
}

# path_inside <path> <dir>: true when <path> is <dir> itself or below it.
path_inside() {
  case "$1/" in
    "$2/"*) return 0 ;;
  esac
  return 1
}

hook_field() {  # <json> <jq-filter>
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null
}

read_hook_payload() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read the harness worktree hook payload"
  HOOK_PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$HOOK_PAYLOAD" ] || die "empty worktree hook payload"
  printf '%s' "$HOOK_PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "worktree hook payload is not a JSON object"
}

# Set WORKTREE_PORCELAIN to `git worktree list --porcelain` for <repo>'s
# repository, or die when git cannot list it.
read_worktree_porcelain() {  # <repo>
  WORKTREE_PORCELAIN=$(git -C "$1" worktree list --porcelain) \
    || die "cannot list the registered worktrees of $1"
}

# Echo the main checkout of the repository that owns <worktree>.
main_checkout_of() {
  local line
  line=$(git -C "$1" worktree list --porcelain 2>/dev/null | head -1) || return 1
  case "$line" in
    "worktree "*) printf '%s\n' "${line#worktree }" ;;
    *) return 1 ;;
  esac
}

# True when <canonical-path> is a registered worktree of <repo>'s repository.
registered_worktree() {  # <repo> <canonical-path>
  local want=$2 line path real
  read_worktree_porcelain "$1"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=${line#worktree }
        real=$(canonical_dir "$path") || real=$path
        [ "$real" != "$want" ] || return 0
        ;;
    esac
  done <<EOF
$WORKTREE_PORCELAIN
EOF
  return 1
}

resolve_task_args() {  # <task-worktree> <scratch-root>
  TASK_WT=${1:-}
  SCRATCH_ROOT=${2:-}
  [ -n "$TASK_WT" ] && [ -n "$SCRATCH_ROOT" ] || { usage; exit 2; }
  case "$SCRATCH_ROOT" in
    /*) ;;
    *) die "scratch root must be an absolute path: $SCRATCH_ROOT" ;;
  esac
  git -C "$TASK_WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "task worktree is not a git work tree: $TASK_WT"
  TASK_WT_REAL=$(git -C "$TASK_WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "cannot resolve the task worktree root: $TASK_WT"
  TASK_WT_REAL=$(canonical_dir "$TASK_WT_REAL") || die "cannot resolve the task worktree root: $TASK_WT"
  MAIN_CHECKOUT=$(main_checkout_of "$TASK_WT_REAL") || die "cannot resolve the main checkout of $TASK_WT"
  MAIN_CHECKOUT_REAL=$(canonical_dir "$MAIN_CHECKOUT") || MAIN_CHECKOUT_REAL=$MAIN_CHECKOUT
}

cmd_create() {
  local name slug branch base base_commit worktrees dest dest_real default_ref
  resolve_task_args "$@"
  read_hook_payload
  name=$(hook_field "$HOOK_PAYLOAD" '.worktree_name // .name')
  [ -n "$name" ] || die "worktree hook payload names no worktree"
  case "$name" in
    -*|.*|*/|*//*|*..*|*.lock|*/.*) die "unsupported worktree name: $name" ;;
  esac
  printf '%s' "$name" | LC_ALL=C grep -Eq '^[A-Za-z0-9._/+-]{1,128}$' \
    || die "unsupported worktree name: $name"
  slug=$(printf '%s' "$name" | tr '/' '+')
  branch="worktree-$slug"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "worktree name does not form a valid branch: $name"

  worktrees=$(canonical_path "$SCRATCH_ROOT/worktrees") \
    || die "cannot resolve the scratch worktree directory: $SCRATCH_ROOT/worktrees"
  dest="$worktrees/$slug"
  if path_inside "$dest" "$MAIN_CHECKOUT_REAL"; then
    die "refusing to place a worktree inside the main checkout $MAIN_CHECKOUT_REAL: $dest"
  fi
  if path_inside "$dest" "$TASK_WT_REAL"; then
    die "refusing to place a worktree inside the task worktree $TASK_WT_REAL: $dest"
  fi
  mkdir -p "$worktrees" || die "cannot create the scratch worktree directory: $worktrees"

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    dest_real=$(canonical_dir "$dest") || die "destination exists but is not a directory: $dest"
    registered_worktree "$TASK_WT_REAL" "$dest_real" \
      || die "destination exists but is not a registered worktree of this repository: $dest"
    printf '%s\n' "$dest_real"
    return 0
  fi

  if git -C "$TASK_WT_REAL" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$TASK_WT_REAL" worktree add "$dest" "$branch" >&2 \
      || die "could not attach existing branch $branch at $dest"
  else
    base=$(hook_field "$HOOK_PAYLOAD" '.base_ref')
    if [ -z "$base" ]; then
      default_ref=$(git -C "$TASK_WT_REAL" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
      if [ -n "$default_ref" ] && git -C "$TASK_WT_REAL" rev-parse --verify --quiet "$default_ref^{commit}" >/dev/null; then
        base=$default_ref
      else
        base=HEAD
      fi
    fi
    base_commit=$(git -C "$TASK_WT_REAL" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) \
      || die "cannot resolve worktree base '$base'"
    git -C "$TASK_WT_REAL" worktree add -b "$branch" "$dest" "$base_commit" >&2 \
      || die "git worktree add failed for $dest"
  fi
  dest_real=$(canonical_dir "$dest") || die "created worktree is missing: $dest"
  printf '%s\n' "$dest_real"
}

# True when <commit> is contained in <anchor>'s HEAD or in any remote-tracking
# ref, so dropping every other reference to it loses nothing.
commit_landed() {  # <anchor> <commit>
  local contained
  git -C "$1" merge-base --is-ancestor "$2" HEAD >/dev/null 2>&1 && return 0
  contained=$(git -C "$1" for-each-ref --count=1 --contains "$2" --format='%(refname)' refs/remotes 2>/dev/null || true)
  [ -n "$contained" ]
}

# Classify one existing copy. Echoes landed|unlanded.
classify_copy() {  # <anchor> <path> <head>
  local anchor=$1 path=$2 head=$3 status unpushed
  status=$(git -C "$path" status --porcelain --ignore-submodules=none 2>/dev/null) || { echo unlanded; return; }
  unpushed=$(git -C "$path" submodule foreach --quiet --recursive \
    'git log --format=%H -1 HEAD --branches --not --remotes --' 2>/dev/null) || { echo unlanded; return; }
  if [ -z "$status" ] && [ -z "$unpushed" ] && [ -n "$head" ] && commit_landed "$anchor" "$head"; then
    echo landed
  else
    echo unlanded
  fi
}

# Echo the git admin dir of the registered worktree at <path>: the common dir's
# `worktrees/*` entry whose `gitdir` file names <path>/.git.
worktree_admin_dir() {  # <anchor> <path>
  local common admin gitdir want
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$1/$common" ;;
  esac
  want=$(canonical_path "$2/.git") || return 1
  for admin in "$common"/worktrees/*; do
    gitdir=$(cat "$admin/gitdir" 2>/dev/null) || continue
    case "$gitdir" in
      /*) ;;
      *) gitdir="$admin/$gitdir" ;;
    esac
    [ "$(canonical_path "$gitdir")" = "$want" ] || continue
    printf '%s\n' "$admin"
    return 0
  done
  return 1
}

# Classify one registered copy whose directory is gone. Echoes missing|unlanded.
# Its admin dir outlives it and is deleted on removal, so submodule git dirs
# there, or a detached HEAD there that is the only ref to its commit, make it
# unlanded.
classify_missing_copy() {  # <anchor> <path> <head> <branch>
  local admin
  admin=$(worktree_admin_dir "$1" "$2") || { echo unlanded; return; }
  if [ -e "$admin/modules" ]; then
    echo unlanded
  elif [ -z "$4" ] && { [ -z "$3" ] || ! commit_landed "$1" "$3"; }; then
    echo unlanded
  else
    echo missing
  fi
}

# Delete a retired copy's `worktree-*` branch while its tip still passes the
# landed test; the delete compares against that tested tip.
retire_branch() {  # <anchor> <branch>
  local tip
  case "$2" in
    worktree-*) ;;
    *) return 0 ;;
  esac
  tip=$(git -C "$1" rev-parse --verify --quiet "refs/heads/$2" 2>/dev/null) || return 0
  commit_landed "$1" "$tip" || return 0
  git -C "$1" update-ref -d "refs/heads/$2" "$tip" >/dev/null 2>&1 || true
}

# Append one list line to LIST_OUT for a registered worktree record when it
# lies inside one of SCOPES, excluding each scope directory itself.
record_copy() {  # <anchor> <path> <head> <branch> <locked> <prunable>
  local anchor=$1 path=$2 head=$3 branch=$4 locked=$5 prunable=$6 real scope_dir in_scope=0 state line
  real=$(canonical_path "$path") || real=$path
  for scope_dir in ${SCOPES[@]+"${SCOPES[@]}"}; do
    [ "$real" != "$scope_dir" ] || return 0
    if path_inside "$real" "$scope_dir"; then
      in_scope=1
    fi
  done
  [ "$in_scope" -eq 1 ] || return 0
  if [ "$prunable" -eq 1 ] || [ ! -d "$path" ]; then
    state=$(classify_missing_copy "$anchor" "$path" "$head" "$branch")
  elif [ "$locked" -eq 1 ]; then
    state=locked
  else
    state=$(classify_copy "$anchor" "$real" "$head")
  fi
  printf -v line '%s\t%s\t%s\n' "$state" "$real" "${branch:-detached}"
  LIST_OUT=$LIST_OUT$line
}

# Set LIST_OUT to the list lines for <anchor> [<dir>...]. The first porcelain
# record is always the repository's main checkout, which is never a copy.
collect_copies() {
  local anchor=$1 line dir real path='' head='' branch='' locked=0 prunable=0 records=0
  shift
  [ "$#" -gt 0 ] || set -- "$anchor"
  SCOPES=()
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    real=$(canonical_path "$dir") || real=${dir%/}
    SCOPES+=("$real")
  done
  read_worktree_porcelain "$anchor"
  LIST_OUT=
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        [ "$records" -lt 2 ] || record_copy "$anchor" "$path" "$head" "$branch" "$locked" "$prunable"
        records=$((records + 1))
        path=${line#worktree }
        head='' branch='' locked=0 prunable=0
        ;;
      "HEAD "*) head=${line#HEAD } ;;
      "branch "*) branch=${line#branch refs/heads/} ;;
      locked|"locked "*) locked=1 ;;
      prunable|"prunable "*) prunable=1 ;;
    esac
  done <<EOF
$WORKTREE_PORCELAIN
EOF
  [ "$records" -lt 2 ] || record_copy "$anchor" "$path" "$head" "$branch" "$locked" "$prunable"
}

require_anchor() {
  [ -n "${1:-}" ] || { usage; exit 2; }
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "anchor is not a git work tree: $1"
}

cmd_list() {
  require_anchor "${1:-}"
  collect_copies "$@"
  printf '%s' "$LIST_OUT"
}

cmd_retire() {
  local discard=0 anchor state path branch failed=0
  local -a force
  if [ "${1:-}" = --discard ]; then
    discard=1
    shift
  fi
  require_anchor "${1:-}"
  anchor=$1
  collect_copies "$@"
  while IFS=$'\t' read -r state path branch; do
    [ -n "$path" ] || continue
    if [ "$discard" -eq 1 ]; then
      force=(--force --force)
    else
      case "$state" in
        landed) force=(--force) ;;
        missing) force=(--force --force) ;;
        *)
          printf 'REFUSED: worktree %s (branch %s) is %s; inspect it and land or preserve its work first\n' \
            "$path" "$branch" "$state" >&2
          failed=1
          continue
          ;;
      esac
    fi
    if git -C "$anchor" worktree remove "${force[@]}" "$path" >/dev/null 2>&1; then
      printf 'retired: %s\n' "$path"
      retire_branch "$anchor" "$branch"
    else
      printf 'REFUSED: could not remove worktree %s (git kept it)\n' "$path" >&2
      failed=1
    fi
  done <<EOF
$LIST_OUT
EOF
  return "$failed"
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  list) shift; cmd_list "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
