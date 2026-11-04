#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded; a Forgejo
# pull request is addressed through tea by the derived owner and repository
# plus a "tea login" resolved fresh from the parsed host on every run. A Gerrit
# change is refused outright: that adapter is read-only, and the refusal at the
# parse below owns why.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# On Forgejo the merge style defaults to the repository's own
# default_merge_style, read live, and a merge is refused when it cannot be read.
# A GitHub merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the pull request
# is open, not a draft, mergeable, free of conflicts, every unwaived check
# is green at the exact current head commit, where github_checks_not_green below
# owns what makes a check green and judges each one by its current run, and
# every unwaived check the forge requires for the base branch has reported at
# that head. When mergeable is the only failing condition and reads UNKNOWN,
# meaning GitHub has not finished recomputing it, the caller re-reads and
# re-checks every condition after a short bounded wait instead of refusing;
# once that bound is spent it reports mergeability still pending rather than
# unmergeable, with the same nonzero exit as any other refusal.
# A required check that never reported is absent from the checks
# list rather than red, so github_read_required_contexts below reads the
# required set from classic branch protection and active rulesets. Check-run
# requirements retain their producer app binding: a same-named check run from another app cannot
# satisfy them, and a duplicate name-only entry cannot weaken that binding.
# Unbound requirements match by name. A bound requirement reported as a check
# run also needs a matching producer in the check-runs read at the verified
# head, while one reported as a commit status matches by name, because the
# status carries no app id to compare. Status-creator app binding is not verified
# here, so an attended --attended-override -- --admin merge can bypass that
# protection without a missing-check waiver when a same-named status reported.
# An unreadable producer read still refuses.
# Successfully read requirements remain checked even if another
# source fails, so known missing checks and all read errors are reported together.
# github_branch_rules_unavailable_on_plan owns the narrow plan-unavailable
# exception; every other unreadable required source refuses.
# Every failing condition is reported, not just the first.
# The verified head is then passed to gh as
# --match-head-commit, so a push that lands between that read and the merge
# fails the merge instead of landing commits nothing verified. Reading that
# state needs gh and jq, and either one absent stops the merge before any
# state is recorded. An attended --allow-red <check-name> may be passed once,
# with the name as a separate argument; it waives only checks with that exact
# name, still requires every other check green, and still binds the head. Its
# twin, an attended --allow-missing <check-name>, follows the same rules for one
# required check that has not reported: it waives only that exact name, still
# requires every other required check to have reported and every check to be
# green unless separately waived by --allow-red. It matches the required
# context name even for an app-bound requirement, and never waives an unreadable
# required source or producer read. Both are
# refused while the away-posture record exists, and neither
# applies on GitLab, where a merge already requires the head pipeline to have
# succeeded, or on Forgejo, where a merge already requires the head's combined
# commit status to have succeeded. After gh returns success, GitHub's live
# state is read back and
# accepted only when the pull request is merged or in the merge queue. gh's
# GraphQL API supplies that queue-aware read; when that read fails, gh-axi's
# own view still proves a landed merge, and every outcome it cannot prove
# refuses, reporting the failed gh read and naming both failed reads when the
# gh-axi view could not prove the outcome either.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, an attended refusal names the queue's configured merge
# method and exact --attended-override -- --auto --<method> retry flags. While
# the away-posture record exists, asynchronous merge requests are refused and
# queue retry flags are not offered because they would outlive away authority.
# A merge bound to a captain-approved head (below) is offered none either.
# An attended caller that already passed the configured method with --auto is
# told instead that the accepted request has not entered the queue and its queue
# state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. An attended --allow-no-pipeline, for a repository that deliberately
# runs no merge request pipeline, waives only the pipeline condition and only
# when GitLab reports head_pipeline as present and null: a failed, running,
# canceled, or stale pipeline still refuses, every other condition still
# holds, and a project that requires a pipeline to succeed still refuses
# through detailed_merge_status. It is refused while the away-posture record
# exists and on any forge other than GitLab. The verified head is then passed
# to glab as --sha, so a push that lands between that read and the merge fails
# the merge instead of landing commits nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# A Forgejo merge is refused unless every pre-merge condition holds, each read
# live at merge time: the pull request is open, not a draft, mergeable is
# true, and the combined commit status at the exact current head, read across
# every status page, is success (an unconfigured status, reported as "none",
# refuses rather than being treated as nothing to check, the same reading
# GitLab's null head_pipeline gets above). Every
# failing condition is reported, not just the first. tea exposes no head-
# binding flag on its own merge subcommand, so the verified head is instead
# passed as head_commit_id to a direct call against Forgejo/Gitea's REST API
# (through "tea api"), which rejects a mismatched value with "head out of
# date" - verified against a real instance, along with every claim below about
# tea's and the API's exact behavior. Also unlike gh and glab, that API call
# reports an HTTP-level failure with exit status 0, so the merge is never
# judged by its own exit status: only a follow-up read confirming merged=true
# counts as landed. tea addresses a repository by owner/repository slug only;
# the host comes from a named "tea login" rather than the URL the way gh and
# glab take one, so the login registered for the parsed host is re-resolved
# fresh at merge time (bin/fm-pr-check.sh already required one at arm time,
# but a login can be renamed or removed afterwards). Reading and merging both
# need tea and jq, and either one absent stops the merge before any state is
# recorded. Forgejo has no merge-queue or scheduled-merge concept, so unlike
# GitHub and GitLab there is no away-mode async/queued case to detect: every
# accepted Forgejo merge here is immediate, and any caller-passed extra
# argument beyond a merge method is refused rather than silently dropped,
# because there is no established translation from a gh/glab-style flag into
# a Forgejo API field yet.
#
# An attended merge also proceeds only at the head the captain approved, or at
# a head whose only additions are a clean catch-up with the base branch, before
# any forge's merge command; bin/fm-approved-head.sh owns that record, the
# clean catch-up definition, and the rule for a task with no recorded head.
# An away-authority merge is bound the same way when a head is recorded for
# this pull request, because that record is a captain word the posture does not
# widen, and is bound to no head only when none is recorded; captain away words
# that explicitly cover a later head widen the binding only by the away session
# recording that head first. In a secondmate home a refusal that needs the
# captain again publishes the child's PR-ready line with the live head on the
# parent channel, so the parent can present that head; one that only asks for a
# retry publishes nothing.
# A merge bound to a head must also land it immediately, because a forge asked
# to merge later lands whatever the head is by then, without the captain being
# asked again. A GitHub or GitLab auto-merge, requested here or already set on
# a GitLab merge request, is refused with a pointer to merge once the checks
# are green instead, and GitLab is passed a final --auto-merge=false. A GitHub
# pull request whose isMergeQueueEnabled or base-branch rules do not prove the
# absence of a merge queue is refused too, naming an unreadable answer apart
# from a queue, and one that enters a queue anyway is refused rather than
# reported as queued, so a base branch that requires a merge queue takes no
# merge bound to a head; that needs a later design. A yolo merge with no
# recorded head is bound to none and keeps the asynchronous paths above.
#
# Before either forge merge, the task's existing per-task control lock
# serializes the captain-hold check through the forge command. A still-held or
# unreadable row refuses before that command, so a captain approval must be
# recorded as an `answer --release` before this entrypoint is invoked. While
# an away record exists (a quiet-mode record is a present captain, so its
# merges stay attended: bin/fm-afk-contract.sh mode) any green merge may
# proceed under away authority, still bound to a head recorded for it (above):
# the record's presence is the whole mechanical fact, and which merge the
# captain's away words meant is the supervision session's reading
# (bin/fm-branch-prompt.sh "Postures"). An unreadable record refuses rather
# than being skipped, neither posture releases a captain hold, and away
# authority lapses when the record is archived.
# The authority read and synchronous forge command share the away record's
# cross-subsystem lock, which bin/fm-afk-contract.sh owns, closing the common
# live-owner TOCTOU; failure to take it refuses before the forge call. Async and
# queued paths are refused while away. Two confused-agent-grade limitations are
# accepted rather than hidden: queue or base changes after GitHub's preflight can
# still enqueue, and killing this shell can orphan a forge child after stale-lock
# recovery. docs/architecture.md owns those away-merge limits, while
# docs/captain-hold-lifecycle.md owns the separate merge-to-cleanup residual.
# A failed forge command releases the lock after it returns. A successful one
# retains the lock until the accepted merge authority is persisted against the
# still-matching task metadata.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha or --match-head-commit because the head comes only from the
# live read. An existing task-meta pr= must equal the requested canonical URL,
# unless that bound PR has already merged - proven by its recorded merge
# notification - in which case the task's next PR is accepted so several PRs
# from one task can each merge in turn; while the bound PR is still unmerged a
# different URL is refused. Auto-merge (--auto), a protection bypass
# (--admin), and branch
# deletion (--delete-branch, -d and short-flag clusters, and GitLab's
# --remove-source-branch) are refused by default; --attended-override, parsed
# before the optional -- separator, re-enables those forge flags for an
# explicit captain instruction, except auto-merge on a merge bound to a
# captain-approved head (above), and never skips the live green check, the
# away-record read, or a captain hold.
#
# --low-risk is the merge path for the low-risk merge tier, the standing
# posture under which firstmate merges without the captain's word or yolo
# (AGENTS.md section 7); bin/fm-merge-tier-lib.sh owns the declaration and
# the per-path verdict. The task's project declaration is read from the home's
# config/merge-tiers before anything is recorded, and a project with no
# low-risk rule, or a declaration that cannot be read, refuses. After the live
# green check verifies a head, the pull request's changed files are read from
# GitHub's REST file listing, every page, between two reads of the pull
# request that must both report that verified head and one changed-file count,
# and the listing must hold exactly that many entries. The merge stays bound to
# that head, so the paths judged are the paths merged. Every listed path, and
# a renamed file's previous path, must be low risk. A listing that cannot be
# read in full refuses: a failed read, a moved head, more files than GitHub
# lists (3000), a short listing, a path carrying a control character, or no
# changed file at all. Any always-ask or unmatched path refuses too, and the
# refusal names it. Every tier refusal exits 4, apart from a red or
# unmergeable pull request's 1, because its answer is the captain's merge
# call. The changed-file read is GitHub-only, so a GitLab or Forgejo request
# refuses the same way. --low-risk takes none of the attended waivers
# (--attended-override, --allow-red, --allow-missing, --allow-no-pipeline),
# which exist only for an explicit captain instruction, and every other gate
# above still applies, the captain-hold check and away authority included.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--attended-override] [--allow-red <check-name>] [--allow-missing <check-name>] [--allow-no-pipeline] [--low-risk] [-- <extra forge merge args>]
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-merge-tier-lib.sh
. "$SCRIPT_DIR/fm-merge-tier-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
# Firstmate never submits a Gerrit change, even though gerrit-axi can, so the
# refusal is stated rather than left as a silently absent provider branch.
# Submitting a Gerrit change means first recording a Code-Review+2, which is a
# positive attributed claim that a named human approved the change, read by
# colleagues and by any audit of the repository. Firstmate must not manufacture
# one. The server permitting self-approval is what makes this a policy boundary
# rather than a capability limit, so it is enforced here rather than assumed.
if [ "$PROVIDER" = gerrit ]; then
  echo "error: firstmate does not submit a Gerrit change: submitting requires an attributed human approval it must not manufacture, so a human submits the change on the server" >&2
  exit 2
fi
shift 2
ATTENDED_OVERRIDE=false
ALLOW_NO_PIPELINE=false
LOW_RISK=false
ALLOW_RED=()
ALLOW_MISSING=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attended-override)
      ATTENDED_OVERRIDE=true
      shift
      ;;
    --attended-override=*)
      echo "error: --attended-override takes no value" >&2
      exit 2
      ;;
    --allow-red)
      [ -n "${2:-}" ] || { echo "error: --allow-red requires a check name" >&2; exit 2; }
      [ "${#ALLOW_RED[@]}" -eq 0 ] || { echo "error: --allow-red may be specified only once" >&2; exit 2; }
      ALLOW_RED+=("$2")
      shift 2
      ;;
    --allow-red=*)
      echo "error: --allow-red requires a separate check name argument" >&2
      exit 2
      ;;
    --allow-missing)
      [ -n "${2:-}" ] || { echo "error: --allow-missing requires a check name" >&2; exit 2; }
      [ "${#ALLOW_MISSING[@]}" -eq 0 ] || { echo "error: --allow-missing may be specified only once" >&2; exit 2; }
      ALLOW_MISSING+=("$2")
      shift 2
      ;;
    --allow-missing=*)
      echo "error: --allow-missing requires a separate check name argument" >&2
      exit 2
      ;;
    --allow-no-pipeline)
      ALLOW_NO_PIPELINE=true
      shift
      ;;
    --allow-no-pipeline=*)
      echo "error: --allow-no-pipeline takes no value" >&2
      exit 2
      ;;
    --low-risk)
      LOW_RISK=true
      shift
      ;;
    --low-risk=*)
      echo "error: --low-risk takes no value" >&2
      exit 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done
# --allow-red names one check run to waive, which only GitHub's per-check
# reading can match. GitLab and Forgejo each collapse their checks into a
# single head verdict - a head pipeline status and a combined commit status -
# so there is no per-check name to waive there; GitLab's only waiver is the
# whole-pipeline absence --allow-no-pipeline covers. Refuse the combination
# rather than accept a flag that would be silently dropped into a refusal the
# caller cannot explain.
if [ "${#ALLOW_RED[@]}" -gt 0 ]; then
  case "$PROVIDER" in
    gitlab)
      echo "error: --allow-red does not apply to GitLab, where a merge already requires the head pipeline to have succeeded; --allow-no-pipeline waives only a merge request with no head pipeline at all" >&2
      exit 2
      ;;
    forgejo)
      echo "error: --allow-red does not apply to Forgejo, where a merge already requires the head's combined commit status to have succeeded" >&2
      exit 2
      ;;
  esac
fi
# --allow-no-pipeline waives only GitLab's own reading of a merge request that
# has no head pipeline at all. GitHub's per-check waivers and Forgejo's
# combined status have no such state to waive, so it is refused there too.
if [ "$ALLOW_NO_PIPELINE" = true ] && [ "$PROVIDER" != gitlab ]; then
  echo "error: --allow-no-pipeline applies only to GitLab, where it waives a merge request that has no head pipeline at all" >&2
  exit 2
fi
if [ "${#ALLOW_MISSING[@]}" -gt 0 ]; then
  case "$PROVIDER" in
    gitlab)
      echo "error: --allow-missing does not apply to GitLab, where a merge already requires the head pipeline to have succeeded; --allow-no-pipeline waives only a merge request with no head pipeline at all" >&2
      exit 2
      ;;
    forgejo)
      echo "error: --allow-missing does not apply to Forgejo, where a merge already requires the head's combined commit status to have succeeded" >&2
      exit 2
      ;;
  esac
fi
# A low-risk merge runs on standing posture, not on a captain instruction, so
# it takes none of the waivers that exist only for one.
if [ "$LOW_RISK" = true ]; then
  if [ "$ATTENDED_OVERRIDE" = true ] || [ "${#ALLOW_RED[@]}" -gt 0 ] \
    || [ "${#ALLOW_MISSING[@]}" -gt 0 ] || [ "$ALLOW_NO_PIPELINE" = true ]; then
    echo "error: --low-risk takes no attended waiver: --attended-override, --allow-red, --allow-missing, and --allow-no-pipeline need an explicit captain instruction, and a merge on one is not a low-risk merge" >&2
    exit 2
  fi
  if [ "$PROVIDER" != github ]; then
    printf 'error: refusing a low-risk merge of %s: the low-risk tier reads changed files only from GitHub, so this merge waits for the captain\n' "$URL" >&2
    exit 4
  fi
fi

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*|--match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_protected_forge_args() {
  local arg
  [ "$ATTENDED_OVERRIDE" = true ] && return 0
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--admin|--admin=*|--delete-branch|--delete-branch=*|--remove-source-branch|--remove-source-branch=*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster. -d is gh's
      # --delete-branch, and -yd carries it the same way -yR carries --repo.
      -*d*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
reject_head_overrides "$@" || exit 1
reject_protected_forge_args "$@" || exit 1

FM_PR_GITHUB_AUTO_REQUESTED=false
if [ "$PROVIDER" = github ] && caller_requested_auto_merge "$@"; then
  FM_PR_GITHUB_AUTO_REQUESTED=true
fi
FM_PR_GITLAB_ASYNC_REQUESTED=false
if [ "$PROVIDER" = gitlab ]; then
  for arg in "$@"; do
    case "$arg" in
      --auto-merge|--when-pipeline-succeeds) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
      --auto-merge=*|--when-pipeline-succeeds=*)
        case "${arg#*=}" in
          [tT]|[tT][rR][uU][eE]|1) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
          [fF]|[fF][aA][lL][sS][eE]|0) FM_PR_GITLAB_ASYNC_REQUESTED=false ;;
        esac
        ;;
    esac
  done
fi
FM_PR_AWAY_POSTURE=false

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Role partition: merging is MAIN-owned while attended; the Pi supervision
# branch reports the green PR and never merges (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). While the away-posture record exists
# main is parked and this one action relocates to the branch, which then meets
# exactly the same gates below as main would: green at its live head,
# synchronous, under the record lock. This precedes
# reading the task record, because the wrong actor is refused for its role
# whatever that record says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated

if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

# The low-risk declaration is read once, before anything is recorded, so an
# undeclared or unreadable tier refuses with no side effect. The project is
# named by its recorded clone's basename, as the registry names it.
TIER_PROJECT=
if [ "$LOW_RISK" = true ]; then
  TIER_PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  TIER_PROJECT=${TIER_PROJECT%/}
  TIER_PROJECT=${TIER_PROJECT##*/}
  tier_status=0
  fm_merge_tier_load "$CONFIG" "$TIER_PROJECT" || tier_status=$?
  case "$tier_status" in
    0) ;;
    1)
      printf 'error: refusing a low-risk merge of %s: %s, so this merge waits for the captain\n' \
        "$URL" "$FM_MERGE_TIER_ERROR" >&2
      exit 4
      ;;
    *)
      printf 'error: refusing a low-risk merge of %s: %s; until it is corrected every low-risk merge in this home waits for the captain\n' \
        "$URL" "$FM_MERGE_TIER_ERROR" >&2
      exit 4
      ;;
  esac
fi

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  fm_afk_contract_lock_release || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi
GITHUB_MISSING=
if [ "$PROVIDER" = github ]; then
  command -v gh >/dev/null 2>&1 || GITHUB_MISSING="gh"
  if ! command -v jq >/dev/null 2>&1; then
    GITHUB_MISSING="${GITHUB_MISSING:+$GITHUB_MISSING and }jq"
  fi
  if [ -n "$GITHUB_MISSING" ]; then
    echo "error: merging a GitHub pull request requires $GITHUB_MISSING on PATH" >&2
    exit 1
  fi
fi
# tea addresses a repo by slug only; the host comes from a named "tea login"
# rather than the URL, so the login registered for this exact host is
# resolved here too (bin/fm-pr-check.sh already refused arming without one,
# but a login can be removed or renamed after arming, so this is re-derived
# fresh rather than trusted from that earlier check).
FORGEJO_MISSING=
FORGEJO_LOGIN=
if [ "$PROVIDER" = forgejo ]; then
  command -v tea >/dev/null 2>&1 || FORGEJO_MISSING="tea"
  if ! command -v jq >/dev/null 2>&1; then
    FORGEJO_MISSING="${FORGEJO_MISSING:+$FORGEJO_MISSING and }jq"
  fi
  if [ -n "$FORGEJO_MISSING" ]; then
    echo "error: merging a Forgejo pull request requires $FORGEJO_MISSING on PATH" >&2
    exit 1
  fi
  FORGEJO_LOGIN=$(fm_pr_forgejo_login "$PR_HOST") || {
    echo "error: merging a Forgejo pull request at $PR_HOST requires exactly one 'tea login' registered for that host (see 'tea login list')" >&2
    exit 1
  }
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ] || [ "$PROVIDER" = forgejo ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
FM_PR_MERGE_BASE=
FM_PR_GITLAB_ASYNC_CONFIGURED=false
gitlab_verify_mergeable() {
  local json fields line pipeline_waived
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' base='' pipeline_sha='' pipeline_status='' pipeline_absent='' async_configured=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "base=" + ((.target_branch // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring),
        "pipeline_absent=" + (if has("head_pipeline") and .head_pipeline == null then "true" else "false" end),
        "async_configured=" + (if .merge_when_pipeline_succeeds == true or (.merge_after != null) then "true" else "false" end)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      pipeline_absent=*) pipeline_absent=${line#pipeline_absent=} ;;
      async_configured=*) async_configured=${line#async_configured=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 10 ] || [ "$total" -ne 10 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  # The waiver covers only a head_pipeline GitLab reports as null; a failed,
  # running, canceled, or stale pipeline is a verdict, not an absence of one.
  pipeline_waived=false
  if [ "$ALLOW_NO_PIPELINE" = true ] && [ "$pipeline_absent" = true ]; then
    pipeline_waived=true
  else
    [ "$pipeline_status" = success ] \
      || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
    [ "$pipeline_sha" = "$live_head" ] \
      || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  if [ "$pipeline_waived" = true ]; then
    printf 'verified: %s is open and mergeable at head %s, with no head pipeline, waived by --allow-no-pipeline\n' \
      "$URL" "$live_head" >&2
  else
    printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
      "$URL" "$live_head" >&2
  fi
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_MERGE_BASE=$base
  FM_PR_GITLAB_ASYNC_CONFIGURED=$async_configured
}

# Pre-merge conditions for a Forgejo pull request, read from one live view of
# it. tea's single-PR view ignores field selection entirely (verified against
# a real instance), so the raw API is read directly through "tea api" instead
# of any tea subcommand, exactly like glab's JSON view above but through
# Forgejo/Gitea's REST API. Sets FM_PR_MERGE_HEAD to the verified head on
# success and returns non-zero after reporting every condition that failed.
#
# Forgejo has no merge-queue or scheduled-merge concept to detect, so unlike
# GitHub and GitLab this never sets an async/queued signal: every accepted
# Forgejo merge here is immediate. Shares FM_PR_MERGE_HEAD, declared above.
forgejo_verify_mergeable() {
  local pr_json status_json fields line
  local total=0 named=0 refusals=''
  local state='' mergeable='' draft='' live_head='' base='' ci_state='' page_state='' page_count='' page=1

  if ! pr_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
      "/repos/{owner}/{repo}/pulls/$PR_NUMBER" 2>/dev/null) || [ -z "$pr_json" ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$pr_json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + (.mergeable | tostring),
        "draft=" + (.draft | tostring),
        "head=" + ((.head.sha // "") | tostring),
        "base=" + ((.base.ref // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      draft=*) draft=${line#draft=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 5 ] || [ "$total" -ne 5 ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the Forgejo pull request head commit before merging" >&2
    return 1
  fi
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  # An absent combined status (no statuses on any page, as a repo with no
  # configured Actions reports) is a real "none" here rather than nothing to
  # check, the same reading GitLab's null head_pipeline gets above. The
  # endpoint computes its combined state from one page of the latest status
  # per context, so every page is read until an empty one and the head is
  # green only when each non-empty page is; the first page that is not
  # success, or that cannot be read, decides the refusal.
  ci_state=none
  while :; do
    if ! status_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
        "/repos/{owner}/{repo}/commits/$live_head/status?limit=50&page=$page" 2>/dev/null) \
      || ! fields=$(printf '%s' "$status_json" | jq -r '
          if type == "object" and ((.statuses // []) | type) == "array" then
            "count=" + ((.statuses // []) | length | tostring),
            "state=" + ((.state // "") | tostring)
          else
            error("status payload is not a combined status")
          end' 2>/dev/null); then
      ci_state=unreadable
      break
    fi
    page_count='' page_state=''
    while IFS= read -r line; do
      case "$line" in
        count=*) page_count=${line#count=} ;;
        state=*) page_state=${line#state=} ;;
      esac
    done <<FIELDS
$fields
FIELDS
    [ "$page_count" != 0 ] || break
    if [ "$page_state" != success ]; then
      ci_state=${page_state:-unreadable}
      break
    fi
    ci_state=success
    page=$((page + 1))
    # A server that ignores the page parameter would repeat a non-empty page
    # forever, so an implausible page count is unreadable rather than green.
    if [ "$page" -gt 100 ]; then
      ci_state=unreadable
      break
    fi
  done

  [ "$state" = open ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$mergeable" = true ] \
    || refusals="$refusals  - mergeable is \"${mergeable:-unreadable}\", not true
"
  # Only a positive draft reading refuses: an instance too old to report the
  # field still refuses a work-in-progress merge server side.
  [ "$draft" != true ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$ci_state" = success ] \
    || refusals="$refusals  - the combined commit status is \"$ci_state\", not success
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful combined status at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_MERGE_BASE=$base
}

# The caller's own extra arguments may only name a merge method, in the same
# forms caller_merge_method reads. There is no translation from a gh/glab-style
# flag such as --auto, --admin, or --delete-branch into a Forgejo API field
# yet (reject_protected_forge_args above already forbids those exact spellings
# outright), so anything else is refused rather than silently dropped.
forgejo_reject_unsupported_args() {
  local arg pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      pending=false
      continue
    fi
    case "$arg" in
      --squash|--merge|--rebase) ;;
      --method) pending=true ;;
      --method=*) ;;
      *)
        echo "error: extra merge arguments are not yet supported for Forgejo merges" >&2
        return 1
        ;;
    esac
  done
}

# The merge style a Forgejo merge uses when the caller names none: the
# repository's own default_merge_style, read live through the same tea login,
# so a repository that allows only squash or rebase merges is not sent a merge
# commit it refuses. An unreadable or unrecognized value is refused rather than
# replaced by a style chosen here.
forgejo_default_merge_style() {
  local repo_json style
  repo_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
    "/repos/{owner}/{repo}" 2>/dev/null) || repo_json=
  style=$(printf '%s' "$repo_json" | jq -r '
    if type == "object" and (.default_merge_style | type) == "string"
    then .default_merge_style else "" end' 2>/dev/null) || style=
  case "$style" in
    merge|rebase|rebase-merge|squash|fast-forward-only) printf '%s' "$style" ;;
    *)
      echo "error: refusing to merge $URL: the repository's default merge style could not be read; name one with --merge, --rebase, --squash, or --method <style>" >&2
      return 1
      ;;
  esac
}

# Every GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
github_checks_not_green() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r --argjson required "$required" --argjson producers "$producers" '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}

# Pre-merge conditions from a live PR view, base requirements, and head producers.
# Sets FM_PR_MERGE_HEAD to the verified head on success. Returns 3, rather than
# the usual 1, when mergeable=UNKNOWN is the only failing condition, so the
# caller can retry a still-computing mergeability read instead of refusing.
github_verify_mergeable() {
  local json fields line red name covered missing unreported producers runs
  local total=0 named=0 refusals='' mergeable_refusal=''
  local state='' draft='' mergeable='' merge_state='' live_head='' base=''

  if ! json=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + ((.mergeable // "") | tostring),
        "merge_state=" + ((.mergeStateStatus // "") | tostring),
        "head=" + ((.headRefOid // "") | tostring),
        "base=" + ((.baseRefName // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      merge_state=*) merge_state=${line#merge_state=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 5 ] || [ "$total" -ne 5 ] || [ -z "$base" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  draft=$(fm_pr_json_draft_state "$json")
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitHub pull request head commit before merging" >&2
    return 1
  fi
  if ! red=$(github_checks_not_green "$json"); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  case "$state" in
    [oO][pP][eE][nN]) ;;
    *)
      refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
      ;;
  esac
  [ "$draft" = false ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$mergeable" = MERGEABLE ] \
    || mergeable_refusal="  - mergeable is \"${mergeable:-unreadable}\", not MERGEABLE
"
  [ "$merge_state" != DIRTY ] \
    || refusals="$refusals  - mergeStateStatus is DIRTY (conflicts)
"

  uncovered=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    covered=0
    if [ "${#ALLOW_RED[@]}" -gt 0 ]; then
      for check in "${ALLOW_RED[@]}"; do
        [ "$check" = "$name" ] && covered=1
      done
    fi
    [ "$covered" -eq 1 ] || {
      refusals="$refusals  - check '$name' is not green
"
      uncovered="${uncovered:+$uncovered, }$name"
    }
  done <<EOF
$red
EOF

  unreported=''
  if ! github_read_required_contexts "$base"; then
    while IFS= read -r line; do
      refusals="$refusals  - $line, so a required check that has not reported cannot be ruled out
"
    done <<EOF
$FM_PR_GITHUB_REQUIRED_ERROR
EOF
  fi
  producers='[]'
  if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$live_head/check-runs" 2>/dev/null) \
      || [ -z "$runs" ] \
      || ! producers=$(printf '%s' "$runs" | jq -sc --arg head "$live_head" '
        [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
          | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
            then . else error("invalid check producer") end ]' 2>/dev/null); then
      producers='[]'
      refusals="$refusals  - required check producers at head $live_head could not be read
"
    fi
  fi
  if ! missing=$(github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" "$producers"); then
    refusals="$refusals  - the GitHub pull request check rollup could not be read
"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ "${#ALLOW_MISSING[@]}" -gt 0 ] && [ "${ALLOW_MISSING[0]}" = "$name" ] && continue
      refusals="$refusals  - required check '$name' has not reported at head $live_head
"
      unreported="${unreported:+$unreported, }$name"
    done <<EOF
$missing
EOF
  fi

  if [ -n "$mergeable_refusal" ]; then
    if [ -z "$refusals" ] && [ "$mergeable" = UNKNOWN ]; then
      return 3
    fi
    refusals="$refusals$mergeable_refusal"
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    [ -z "$uncovered" ] || printf 'error: these checks are not green: %s\n' "$uncovered" >&2
    [ -z "$unreported" ] || printf 'error: these required checks have not reported: %s\n' "$unreported" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with every unwaived required check reported and every unwaived check green at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_MERGE_BASE=$base
  FM_PR_GITHUB_BASE=$base
}

# GitHub's REST file listing returns at most this many files for one pull
# request, so a larger change cannot be read in full.
FM_PR_GITHUB_FILES_MAX=3000

# "<head> <changed-file count>" from one live REST read of the pull request, or
# non-zero when either field is unreadable.
github_head_and_file_count() {
  local json
  json=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" 2>/dev/null) && [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r '
    if type == "object" and (.head.sha | type) == "string"
       and (.changed_files | type) == "number"
       and .changed_files >= 0 and (.changed_files | floor) == .changed_files
    then "\(.head.sha) \(.changed_files)"
    else error("pull request payload is unreadable") end' 2>/dev/null
}

# Every path the pull request changes at the verified head, one per line, with
# a renamed file's previous path as well, in FM_PR_TIER_PATHS. Returns non-zero
# after naming why the listing could not be read in full. The listing is read
# between two reads of the pull request that must agree on the verified head
# and the changed-file count, and must hold exactly that many entries.
FM_PR_TIER_PATHS=
FM_PR_TIER_FILE_COUNT=0
github_read_changed_files() {
  local before after head count listing listed paths
  FM_PR_TIER_PATHS=
  FM_PR_TIER_FILE_COUNT=0
  if ! before=$(github_head_and_file_count) || [ -z "$before" ]; then
    echo "error: could not read the changed-file count of $URL" >&2
    return 1
  fi
  head=${before%% *}
  count=${before#* }
  if [ "$head" != "$FM_PR_MERGE_HEAD" ]; then
    echo "error: the head of $URL moved from $FM_PR_MERGE_HEAD to $head after it was verified" >&2
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    echo "error: GitHub reports no changed file for $URL" >&2
    return 1
  fi
  if [ "$count" -gt "$FM_PR_GITHUB_FILES_MAX" ]; then
    echo "error: $URL changes $count files, more than the $FM_PR_GITHUB_FILES_MAX GitHub lists" >&2
    return 1
  fi
  if ! listing=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/files?per_page=100" 2>/dev/null) \
    || [ -z "$listing" ] \
    || ! listed=$(printf '%s' "$listing" | jq -s '
      [ .[] | if type == "array" then .[] else error("not a page of files") end ] | length' 2>/dev/null); then
    echo "error: could not read the changed files of $URL" >&2
    return 1
  fi
  if [ "$listed" != "$count" ]; then
    echo "error: GitHub listed $listed of the $count files $URL changes" >&2
    return 1
  fi
  if ! paths=$(printf '%s' "$listing" | jq -rs '
      .[][]
      | if type == "object" then . else error("unreadable file entry") end
      | .filename, (.previous_filename // empty)
      | if type == "string" and length > 0
           and (explode | any(. < 32 or . == 127) | not)
        then . else error("unreadable path") end' 2>/dev/null) \
    || [ -z "$paths" ]; then
    echo "error: a changed path of $URL is missing or carries a control character" >&2
    return 1
  fi
  if ! after=$(github_head_and_file_count) || [ "$after" != "$before" ]; then
    echo "error: $URL changed while its files were being read" >&2
    return 1
  fi
  FM_PR_TIER_PATHS=$paths
  FM_PR_TIER_FILE_COUNT=$count
}

# The low-risk tier's merge gate: the changed files at the verified head must
# all be low risk for the declaration read before anything was recorded.
github_require_low_risk_tier() {
  if ! github_read_changed_files; then
    printf 'error: refusing a low-risk merge of %s: its changed files could not be read in full, so this merge waits for the captain\n' \
      "$URL" >&2
    return 1
  fi
  if fm_merge_tier_judge <<< "$FM_PR_TIER_PATHS"; then
    printf 'verified: all %s changed files of %s at head %s are in the low-risk tier for %s\n' \
      "$FM_PR_TIER_FILE_COUNT" "$URL" "$FM_PR_MERGE_HEAD" "$TIER_PROJECT" >&2
    return 0
  fi
  printf 'error: refusing a low-risk merge of %s: %s changed path(s) fall outside the low-risk tier for %s, so this merge waits for the captain\n' \
    "$URL" "$FM_MERGE_TIER_BLOCKED_COUNT" "$TIER_PROJECT" >&2
  printf '%s' "$FM_MERGE_TIER_BLOCKERS" >&2
  return 1
}

# Read one live GitHub pull request view after gh returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view; if that post-merge read becomes unavailable, gh-axi is the degradation
# path that can prove only a landed merge. gh remains a pre-merge prerequisite.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -f "owner=$PR_OWNER" -f "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
      return 0
    fi
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false api_err api_err_text
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-queue-rules.XXXXXX") || return 0
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>"$api_err"); then
    api_err_text=$(cat "$api_err" 2>/dev/null)
    rm -f "$api_err"
    # A repository that cannot have branch rules cannot have a merge_queue
    # rule either, so that specific refusal resolves to no queue rather than
    # the generic unreadable status.
    if github_branch_rules_unavailable_on_plan "$api_err_text"; then
      FM_PR_GITHUB_QUEUE_STATUS=none
    fi
    return 0
  fi
  rm -f "$api_err"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

# Whether gh would hand this merge to a merge queue instead of landing it now.
# gh enqueues a merge when the pull request reports isMergeQueueEnabled, which
# a queue required by classic branch protection sets as well as a ruleset's
# merge_queue rule, so an immediate merge is proven only when that field reads
# false and github_read_queue_method finds no merge_queue rule. Sets
# FM_PR_GITHUB_MERGE_QUEUE to absent, present, or unreadable; a queue either
# read shows is present even when the other read failed.
FM_PR_GITHUB_MERGE_QUEUE=unreadable
github_read_merge_queue() {
  local enabled
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  enabled=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){isMergeQueueEnabled}}}' \
    -f "owner=$PR_OWNER" -f "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest.isMergeQueueEnabled' 2>/dev/null) || enabled=
  github_read_queue_method
  case "$enabled:$FM_PR_GITHUB_QUEUE_STATUS" in
    true:* | *:single | *:conflicting | *:unrecognised) FM_PR_GITHUB_MERGE_QUEUE=present ;;
    false:none) FM_PR_GITHUB_MERGE_QUEUE=absent ;;
    *) FM_PR_GITHUB_MERGE_QUEUE=unreadable ;;
  esac
}

record_pr_metadata() {
  if ! FM_PR_CHECK_MERGE=1 "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

require_released_captain_hold() {
  local hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
  case "$hold_status" in
    0)
      echo "error: task $ID is still held for the captain; release it before merging" >&2
      return 1
      ;;
    1|3) return 0 ;;
    *)
      echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
      return 1
      ;;
  esac
}

# The captain's merge word covers the head it was given at, so a merge proceeds
# only where bin/fm-approved-head.sh vouches for the verified head, passing
# --away while the away record exists so a PR with no recorded head is bound to
# none. It runs once before the away-record lock, where its fetch need not hold
# that lock, and is called again after the final authority read under the lock,
# where it is a no-op for the head and posture it already passed and runs again
# only when the posture changed between the two reads. In a secondmate home a
# refusal that needs the captain again (exit 1, not a retryable exit 4)
# publishes the child's PR-ready line with the live head, which is what the
# parent presents to the captain again; bin/fm-pr-check.sh's merge-time
# registration publishes no ready line of its own. A merge the verify binds to
# a head sets FM_PR_HEAD_BOUND and must then be immediate. A --low-risk merge
# runs on standing posture rather than a captain word, so it is not bound to a
# head; its own tier gate binds the changed files it judged to the verified
# head.
FM_PR_APPROVED_HEAD_VERIFIED=
FM_PR_HEAD_BOUND=false
require_approved_head() {
  local verify_status=0 ready_rc=0 posture=()
  [ "$LOW_RISK" != true ] || return 0
  [ "$FM_PR_APPROVED_HEAD_VERIFIED" != "$FM_PR_MERGE_HEAD $FM_PR_AWAY_POSTURE" ] || return 0
  [ "$FM_PR_AWAY_POSTURE" != true ] || posture=(--away)
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-approved-head.sh" verify "$ID" "$URL" "$FM_PR_MERGE_HEAD" "$FM_PR_MERGE_BASE" \
    "${posture[@]+"${posture[@]}"}" || verify_status=$?
  if [ "$verify_status" -eq 1 ]; then
    fm_parent_channel_report "$FM_HOME" "$STATE" \
      "$(fm_parent_channel_pr_ready_line "$ID" "$URL" "$META" "$FM_PR_MERGE_HEAD")" || ready_rc=$?
    case "$ready_rc" in
      0|1) ;;
      *) printf 'actionable: the refused head %s of %s did not reach the parent channel (rc=%s)\n' \
        "$FM_PR_MERGE_HEAD" "$URL" "$ready_rc" >&2 ;;
    esac
  fi
  case "$verify_status" in
    0)
      FM_PR_HEAD_BOUND=true
      refuse_deferred_bound_merge || return 1
      ;;
    3) ;;
    *) return 1 ;;
  esac
  FM_PR_APPROVED_HEAD_VERIFIED="$FM_PR_MERGE_HEAD $FM_PR_AWAY_POSTURE"
}

# A forge asked to merge later lands whatever the head is by then, so a merge
# bound to the captain-approved head refuses every such request before the
# forge command. The GitHub queue read is github_read_merge_queue, shared with
# refuse_github_queue_while_away, and anything short of proving no queue refuses.
refuse_deferred_bound_merge() {
  case "$PROVIDER" in
    github)
      if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
        printf 'error: refusing to merge %s with --auto: the merge is bound to the captain-approved head, and auto-merge would land the pull request later with any push made by then; merge once the checks are green instead\n' \
          "$URL" >&2
        return 1
      fi
      github_read_merge_queue
      case "$FM_PR_GITHUB_MERGE_QUEUE" in
        absent) return 0 ;;
        present)
          printf 'error: refusing to merge %s: the merge is bound to the captain-approved head, but base branch %s requires a merge queue, and a queued merge would land with any push made by then; nothing was handed to the forge, and a base branch that requires a merge queue needs a later design\n' \
            "$URL" "$FM_PR_GITHUB_BASE" >&2
          ;;
        *)
          printf 'error: refusing to merge %s: the merge is bound to the captain-approved head, but whether base branch %s requires a merge queue could not be read, so an immediate merge is not proven; nothing was handed to the forge, and the merge can be retried once that state reads\n' \
            "$URL" "$FM_PR_GITHUB_BASE" >&2
          ;;
      esac
      return 1
      ;;
    gitlab)
      [ "$FM_PR_GITLAB_ASYNC_REQUESTED" = true ] || [ "$FM_PR_GITLAB_ASYNC_CONFIGURED" = true ] || return 0
      printf 'error: refusing to merge %s with GitLab auto-merge, requested here or already set on the merge request: the merge is bound to the captain-approved head, and auto-merge would land the merge request later with any push made by then; merge once the checks are green instead, cancelling any auto-merge or scheduled merge set on the merge request\n' \
        "$URL" >&2
      return 1
      ;;
  esac
}

FM_PR_MERGE_AUTHORITY=
# The authority read. bin/fm-merge-authority-lib.sh owns what the away-posture
# record's presence means; this function owns what a merge run may do about it,
# so the answer the merge poll later tags its ledger row with is the same answer
# resolved here. An unreadable record refuses rather than being skipped.
resolve_merge_authority() {
  FM_PR_MERGE_AUTHORITY=
  if fm_merge_authority_resolve "$FM_HOME" "$STATE" "$META" "$ID"; then
    FM_PR_MERGE_AUTHORITY=$FM_MERGE_AUTHORITY
    return 0
  fi
  echo "error: PR merge refused - the away-posture record could not be read; nothing was merged" >&2
  return 1
}

# Take the away record's own lock (bin/fm-afk-contract.sh owns it) so that
# record cannot be published, replaced, or archived between the authority read
# below and the forge command that acts on it. Refuses without the lock: a merge
# on authority nothing is holding still is exactly what this closes. This is the
# only path that holds both the per-task control lock and the away-record lock,
# and it always takes them in that order; the away-record side takes only its own
# lock, so the pair cannot deadlock.
hold_away_record_for_merge() {
  fm_afk_contract_lock_hold "$STATE" && return 0
  echo "error: PR merge refused - the away-posture record could not be locked for the merge; nothing was merged" >&2
  return 1
}

require_current_away_authority() {
  FM_PR_AWAY_POSTURE=false
  if fm_afk_contract_away_present "$STATE"; then
    FM_PR_AWAY_POSTURE=true
    if [ "$PROVIDER" = github ] && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
      echo "error: --auto is attended-only; while the away-posture record exists only a synchronous merge may run under its authority lock" >&2
      return 2
    fi
    if [ "$PROVIDER" = gitlab ] \
      && { [ "$FM_PR_GITLAB_ASYNC_REQUESTED" = true ] || [ "$FM_PR_GITLAB_ASYNC_CONFIGURED" = true ]; }; then
      echo "error: GitLab auto-merge is attended-only; while the away-posture record exists only an immediate merge may run under its authority lock" >&2
      return 2
    fi
  fi
  fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated
  resolve_merge_authority || return 1
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_RED[@]}" -gt 0 ]; then
    echo "error: --allow-red is attended-only; while the away-posture record exists the green check is absolute" >&2
    return 2
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_MISSING[@]}" -gt 0 ]; then
    echo "error: --allow-missing is attended-only; while the away-posture record exists every required check must report" >&2
    return 2
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "$ALLOW_NO_PIPELINE" = true ]; then
    echo "error: --allow-no-pipeline is attended-only; while the away-posture record exists a GitLab merge requires a successful head pipeline" >&2
    return 2
  fi
}

persist_accepted_merge_authority() {
  local status=0
  MERGE_META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$MERGE_META_LOCK" || return 1
  fm_merge_authority_persist "$STATE" "$ID" "$META" \
    "$PROVIDER" "$PR_HOST" "$PR_PATH" "$PR_NUMBER" "$FM_PR_MERGE_AUTHORITY" \
    || status=1
  fm_lock_release "$MERGE_META_LOCK" || status=1
  MERGE_META_LOCK=
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  printf 'actionable: the forge accepted the merge request for %s but its merge authority could not be persisted; the merge poll remains armed\n' \
    "$URL" >&2
  return 1
}

# While away, a merge proceeds only when github_read_merge_queue proves no
# merge queue, because a queued merge can land after its away authority
# lapses with the record's archive. A repository whose
# plan does not expose branch rules at all (GitHub's "Upgrade to GitHub Pro or
# make this repository public" 403) proves the rules side on its own, since
# such a repository cannot have a merge_queue rule either; see
# github_read_queue_method, which resolves that specific 403 to status=none.
# Every other failure to read the queue state (auth, rate limit, network, a
# 404, or an unrelated 403) stays unreadable and refuses the merge. The merge
# stays synchronous (--auto is refused earlier) and every other gate still
# applies.
refuse_github_queue_while_away() {
  [ "$FM_PR_AWAY_POSTURE" = true ] || return 0
  # Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
  # oversight: a queue rule or PR base change after this preflight can still
  # enqueue the merge, which can land after its away authority lapses.
  github_read_merge_queue
  case "$FM_PR_GITHUB_MERGE_QUEUE" in
    absent) return 0 ;;
    present)
      printf 'error: GitHub merge refused while away because base branch %s requires a merge queue, so its merge-queue state does not prove an immediate merge; nothing was handed to the forge\n' \
        "$FM_PR_GITHUB_BASE" >&2
      ;;
    *)
      printf 'error: GitHub merge refused while away because whether base branch %s requires a merge queue could not be read, so its merge-queue state does not prove an immediate merge; nothing was handed to the forge, and the merge can be retried once that state reads\n' \
        "$FM_PR_GITHUB_BASE" >&2
      ;;
  esac
  return 2
}

require_recorded_pr_identity() {
  local existing
  existing=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$existing" ] || return 0
  [ "$existing" = "$URL" ] && return 0
  # Parsed in a subshell so FM_PR_* stays the new URL's identity for every
  # caller after this gate; only the already-notified verdict escapes.
  if ( fm_pr_url_parse "$existing" \
    && fm_pr_poll_merge_already_notified "$STATE" "$ID" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ); then
    return 0
  fi
  echo "error: task $ID is bound to $existing, not $URL" >&2
  return 1
}

FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  if [ "$FM_PR_AWAY_POSTURE" = true ]; then
    printf 'error: the direct merge did not land while the away-posture record exists; merge-queue retry flags are unavailable because a queued merge would outlive its authority\n' >&2
    return 0
  fi
  if [ "$FM_PR_HEAD_BOUND" = true ]; then
    printf 'error: the direct merge did not land, and a merge bound to the captain-approved head is offered no merge-queue or auto-merge retry, because either would land the pull request later with any push made by then; a base branch that requires a merge queue needs a later design\n' >&2
    return 0
  fi
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s --attended-override -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    if [ "$FM_PR_AWAY_POSTURE" = true ]; then
      printf 'error: the synchronous merge did not land while the away-posture record exists; no asynchronous merge or queue retry is available under away authority\n' >&2
    else
      printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
        "$URL" >&2
    fi
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Unlike gh and glab, "tea api" reports an HTTP-level failure (a rejected or
# malformed merge request included) with exit status 0 and the error only in
# the response body, verified empirically against a real Forgejo instance. So
# this confirmation is not a bonus corroboration of an already-trusted exit
# code the way gitlab_confirm_merged's is: it is the only reliable signal that
# a Forgejo merge landed at all.
forgejo_confirm_merged() {
  local json merged
  if ! json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
    "/repos/{owner}/{repo}/pulls/$PR_NUMBER" 2>/dev/null) || [ -z "$json" ]; then
    return 2
  fi
  if ! merged=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.merged | type == "boolean") then .merged else error("invalid merged field") end' \
    2>/dev/null); then
    return 2
  fi
  [ "$merged" = true ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
away_status=0
require_current_away_authority || away_status=$?
[ "$away_status" -eq 0 ] || exit "$away_status"
require_recorded_pr_identity || exit 1
record_pr_metadata || exit 1
require_released_captain_hold || exit 1

# Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
# oversight: if this lock-owning shell dies while its gh or glab child lives,
# stale-owner recovery can release the record for archive or replacement and
# the orphaned forge child can still merge on the lapsed away authority.
case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    # mergeable reads UNKNOWN for a short while after a push or base-branch
    # change while GitHub recomputes it; retry a bounded number of times,
    # re-reading and re-checking every live condition on each attempt, rather
    # than refusing a pull request that is simply still being computed. The
    # delay is capped at 0-10 seconds so the wait stays short under the lock.
    mergeable_retry_delay=${FM_PR_GITHUB_MERGEABLE_RETRY_DELAY:-3}
    case "$mergeable_retry_delay" in
      [0-9] | 10) ;;
      *) mergeable_retry_delay=3 ;;
    esac
    mergeable_attempt=1
    while :; do
      mergeable_status=0
      github_verify_mergeable || mergeable_status=$?
      if [ "$mergeable_status" -eq 0 ]; then
        break
      fi
      if [ "$mergeable_status" -ne 3 ] || [ "$mergeable_attempt" -ge 5 ]; then
        break
      fi
      sleep "$mergeable_retry_delay"
      mergeable_attempt=$((mergeable_attempt + 1))
    done
    if [ "$mergeable_status" -ne 0 ]; then
      if [ "$mergeable_status" -eq 3 ]; then
        printf 'error: mergeability for %s is still being computed by GitHub; retry shortly\n' "$URL" >&2
      fi
      exit 1
    fi
    require_approved_head || exit 1
    if [ "$LOW_RISK" = true ]; then
      github_require_low_risk_tier || exit 4
    fi
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    refuse_github_queue_while_away || exit 2
    require_approved_head || exit 1
    merge_status=0
    merge_output=$(gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      --match-head-commit "$FM_PR_MERGE_HEAD" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1) || merge_status=$?
    if [ "$merge_status" -eq 0 ]; then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
      persist_accepted_merge_authority || exit 1
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
    else
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      if [ "$FM_PR_HEAD_BOUND" = true ]; then
        printf 'error: %s entered the merge queue instead of merging (state=%s, merged=%s, isInMergeQueue=%s), but the merge is bound to the captain-approved head, and a queued merge would land with any push made by then; take it out of the merge queue and tell the captain, because a base branch that requires a merge queue needs a later design\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        exit 1
      fi
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    require_approved_head || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    require_approved_head || exit 1
    merge_status=0
    gitlab_merge_args=()
    if [ "$FM_PR_AWAY_POSTURE" = true ] || [ "$FM_PR_HEAD_BOUND" = true ]; then
      gitlab_merge_args=(--auto-merge=false)
    fi
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@" "${gitlab_merge_args[@]+"${gitlab_merge_args[@]}"}" || merge_status=$?
    if [ "$merge_status" -ne 0 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      exit "$merge_status"
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  forgejo)
    forgejo_reject_unsupported_args "$@" || exit 1
    forgejo_method=$(caller_merge_method "$@")
    [ -n "$forgejo_method" ] || forgejo_method=$(forgejo_default_merge_style) || exit 1
    forgejo_verify_mergeable || exit 1
    require_approved_head || exit 1
    # The away record is locked first, so this last presence and authority
    # read and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    require_approved_head || exit 1
    # head_commit_id binds the merge to the head this run verified: Forgejo's
    # REST API rejects a mismatched value with "head out of date" (verified
    # against a real instance), matching --match-head-commit/--sha above. tea
    # exposes no such flag on its own merge subcommand, so the API is called
    # directly through "tea api" instead.
    merge_output=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
      -X POST "/repos/{owner}/{repo}/pulls/$PR_NUMBER/merge" \
      -f "Do=$forgejo_method" -f "head_commit_id=$FM_PR_MERGE_HEAD" 2>&1) || true
    # "tea api" reports an HTTP-level failure with exit status 0 (also
    # verified against a real instance), so that output is kept only for the
    # failure report below; the merge is judged solely by reading the pull
    # request back through forgejo_confirm_merged. Only an unreadable read-back
    # (status 2) is retried, a bounded number of times, so a transient read
    # failure after a landed merge is not reported as unmerged; a definite
    # merged=false stops at once.
    forgejo_confirm_attempt=1
    while :; do
      forgejo_confirm_rc=0
      forgejo_confirm_merged || forgejo_confirm_rc=$?
      [ "$forgejo_confirm_rc" -eq 2 ] && [ "$forgejo_confirm_attempt" -lt 5 ] || break
      sleep 1
      forgejo_confirm_attempt=$((forgejo_confirm_attempt + 1))
    done
    if [ "$forgejo_confirm_rc" -ne 0 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      [ -z "$merge_output" ] || printf 'error: > %s\n' "$merge_output" >&2
      echo "error: Forgejo did not confirm $URL as merged" >&2
      exit 1
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self \
  "${FM_PR_MERGE_AUTHORITY:-}" || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
