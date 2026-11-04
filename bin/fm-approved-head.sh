#!/usr/bin/env bash
# Bind a captain's merge word to the pull request head commit firstmate showed
# the captain, so an attended merge lands only the commits that were approved.
#
# record <task-id> <pr-url> [<head>]
#   Run when presenting a PR for the captain's merge word in chat, or when a
#   merge word arrives from a surface that carries the head it showed. Stores
#   that head in the task metadata as
#     approved_head=<sha> <canonical-pr-url>
#   atomically under the meta lock, placed before the pr= line because
#   bin/fm-pr-lib.sh's metadata identity parse accepts only pr_head= after it;
#   bin/fm-pr-check.sh's rewrite keeps that order. With no <head> it reads the
#   pull request's live head from the forge, which is the head the presentation
#   then shows. With <head> it records exactly that head and reads nothing, for
#   a head shown elsewhere: the one a bearings board merge card showed, carried
#   by its Merge now answer; the one a secondmate child's PR-ready line carries,
#   relayed with the captain's merge word; or the one a refusal below names. The
#   task must already record pr= for the same URL (bin/fm-pr-check.sh), so a head
#   is never bound to a PR the task does not own. Recording again replaces the
#   previous head, which is how a re-asked approval moves forward. Prints the
#   recorded head.
#
# live <task-id> <pr-url>
#   Prints the pull request's live head for a task that records pr= for that
#   URL, and records nothing. A presentation whose answer carries the head it
#   showed, such as a bearings board merge card (bin/fm-bearings-board.sh),
#   reads its head here, so presenting a PR never rebinds a merge word already
#   given at another head; that answer is recorded when it arrives.
#
# verify <task-id> <pr-url> <live-head> <base-branch> [--away]
#   Called by bin/fm-pr-merge.sh on every merge except a --low-risk one, which
#   runs on standing posture rather than a captain word, after its own live read
#   and before the forge merge command, with --away while the away-posture
#   record exists. A head recorded for this PR is a captain word, so it binds an
#   away merge exactly as it binds an attended one; away authority never widens
#   it. When the captain's own away words explicitly cover a later head, such as
#   "merge it once the fix lands", the away session records that head with
#   record before merging, so the words, not the posture, widen the binding.
#   Exit 0 lets the merge proceed bound to the captain-approved head, exit 3
#   lets it proceed bound to no head under the away or yolo allowance below,
#   exit 1 refuses with every reason on stderr, exit 2 is a usage error. A
#   recorded approved_head counts only when its URL is the PR being merged. The
#   verdict:
#   - approved head equals the live head: proceed.
#   - no approved head recorded for this PR: proceed under --away, because no
#     captain word named a head and the away words are the away session's
#     reading, or when the task meta records yolo=on, because an autonomous
#     yolo merge has no captain word to bind; otherwise refuse and say to
#     present the pull request to the captain again and record the head shown
#     then. The refusal never offers to record the live head, because nothing
#     says the captain was shown it. A task presented before this rule existed
#     therefore refuses once.
#   - the heads differ: proceed only for a clean catch-up with the base branch,
#     otherwise refuse naming both heads and the commits between them, with the
#     record command for the live head it names, to run when the pull request
#     is presented to the captain again at that head.
#   A clean catch-up is defined strictly, and both conditions must hold:
#   1. the approved head is an ancestor of the live head, so nothing was
#      rewritten (a rebase or force-push refuses);
#   2. every commit between them that is not on the current base branch is a
#      two-parent merge whose tree is exactly the conflict-free tree
#      `git merge-tree --write-tree` computes from its parents, so a merge that
#      needed hand-resolved conflicts, or carries any edit of its own, refuses,
#      as does any ordinary commit added on the PR branch.
#   Together they leave the live head nothing but the approved commits and base
#   branch commits combined by automatic merges, so landing it adds nothing to
#   the base branch that the captain did not approve. That holds only because a
#   merge bound to a head here lands the verified head immediately:
#   bin/fm-pr-merge.sh refuses one that asks the forge to merge later (GitHub
#   auto-merge or a merge-queue entry, GitLab auto-merge), which would land
#   whatever the head is by then.
#   The commits are read from the task worktree (worktree= in the meta) after
#   fetching the PR head ref (refs/pull/<n>/head on GitHub and Forgejo,
#   refs/merge-requests/<n>/head on GitLab) and the base branch from origin into
#   private refs/fm-approved-head/<task-id>/ refs, which are deleted on exit,
#   the same private-ref fetch bin/fm-review-diff.sh uses. The fetched head must
#   equal the live head the merge verified. Anything that cannot be read or
#   proven refuses rather than counting as clean, because a refused merge is
#   only asked again while a wrong pass lands commits nobody approved.
#
# Usage: fm-approved-head.sh record <task-id> <pr-url> [<head>]
#        fm-approved-head.sh live <task-id> <pr-url>
#        fm-approved-head.sh verify <task-id> <pr-url> <live-head> <base-branch> [--away]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-approved-head.sh record <task-id> <pr-url> [<head>]" >&2
  echo "       fm-approved-head.sh live <task-id> <pr-url>" >&2
  echo "       fm-approved-head.sh verify <task-id> <pr-url> <live-head> <base-branch> [--away]" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  record) [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || { usage; exit 2; } ;;
  live) [ "$#" -eq 3 ] || { usage; exit 2; } ;;
  verify) [ "$#" -eq 5 ] || { [ "$#" -eq 6 ] && [ "$6" = --away ]; } || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac
COMMAND=$1
ID=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$3" \
  || { [ "$COMMAND" = record ] && [ "$#" -eq 4 ] && ! fm_pr_head_valid "$4"; }; then
  echo "error: invalid approved-head request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

meta_value() {  # <key>
  grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true
}

RECORD_CMD="$SCRIPT_DIR/fm-approved-head.sh record $ID $URL"
REPRESENT_REMEDY="present the pull request to the captain again and record the head shown then with: $RECORD_CMD <head-shown>"

require_task_pr() {
  [ "$(meta_value pr)" = "$URL" ] && return 0
  echo "error: task $ID does not record pr=$URL; register the PR with bin/fm-pr-check.sh before presenting it for the captain's merge word" >&2
  return 1
}

print_live_head() {
  require_task_pr || return 1
  fm_pr_live_head "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER"
}

record_approved_head() {  # [<head>]
  local head=${1-} line state_device inserted=0
  require_task_pr || return 1
  if [ -z "$head" ]; then
    head=$(fm_pr_live_head "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER") || return 1
  fi

  META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$META_LOCK" || return 1
  META_LOCK_HELD=1
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
    || { echo "error: task metadata is unavailable" >&2; return 1; }
  state_device=$(fm_pr_file_device "$STATE") || return 1
  [ "$(fm_pr_file_device "$META")" = "$state_device" ] || { echo "error: task metadata is unavailable" >&2; return 1; }
  META_TMP=$(mktemp "$STATE/.fm-approved-head-meta.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      approved_head=*) continue ;;
      pr=*)
        if [ "$inserted" -eq 0 ]; then
          printf 'approved_head=%s %s\n' "$head" "$URL" >> "$META_TMP" || return 1
          inserted=1
        fi
        ;;
    esac
    printf '%s\n' "$line" >> "$META_TMP" || return 1
  done < "$META"
  [ "$inserted" -eq 1 ] || { echo "error: task $ID no longer records pr=$URL" >&2; return 1; }
  chmod 0600 "$META_TMP" || return 1
  fm_pr_private_file_valid "$META_TMP" 600 "$state_device" || return 1
  fm_pr_metadata_identity_parse "$META_TMP" && [ "$FM_PR_META_URL" = "$URL" ] \
    || { echo "error: task $ID no longer records pr=$URL" >&2; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || return 1
  mv -f -- "$META_TMP" "$META" || return 1
  META_TMP=
  fm_lock_release "$META_LOCK" || return 1
  META_LOCK_HELD=0
  printf 'recorded: approved head %s for %s\n' "$head" "$URL"
}

# The recorded approved head for this PR, or nothing when none is recorded for
# it. A malformed value is reported rather than read as absent, so a corrupt
# record never falls through to the yolo allowance.
APPROVED_HEAD=
read_approved_head() {
  local value head url
  value=$(meta_value approved_head)
  [ -n "$value" ] || return 0
  head=${value%% *}
  url=${value#* }
  if [ "$head" = "$value" ] || ! fm_pr_head_valid "$head" || [ -z "$url" ]; then
    printf 'error: refusing to merge %s: task %s records a malformed approved_head\n' "$URL" "$ID" >&2
    printf 'error: %s\n' "$REPRESENT_REMEDY" >&2
    return 1
  fi
  [ "$url" = "$URL" ] || return 0
  APPROVED_HEAD=$head
}

WT=
FETCH_HEAD_REF=
FETCH_BASE_REF=

git_wt() {
  git -C "$WT" -c color.ui=false "$@"
}

# Prints one line per PR-side commit between <approved> and <live> - one not
# on the fetched base branch - that is not a clean automatic merge.
unclean_own_commits() {  # <approved> <live>
  local approved=$1 live=$2 commits commit parents count tree merged subject
  commits=$(git_wt rev-list --reverse "$live" "^$approved" "^$FETCH_BASE_REF") || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    parents=$(git_wt rev-list --parents -n 1 "$commit") || return 1
    subject=$(git_wt log -1 --format=%s "$commit") || return 1
    # shellcheck disable=SC2086 # Word-splitting the parent list is intended.
    set -- $parents
    shift
    count=$#
    if [ "$count" -lt 2 ]; then
      printf '%s %s (a commit added to the pull request)\n' "$commit" "$subject"
      continue
    fi
    if [ "$count" -gt 2 ]; then
      printf '%s %s (a merge of %s parents)\n' "$commit" "$subject" "$count"
      continue
    fi
    tree=$(git_wt rev-parse "$commit^{tree}") || return 1
    # A conflicted merge exits non-zero while still printing a tree carrying
    # conflict markers, so only a zero exit yields a tree to compare.
    merged=$(git_wt merge-tree --write-tree --no-messages "$1" "$2" 2>/dev/null) || merged=
    merged=${merged%%$'\n'*}
    if [ -z "$merged" ] || [ "$merged" != "$tree" ]; then
      printf '%s %s (a merge whose tree is not the conflict-free automatic merge of its parents)\n' \
        "$commit" "$subject"
    fi
  done <<EOF
$commits
EOF
}

cleanup_refs() {
  [ -n "$WT" ] || return 0
  [ -z "$FETCH_HEAD_REF" ] || git -C "$WT" update-ref -d "$FETCH_HEAD_REF" >/dev/null 2>&1 || true
  [ -z "$FETCH_BASE_REF" ] || git -C "$WT" update-ref -d "$FETCH_BASE_REF" >/dev/null 2>&1 || true
}

refuse_changed() {  # <approved> <live> <reason-lines>
  printf 'error: refusing to merge %s: the captain approved head %s, but the live head is %s\n' "$URL" "$1" "$2" >&2
  printf '%s' "$3" >&2
  printf 'error: present the pull request to the captain again at head %s, recording that head with: %s %s\n' \
    "$2" "$RECORD_CMD" "$2" >&2
}

count_of() {  # <count> <noun>: the count and the noun, plural unless the count is 1
  if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

verify_approved_head() {
  local live=$1 base_branch=$2 away=${3-} pr_ref fetched approved reasons='' unclean own_count all_count line
  if ! fm_pr_head_valid "$live"; then
    echo "error: invalid approved-head request" >&2
    return 2
  fi
  read_approved_head || return 1
  approved=$APPROVED_HEAD
  if [ -z "$approved" ]; then
    if [ "$away" = --away ]; then
      printf 'notice: no captain-approved head is recorded for %s; merging under away authority, bound to no head\n' "$URL" >&2
      return 3
    fi
    if [ "$(meta_value yolo)" = on ]; then
      printf 'notice: no captain-approved head is recorded for %s; merging under the task'"'"'s yolo posture\n' "$URL" >&2
      return 3
    fi
    printf 'error: refusing to merge %s: no captain-approved head is recorded for task %s\n' "$URL" "$ID" >&2
    printf 'error: %s\n' "$REPRESENT_REMEDY" >&2
    return 1
  fi
  if [ "$approved" = "$live" ]; then
    printf 'verified: live head %s of %s is the captain-approved head\n' "$live" "$URL" >&2
    return 0
  fi

  WT=$(meta_value worktree)
  case "$PROVIDER" in
    github|forgejo) pr_ref="refs/pull/$NUMBER/head" ;;
    gitlab) pr_ref="refs/merge-requests/$NUMBER/head" ;;
    *) pr_ref= ;;
  esac
  if [ -z "$WT" ] || [ ! -d "$WT" ] || ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    WT=
    refuse_changed "$approved" "$live" "  - the commits between them could not be read: the task worktree is unavailable
"
    return 1
  fi
  if [ -z "$pr_ref" ] || [ -z "$base_branch" ] \
    || ! git check-ref-format --branch "$base_branch" >/dev/null 2>&1; then
    WT=
    refuse_changed "$approved" "$live" "  - the commits between them could not be read: the base branch is unknown
"
    return 1
  fi
  FETCH_HEAD_REF="refs/fm-approved-head/$ID/head"
  FETCH_BASE_REF="refs/fm-approved-head/$ID/base"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$WT" fetch --quiet --no-tags origin \
      "+$pr_ref:$FETCH_HEAD_REF" "+refs/heads/$base_branch:$FETCH_BASE_REF" >/dev/null 2>&1; then
    refuse_changed "$approved" "$live" "  - the commits between them could not be read: fetching $pr_ref and $base_branch from origin failed
"
    return 1
  fi
  fetched=$(git_wt rev-parse --verify --quiet "$FETCH_HEAD_REF^{commit}" 2>/dev/null) || fetched=
  if [ "$fetched" != "$live" ]; then
    refuse_changed "$approved" "$live" "  - the fetched pull request head ${fetched:-(none)} is not the live head, so the head moved while it was being verified
"
    return 1
  fi
  if ! git_wt merge-base --is-ancestor "$approved" "$live" >/dev/null 2>&1; then
    refuse_changed "$approved" "$live" "  - the approved head is not an ancestor of the live head, so the pull request history was rewritten (a rebase or force-push) or the approved commit is unavailable
"
    return 1
  fi

  if ! unclean=$(unclean_own_commits "$approved" "$live") \
    || ! own_count=$(git_wt rev-list --count "$live" "^$approved" "^$FETCH_BASE_REF") \
    || ! all_count=$(git_wt rev-list --count "$live" "^$approved"); then
    refuse_changed "$approved" "$live" "  - the commits between them could not be read
"
    return 1
  fi
  if [ -n "$unclean" ]; then
    while IFS= read -r line; do
      reasons="$reasons  - $line
"
    done <<EOF
$unclean
EOF
    reasons="$reasons  - $(count_of "$all_count" commit) between the heads, $own_count not on $base_branch
"
    refuse_changed "$approved" "$live" "$reasons"
    return 1
  fi
  printf 'verified: live head %s of %s adds only a clean catch-up with %s to the captain-approved head %s (%s from %s, %s)\n' \
    "$live" "$URL" "$base_branch" "$approved" "$(count_of "$((all_count - own_count))" commit)" "$base_branch" \
    "$(count_of "$own_count" 'clean merge commit')" >&2
}

META_TMP=
META_LOCK=
META_LOCK_HELD=0
approved_head_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
  fi
  cleanup_refs
}
trap approved_head_cleanup EXIT
trap 'exit 1' HUP INT TERM

case "$COMMAND" in
  record) record_approved_head "${4-}" || exit 1 ;;
  live) print_live_head || exit 1 ;;
  verify)
    status=0
    verify_approved_head "$4" "$5" "${6-}" || status=$?
    exit "$status"
    ;;
esac
