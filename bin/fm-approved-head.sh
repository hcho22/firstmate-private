#!/usr/bin/env bash
# Bind a captain's merge word to the pull request head commit firstmate showed
# the captain, so an attended merge lands only the commits that were approved.
#
# record <task-id> <pr-url>
#   Run when presenting a PR for the captain's merge word. Reads the pull
#   request's live head from the forge and stores it in the task metadata as
#     approved_head=<sha> <canonical-pr-url>
#   atomically under the meta lock, placed before the pr= line because
#   bin/fm-pr-lib.sh's metadata identity parse accepts only pr_head= after it;
#   bin/fm-pr-check.sh's rewrite keeps that order. The task must already record
#   pr= for the same URL (bin/fm-pr-check.sh), so a head is never bound to a PR
#   the task does not own. Recording again replaces the previous head, which is
#   how a re-asked approval moves forward. Prints the recorded head.
#
# verify <task-id> <pr-url> <live-head> <base-branch>
#   Called by bin/fm-pr-merge.sh on an attended merge, after its own live read
#   and before the forge merge command; away-authority merges never call it.
#   Exit 0 lets the merge proceed, exit 1 refuses with every reason on stderr,
#   exit 2 is a usage error. A recorded approved_head counts only when its URL is
#   the PR being merged. The verdict:
#   - approved head equals the live head: proceed.
#   - no approved head recorded for this PR: proceed only when the task meta
#     records yolo=on, because an autonomous yolo merge has no captain word to
#     bind; otherwise refuse and print the exact record command. A task
#     presented before this rule existed therefore refuses once: firstmate
#     re-presents the PR and records the head it shows.
#   - the heads differ: proceed only for a clean catch-up with the base branch,
#     otherwise refuse naming both heads and the commits between them.
#   A clean catch-up is defined strictly, and every condition must hold:
#   1. the approved head is an ancestor of the live head, so nothing was
#      rewritten (a rebase or force-push refuses);
#   2. every commit between them that is not on the current base branch is a
#      two-parent merge whose tree is exactly the conflict-free tree
#      `git merge-tree --write-tree` computes from its parents, so a merge that
#      needed hand-resolved conflicts, or carries any edit of its own, refuses,
#      as does any ordinary commit added on the PR branch;
#   3. the PR's own changes relative to its base are the same at both heads:
#      the zero-context diff from the merge base with the base branch to each
#      head has the same `git patch-id --stable`, where each head has exactly
#      one merge base.
#   The commits are read from the task worktree (worktree= in the meta) after
#   fetching the PR head ref (refs/pull/<n>/head on GitHub and Forgejo,
#   refs/merge-requests/<n>/head on GitLab) and the base branch from origin into
#   private refs/fm-approved-head/<task-id>/ refs, which are deleted on exit,
#   the same private-ref fetch bin/fm-review-diff.sh uses. The fetched head must
#   equal the live head the merge verified. Anything that cannot be read or
#   proven refuses rather than counting as clean, because a refused merge is
#   only asked again while a wrong pass lands commits nobody approved.
#
# Usage: fm-approved-head.sh record <task-id> <pr-url>
#        fm-approved-head.sh verify <task-id> <pr-url> <live-head> <base-branch>
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
  echo "usage: fm-approved-head.sh record <task-id> <pr-url>" >&2
  echo "       fm-approved-head.sh verify <task-id> <pr-url> <live-head> <base-branch>" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  record) [ "$#" -eq 3 ] || { usage; exit 2; } ;;
  verify) [ "$#" -eq 5 ] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac
COMMAND=$1
ID=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$3"; then
  echo "error: invalid approved-head request" >&2
  exit 2
fi
URL=$FM_PR_URL
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

meta_value() {  # <key>
  grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true
}

RECORD_CMD="$SCRIPT_DIR/fm-approved-head.sh record $ID $URL"

# The live head as the forge reports it now, for the record subcommand.
read_live_head() {
  local head='' json
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 || { echo "error: reading a GitHub pull request head requires gh on PATH" >&2; return 1; }
      head=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) || head=
      ;;
    gitlab)
      if ! command -v glab >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "error: reading a GitLab merge request head requires glab and jq on PATH" >&2
        return 1
      fi
      if json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json 2>/dev/null); then
        head=$(printf '%s' "$json" | jq -r 'if type == "object" and (.sha | type) == "string" then .sha else empty end' 2>/dev/null) || head=
      fi
      ;;
    forgejo)
      if fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
        head=$FM_PR_RECORD_HEAD
      fi
      ;;
    *)
      echo "error: firstmate does not merge a $FM_PR_PROVIDER change, so it records no approved head for one" >&2
      return 1
      ;;
  esac
  if ! fm_pr_head_valid "$head"; then
    echo "error: could not read the live head of $URL" >&2
    return 1
  fi
  printf '%s\n' "$head"
}

record_approved_head() {
  local head line state_device inserted=0
  if [ "$(meta_value pr)" != "$URL" ]; then
    echo "error: task $ID does not record pr=$URL; register the PR with bin/fm-pr-check.sh before recording the head shown to the captain" >&2
    return 1
  fi
  head=$(read_live_head) || return 1

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
    printf 'error: refusing to merge %s: task %s records a malformed approved_head; record the head shown to the captain again with: %s\n' \
      "$URL" "$ID" "$RECORD_CMD" >&2
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

# The single merge base of <rev> with the fetched base branch; none or several
# fail, because a patch-id compare against an arbitrary pick proves nothing.
single_merge_base() {  # <rev>
  local bases
  bases=$(git_wt merge-base --all "$FETCH_BASE_REF" "$1" 2>/dev/null) || return 1
  [ -n "$bases" ] && [ "$(printf '%s\n' "$bases" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s\n' "$bases"
}

# The patch id of the PR's own zero-context change at <rev>. Context lines are
# left out so a clean catch-up whose base edits sit beside the PR's hunks
# still compares equal; condition 2 is what rules out a hand-moved hunk.
own_change_patch_id() {  # <rev>
  local base diff
  base=$(single_merge_base "$1") || return 1
  diff=$(git_wt diff --no-ext-diff --no-textconv --no-renames --full-index --binary \
    --src-prefix=a/ --dst-prefix=b/ -U0 "$base" "$1" --) || return 1
  printf '%s\n' "$diff" | git_wt patch-id --stable | cut -d' ' -f1
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
  printf 'error: present the pull request to the captain again at head %s and, on a fresh merge word, record it with: %s\n' \
    "$2" "$RECORD_CMD" >&2
}

verify_approved_head() {
  local live=$1 base_branch=$2 pr_ref fetched approved reasons='' unclean own_count all_count approved_pid live_pid line
  if ! fm_pr_head_valid "$live"; then
    echo "error: invalid approved-head request" >&2
    return 2
  fi
  read_approved_head || return 1
  approved=$APPROVED_HEAD
  if [ -z "$approved" ]; then
    if [ "$(meta_value yolo)" = on ]; then
      printf 'notice: no captain-approved head is recorded for %s; merging under the task'"'"'s yolo posture\n' "$URL" >&2
      return 0
    fi
    printf 'error: refusing to merge %s: no captain-approved head is recorded for task %s\n' "$URL" "$ID" >&2
    printf 'error: record the head the captain was shown with: %s\n' "$RECORD_CMD" >&2
    printf 'error: that records the live head %s; if the captain was not shown that head, present the pull request again first\n' "$live" >&2
    return 1
  fi
  if [ "$approved" = "$live" ]; then
    printf 'verified: live head %s of %s is the captain-approved head\n' "$live" "$URL" >&2
    return 0
  fi

  WT=$(meta_value worktree)
  case "$FM_PR_PROVIDER" in
    github|forgejo) pr_ref="refs/pull/$FM_PR_NUMBER/head" ;;
    gitlab) pr_ref="refs/merge-requests/$FM_PR_NUMBER/head" ;;
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
  fi
  approved_pid=$(own_change_patch_id "$approved") || approved_pid='unreadable'
  live_pid=$(own_change_patch_id "$live") || live_pid='unreadable'
  if [ "$approved_pid" = unreadable ] || [ "$live_pid" = unreadable ]; then
    reasons="$reasons  - the pull request's own changes relative to $base_branch could not be compared (no single merge base)
"
  elif [ "$approved_pid" != "$live_pid" ]; then
    reasons="$reasons  - the pull request's own changes relative to $base_branch differ from those at the approved head
"
  fi
  if [ -n "$reasons" ]; then
    reasons="$reasons  - $all_count commits lie between the heads, $own_count of them not on $base_branch
"
    refuse_changed "$approved" "$live" "$reasons"
    return 1
  fi
  printf 'verified: live head %s of %s adds only a clean catch-up with %s to the captain-approved head %s (%s commits from %s, %s clean merge commits)\n' \
    "$live" "$URL" "$base_branch" "$approved" "$((all_count - own_count))" "$base_branch" "$own_count" >&2
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
  record) record_approved_head || exit 1 ;;
  verify)
    status=0
    verify_approved_head "$4" "$5" || status=$?
    exit "$status"
    ;;
esac
