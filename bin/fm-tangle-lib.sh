# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.
#
# fm_primary_nested_worktrees detects the second tangle shape: a LINKED worktree
# registered inside the primary checkout, such as the `.claude/worktrees/*`
# copies Claude creates in the repository's main checkout when a worker's
# isolated subagent runs without bin/fm-subagent-worktree.sh's placement hook.
# Nothing legitimate lives there - task worktrees and secondmate homes are
# leased outside it, and project clones are separate repositories - so every
# such worktree is reported.

FM_TANGLE_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}

# List every linked worktree registered inside the git checkout at <root>, one
# `<state>\t<path>\t<branch>` line each, and return 0; for none, or when <root>
# is not a git work tree, echo nothing and return 1. <state> distinguishes a
# copy that holds no unique work (landed) from one that must be inspected
# first; bin/fm-subagent-worktree.sh owns the inventory, the states, and the
# `retire <root>` remedy.
fm_primary_nested_worktrees() {
  local root=$1 listing
  listing=$("${FM_TANGLE_LIB_DIR}/fm-subagent-worktree.sh" list "$root" 2>/dev/null) || return 1
  [ -n "$listing" ] || return 1
  printf '%s\n' "$listing"
}
