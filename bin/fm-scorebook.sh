#!/usr/bin/env bash
# fm-scorebook.sh - record each question firstmate puts to the captain, what
# firstmate recommended, and whether the captain's answer matched, and report
# agreement by kind so a kind the captain always answers as recommended can be
# handed to firstmate once he says yes to that kind.
#
# Usage:
#   fm-scorebook.sh kinds
#   fm-scorebook.sh ask --kind <kind> --recommend <text> \
#     (--held <task-id> | --question <text>) [--task <task-id>] [--project <name>]
#   fm-scorebook.sh answer <question-id> --matched yes|no [--answer <text>]
#   fm-scorebook.sh withdraw <question-id> --reason <text>
#   fm-scorebook.sh pending
#   fm-scorebook.sh report
#   fm-scorebook.sh grant <kind> --captain-words-file <path>
#   fm-scorebook.sh revoke <kind> --reason <text>
#   fm-scorebook.sh granted <kind>
#
# The policy for when to record and how a granted kind is decided is owned by
# .agents/skills/ask-user-authority/SKILL.md for review findings,
# .agents/skills/captain-hold-lifecycle/SKILL.md for calls held for the
# captain, and AGENTS.md section 9 for any other question put to him; this
# script owns the kinds, the record, the threshold, and the grant check.
#
# Kinds. `kinds` prints this set and whether each can be handed to firstmate.
# merge, credential, and destructive always stay with the captain, because
# AGENTS.md requires his own words for those; every other kind can be handed
# off, and each policy owner above checks `granted` before putting a question
# of that kind to him.
#   finding-scope    an ask-user review finding whose fix would expand the
#                    accepted contract
#   finding-design   an ask-user review finding that needs a product or
#                    architecture call the accepted intent does not settle
#   finding-repeat   a repeated same-theme review finding while fixes accrete
#                    around a questionable abstraction
#   design           a design or product pick outside a review gate, such as
#                    an investigation, visual review, or intake question
#   merge            a merge or local landing approval; a project's yolo
#                    posture, not this record, is the only standing relaxation
#   credential       a credential or login only the captain can supply
#   destructive      a destructive, irreversible, or security-sensitive action
#   other            any other question
#
# `ask` records one question and prints its id. A question carried by a task
# held for the captain in this home (bin/fm-captain-hold.sh) passes
# `--held <task-id>`: the task must be an open captain call here, the question
# id is the task id, the question text is not copied because the hold reason
# already records it, and the call's lifecycle identity
# (bin/fm-captain-hold.sh open --identity) is recorded so `answer` can tell when
# an answer lands on it. Any other question passes `--question` and gets a fresh
# `chat-` id: one asked only in chat, one relayed from a secondmate home whose
# backlog holds its task, or each further question on a held task that already
# carries one, with `--task` naming that task. An id with an unanswered question
# is refused, so a re-held task records a new question only after its earlier
# one was answered or withdrawn.
#
# `answer` closes the latest open question with that id and records whether the
# captain's answer matched firstmate's recommendation, which is firstmate's
# judgment and never inferred here. A held question's answer is the captain's
# words already recorded on the task by bin/fm-captain-hold.sh answer, so
# `--answer` is refused for it, and it is refused while the task is still an
# open captain call with no resolution recorded since the ask: the count after
# `#` in its lifecycle identity must have grown. A deferral re-held with a new
# hold-set stamp but no answer is still refused, while a call answered with
# `--release` and held again for a new question is accepted. A chat question
# requires `--answer` with his words. When the answer makes its kind newly
# qualify for hand-off, `answer` prints one line naming the kind and its count;
# later answers that keep it qualifying print nothing.
# `withdraw` closes a question that dissolved without his answer, such as a
# call reconciled as moot; it never counts toward agreement.
# `pending` lists open questions, one per line: id, kind, held or chat, asked
# at. captain-hold-lifecycle uses it to find questions still waiting for an
# answer to record, for example after a restart.
#
# Threshold. A hand-off kind qualifies when it has at least 10 answered
# questions and the 10 most recently answered all matched. Withdrawn and open
# questions do not count. `report` prints, for every kind: asked, answered,
# matched, open, withdrawn, the most recent answers as matched/considered, and
# a status of granted, qualifies, not-yet, or captain-only.
#
# Grants. A qualifying kind still stays with the captain until he says yes to
# that specific kind. `grant` records his exact words from a non-empty file of
# at most 8192 bytes and is refused for a kind that cannot be handed off;
# firstmate never runs it without his yes. `revoke` takes the kind back on
# anyone's word. `granted` is that check: exit 0 when the kind's latest grant
# or revoke is a grant and the kind can be handed off, 1 when it is not
# granted, 2 on bad usage or an unreadable record.
#
# Record. One JSON object per line, appended to data/captain-scorebook.jsonl in
# the active home (FM_HOME, or FM_DATA_OVERRIDE), never a tracked path: before
# writing, a record inside a git work tree must be ignored by it, or the write
# is refused. Each home keeps its own record and grants and never reads
# another's: only the home that puts a question to the captain records it, and
# a grant given in the main home does not apply in a secondmate home.
# Fields: event (ask, answer, withdraw, grant, revoke), at (UTC); ask adds id,
# kind, recommendation, held (bool), call_identity (held only), question (chat
# only), task, and project; answer adds id, matched (bool), and answer (chat
# only); withdraw adds id and reason; grant adds kind and captain_words; revoke
# adds kind and reason. Writers serialize on state/.captain-scorebook.lock.
#
# Exit status: 0 on success, 1 on a refused or failed command, 2 on bad usage.
set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/captain-scorebook.jsonl"
LOCK="$STATE/.captain-scorebook.lock"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

KINDS='finding-scope finding-design finding-repeat design merge credential destructive other'
HANDOFF_KINDS='finding-scope finding-design finding-repeat design other'
THRESHOLD=10
MAX_WORDS_BYTES=8192

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-scorebook: %s\n' "$*" >&2
  exit 1
}
bad_usage() {
  printf 'fm-scorebook: %s\n' "$*" >&2
  exit 2
}

in_list() {  # <word> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}
require_kind() {
  in_list "$1" "$KINDS" || bad_usage "unknown kind: $1 (see: fm-scorebook.sh kinds)"
}
require_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}
now_utc() {
  TZ=UTC0 date +%Y-%m-%dT%H:%M:%SZ
}

# The record is private: refuse to write it anywhere a git work tree would
# track it.
require_private_ledger() {
  local dir
  dir=${LEDGER%/*}
  mkdir -p "$dir" || fail "cannot create $dir"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$dir" check-ignore -q -- "$LEDGER" \
      || fail "refusing to write $LEDGER: it is not ignored by the git work tree that contains it"
  fi
}

LOCK_HELD=0
release_lock() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  LOCK_HELD=0
}
trap release_lock EXIT
acquire_lock() {
  mkdir -p "$STATE" || fail "cannot create $STATE"
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
}

append_event() {  # <json-object>
  require_private_ledger
  printf '%s\n' "$1" >> "$LEDGER" || fail "cannot append to $LEDGER"
}

# Prints the whole record as one JSON array, or [] when there is none.
read_events() {
  if [ ! -e "$LEDGER" ]; then
    printf '[]\n'
    return 0
  fi
  jq -cs . "$LEDGER" || fail "record is unreadable: $LEDGER"
}

# The open question with <id>, as JSON, or nothing.
open_question() {  # <id>
  read_events | jq -c --arg id "$1" '
    reduce .[] as $e (null;
      if $e.id != $id then .
      elif $e.event == "ask" then $e
      elif $e.event == "answer" or $e.event == "withdraw" then null
      else . end)
    | select(. != null)'
}

command_kinds() {
  [ "$#" -eq 0 ] || bad_usage "kinds takes no arguments"
  local kind handoff
  for kind in $KINDS; do
    handoff=captain-only
    in_list "$kind" "$HANDOFF_KINDS" && handoff=hand-off
    printf '%s\t%s\n' "$kind" "$handoff"
  done
}

command_ask() {
  local kind='' recommend='' held='' question='' task='' project='' call_identity='' id event open
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind|--recommend|--held|--question|--task|--project)
        [ "$#" -ge 2 ] || bad_usage "$1 needs a value"
        case "$1" in
          --kind) kind=$2 ;;
          --recommend) recommend=$2 ;;
          --held) held=$2 ;;
          --question) question=$2 ;;
          --task) task=$2 ;;
          --project) project=$2 ;;
        esac
        shift 2
        ;;
      *) bad_usage "ask: unexpected argument: $1" ;;
    esac
  done
  require_kind "$kind"
  [ -n "$recommend" ] || bad_usage "ask needs --recommend"
  if [ -n "$held" ]; then
    [ -z "$question" ] || bad_usage "ask takes --held or --question, not both"
    [ -z "$task" ] || [ "$task" = "$held" ] || bad_usage "--task must match --held"
  else
    [ -n "$question" ] || bad_usage "ask needs --held <task-id> or --question <text>"
  fi
  require_jq
  if [ -n "$held" ]; then
    local rc=0
    call_identity=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$held" --identity) || rc=$?
    case "$rc" in
      0) ;;
      1) fail "task $held is not held for the captain in this home; record a question asked in chat or relayed from another home with --question" ;;
      *) fail "could not tell whether task $held is an open captain call" ;;
    esac
    id=$held
    task=$held
  else
    id="chat-$(TZ=UTC0 date +%Y%m%dT%H%M%SZ)-$$"
  fi
  acquire_lock
  open=$(open_question "$id") || fail "could not read the record"
  [ -z "$open" ] || fail "question $id is already open; answer or withdraw it first"
  event=$(jq -cn --arg at "$(now_utc)" --arg id "$id" --arg kind "$kind" \
    --arg recommendation "$recommend" --arg question "$question" \
    --arg task "$task" --arg project "$project" --arg call_identity "$call_identity" \
    --argjson held "$([ -n "$held" ] && echo true || echo false)" '
    {event: "ask", at: $at, id: $id, kind: $kind, recommendation: $recommendation, held: $held}
    + (if $held then {call_identity: $call_identity} else {question: $question} end)
    + {task: (if $task == "" then null else $task end),
       project: (if $project == "" then null else $project end)}')
  append_event "$event"
  release_lock
  printf '%s\n' "$id"
}

command_answer() {
  local id='' matched='' answer='' answer_set=0 open event kind before row
  [ "$#" -gt 0 ] || bad_usage "answer needs a question id"
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --matched) [ "$#" -ge 2 ] || bad_usage "--matched needs yes or no"; matched=$2; shift 2 ;;
      --answer) [ "$#" -ge 2 ] || bad_usage "--answer needs a value"; answer=$2; answer_set=1; shift 2 ;;
      *) bad_usage "answer: unexpected argument: $1" ;;
    esac
  done
  case "$matched" in
    yes) matched=true ;;
    no) matched=false ;;
    *) bad_usage "answer needs --matched yes or --matched no" ;;
  esac
  require_jq
  acquire_lock
  open=$(open_question "$id") || fail "could not read the record"
  [ -n "$open" ] || fail "no open question with id $id"
  if [ "$(printf '%s' "$open" | jq -r .held)" = true ]; then
    [ "$answer_set" = 0 ] || fail "question $id is held on its task: record the captain's words with fm-captain-hold.sh answer, not --answer"
    local rc=0 current asked
    current=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --identity) || rc=$?
    case "$rc" in
      1) ;;
      0)
        asked=$(printf '%s' "$open" | jq -r .call_identity)
        [ "${current##*#}" -gt "${asked##*#}" ] \
          || fail "task $id is still an open captain call with no answer recorded since the question; record his answer with fm-captain-hold.sh answer first"
        ;;
      *) fail "could not tell whether task $id is still an open captain call" ;;
    esac
  else
    [ -n "$answer" ] || fail "question $id was asked in chat: pass his answer with --answer"
  fi
  kind=$(printf '%s' "$open" | jq -r .kind)
  before=$(kind_row "$kind" | jq -r .status) || fail "could not build the report"
  event=$(jq -cn --arg at "$(now_utc)" --arg id "$id" --argjson matched "$matched" \
    --arg answer "$answer" --argjson set "$answer_set" '
    {event: "answer", at: $at, id: $id, matched: $matched}
    + (if $set == 1 then {answer: $answer} else {} end)')
  append_event "$event"
  row=$(kind_row "$kind") || fail "could not build the report"
  release_lock
  [ "$before" != qualifies ] || return 0
  printf '%s\n' "$row" | jq -r 'select(.status == "qualifies")
    | "\(.kind) newly qualifies for hand-off: its \(.recent) most recent answers all matched the recommendation (\(.answered) answered, \(.matched) matched)"'
}

command_withdraw() {
  local id='' reason='' event open
  [ "$#" -gt 0 ] || bad_usage "withdraw needs a question id"
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || bad_usage "--reason needs a value"; reason=$2; shift 2 ;;
      *) bad_usage "withdraw: unexpected argument: $1" ;;
    esac
  done
  [ -n "$reason" ] || bad_usage "withdraw needs --reason"
  require_jq
  acquire_lock
  open=$(open_question "$id") || fail "could not read the record"
  [ -n "$open" ] || fail "no open question with id $id"
  event=$(jq -cn --arg at "$(now_utc)" --arg id "$id" --arg reason "$reason" \
    '{event: "withdraw", at: $at, id: $id, reason: $reason}')
  append_event "$event"
  release_lock
}

# Folds the record into one row per kind.
report_rows() {
  local kinds_json handoff_json
  kinds_json=$(jq -cn --arg k "$KINDS" '$k | split(" ")')
  handoff_json=$(jq -cn --arg k "$HANDOFF_KINDS" '$k | split(" ")')
  read_events | jq -c --argjson kinds "$kinds_json" --argjson handoff "$handoff_json" \
    --argjson threshold "$THRESHOLD" '
    (reduce .[] as $e ({q: [], open: {}, seq: 0, grants: {}};
      if $e.event == "ask" then
        .open[$e.id] = (.q | length) | .q += [{kind: $e.kind, state: "open"}]
      elif ($e.event == "answer" or $e.event == "withdraw") and .open[$e.id] != null then
        .seq += 1
        | .q[.open[$e.id]] += (if $e.event == "answer"
            then {state: "answered", matched: $e.matched, seq: .seq}
            else {state: "withdrawn"} end)
        | del(.open[$e.id])
      elif $e.event == "grant" then .grants[$e.kind] = true
      elif $e.event == "revoke" then .grants[$e.kind] = false
      else . end)) as $s
    | [$kinds[] as $k
      | [$s.q[] | select(.kind == $k)] as $qs
      | [$qs[] | select(.state == "answered")] | sort_by(.seq) as $answered
      | ($answered | .[-$threshold:]) as $recent
      | ($handoff | index($k) != null) as $can
      | {kind: $k,
         asked: ($qs | length),
         answered: ($answered | length),
         matched: ([$answered[] | select(.matched)] | length),
         open: ([$qs[] | select(.state == "open")] | length),
         withdrawn: ([$qs[] | select(.state == "withdrawn")] | length),
         recent_matched: ([$recent[] | select(.matched)] | length),
         recent: ($recent | length),
         status: (if ($can | not) then "captain-only"
                  elif ($s.grants[$k] // false) then "granted"
                  elif ($answered | length) >= $threshold
                       and ([$recent[] | select(.matched | not)] | length) == 0
                    then "qualifies"
                  else "not-yet" end)}]'
}

# The report row for <kind>, as JSON.
kind_row() {  # <kind>
  report_rows | jq -c --arg k "$1" '.[] | select(.kind == $k)'
}

command_report() {
  local rows
  [ "$#" -eq 0 ] || bad_usage "report: unexpected argument: $1"
  require_jq
  rows=$(report_rows) || fail "could not build the report"
  {
    printf 'kind\tasked\tanswered\tmatched\topen\twithdrawn\trecent\tstatus\n'
    printf '%s\n' "$rows" | jq -r '.[] | [.kind, .asked, .answered, .matched, .open,
      .withdrawn, "\(.recent_matched)/\(.recent)", .status] | @tsv'
  } | awk -F '\t' '{ printf "%-15s %5s %8s %7s %4s %9s %6s  %s\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
  printf '\nA hand-off kind qualifies at %s answered questions with the %s most recent all answered as recommended.\n' \
    "$THRESHOLD" "$THRESHOLD"
  printf 'A qualifying kind stays with the captain until he says yes to it (fm-scorebook.sh grant).\n'
}

command_pending() {
  [ "$#" -eq 0 ] || bad_usage "pending takes no arguments"
  require_jq
  read_events | jq -r '
    (reduce .[] as $e ({};
      if $e.event == "ask" then .[$e.id] = $e
      elif $e.event == "answer" or $e.event == "withdraw" then del(.[$e.id])
      else . end))
    | to_entries | sort_by(.value.at) | .[].value
    | [.id, .kind, (if .held then "held" else "chat" end), .at] | @tsv'
}

command_grant() {
  local kind=${1:-} file='' size event
  [ -n "$kind" ] || bad_usage "grant needs a kind"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --captain-words-file) [ "$#" -ge 2 ] || bad_usage "--captain-words-file needs a path"; file=$2; shift 2 ;;
      *) bad_usage "grant: unexpected argument: $1" ;;
    esac
  done
  require_kind "$kind"
  in_list "$kind" "$HANDOFF_KINDS" || fail "kind $kind always stays with the captain and cannot be handed to firstmate"
  [ -n "$file" ] || bad_usage "grant needs --captain-words-file with the captain's own yes"
  [ -f "$file" ] && [ -s "$file" ] || fail "captain words file is missing or empty: $file"
  size=$(wc -c < "$file" | tr -d ' ')
  [ "$size" -le "$MAX_WORDS_BYTES" ] || fail "captain words file exceeds $MAX_WORDS_BYTES bytes"
  require_jq
  acquire_lock
  event=$(jq -cn --arg at "$(now_utc)" --arg kind "$kind" --rawfile words "$file" \
    '{event: "grant", at: $at, kind: $kind, captain_words: $words}')
  append_event "$event"
  release_lock
}

command_revoke() {
  local kind=${1:-} reason='' event
  [ -n "$kind" ] || bad_usage "revoke needs a kind"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || bad_usage "--reason needs a value"; reason=$2; shift 2 ;;
      *) bad_usage "revoke: unexpected argument: $1" ;;
    esac
  done
  require_kind "$kind"
  [ -n "$reason" ] || bad_usage "revoke needs --reason"
  require_jq
  acquire_lock
  event=$(jq -cn --arg at "$(now_utc)" --arg kind "$kind" --arg reason "$reason" \
    '{event: "revoke", at: $at, kind: $kind, reason: $reason}')
  append_event "$event"
  release_lock
}

command_granted() {
  local kind=${1:-} latest
  [ "$#" -eq 1 ] || bad_usage "granted takes exactly one kind"
  require_kind "$kind"
  in_list "$kind" "$HANDOFF_KINDS" || return 1
  command -v jq >/dev/null 2>&1 || bad_usage "jq is required"
  [ -e "$LEDGER" ] || return 1
  latest=$(jq -rs --arg kind "$kind" \
    '[.[] | select((.event == "grant" or .event == "revoke") and .kind == $kind)] | last | .event // ""' \
    "$LEDGER") || bad_usage "record is unreadable: $LEDGER"
  [ "$latest" = grant ]
}

case "${1:-}" in
  kinds) shift; command_kinds "$@" ;;
  ask) shift; command_ask "$@" ;;
  answer) shift; command_answer "$@" ;;
  withdraw) shift; command_withdraw "$@" ;;
  pending) shift; command_pending "$@" ;;
  report) shift; command_report "$@" ;;
  grant) shift; command_grant "$@" ;;
  revoke) shift; command_revoke "$@" ;;
  granted) shift; command_granted "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
