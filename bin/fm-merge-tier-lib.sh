#!/usr/bin/env bash
# fm-merge-tier-lib.sh - a project's low-risk merge tier: the changed files
# under which firstmate may merge a green pull request without the captain's
# word.
#
# The tier is a captain-set, per-project merge posture between yolo off, where
# the captain approves every merge, and yolo on, where firstmate merges any
# green, in-scope work. Under it, bin/fm-pr-merge.sh --low-risk merges only a
# pull request whose every changed path, read live from the forge at the head
# it verified, is low risk by the verdict below. Without a declaration nothing
# changes. AGENTS.md section 7 owns the merge-authority contract,
# docs/configuration.md "Low-risk merge tier" is the operator reference, and
# bin/fm-pr-merge.sh owns the live changed-file read.
#
# This file is the single owner of the declaration format, the pattern grammar,
# the built-in always-ask paths, and the per-path verdict.
#
# Declaration: config/merge-tiers in the home that merges, local to that home
# and not inherited by secondmate homes. One rule per line:
#   <project-name> low-risk <pattern>
#   <project-name> always-ask <pattern>
# <project-name> is the project's registered name, the basename of the task's
# project clone. The pattern is the last whitespace-separated field and the
# kind is the one before it, so the name may contain spaces, while a pattern
# cannot. Blank lines, and lines whose first non-blank character is `#`, are
# ignored, so a project whose name begins with `#` cannot be declared. A
# project is opted in when it has at least one low-risk rule; always-ask rules
# only narrow it. Any other line shape, an unknown kind, or a malformed pattern
# makes the whole file unreadable, and every --low-risk merge in that home then
# refuses, naming the line, rather than guessing which rule was meant.
#
# Pattern grammar. A pattern is a `/`-separated path anchored at the repository
# root, compared case-sensitively against the whole path:
#   *    any run of characters within one path segment
#   ?    exactly one character within one path segment
#   **   as a whole segment, any number of segments: `docs/**` is everything
#        under docs/, `**/*.md` is a Markdown file at any depth, `a/**/b`
#        is b directly or anywhere under a/, and `**` alone is every path
# Every other character matches itself. A pattern is malformed when it is
# empty; starts with `/` or `!`; ends with `/`; has an empty, `.`, or `..`
# segment; has a `**` that is not a whole segment or follows another `**`;
# or contains a control character or any of `[ ] { } \`. Character classes,
# braces, and negation are refused rather than read literally, because a rule
# that silently matches nothing it was written for would be a guess.
#
# Built-in always-ask paths, which no project rule can remove:
#   - CI workflow files: .github/workflows/**, .forgejo/workflows/**,
#     .gitea/workflows/**, and .gitlab-ci.yml.
#   - Agent instruction files: any path whose last segment is AGENTS.md or
#     CLAUDE.md, compared case-insensitively, because a case-insensitive
#     filesystem loads a differently cased copy as the instruction file.
#
# Verdict for one path, first match wins: a built-in always-ask path, then a
# project always-ask rule, then a project low-risk rule; a path none of them
# matches is unmatched. Only a low-risk verdict lets the merge proceed. The
# caller passes a rename as both its old and its new path.
#
# Sourced by bin/fm-pr-merge.sh and tests. No side effects on source.

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_ERROR=
FM_MERGE_TIER_LOW_RISK_PATTERNS=()
FM_MERGE_TIER_LOW_RISK_REGEXES=()
FM_MERGE_TIER_ALWAYS_ASK_PATTERNS=()
FM_MERGE_TIER_ALWAYS_ASK_REGEXES=()
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_VERDICT=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_BLOCKERS=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_BLOCKED_COUNT=0
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_TIER_JUDGED_COUNT=0
# How many refused paths a judgement names before summarizing the rest.
FM_MERGE_TIER_NAMED_MAX=20

# Translate one pattern into an anchored extended regular expression on
# stdout, or print why it is malformed on stderr and return 1.
fm_merge_tier_pattern_regex() {  # <pattern>
  local pattern=$1 out='' seg i n char prev_doublestar=0
  local -a segs
  if [ -z "$pattern" ]; then
    echo "the pattern is empty" >&2
    return 1
  fi
  if [[ $pattern == *[[:cntrl:]]* ]]; then
    echo "pattern \"$pattern\" contains a control character" >&2
    return 1
  fi
  case "$pattern" in
    /*) echo "pattern \"$pattern\" starts with /; patterns are anchored at the repository root without one" >&2; return 1 ;;
    '!'*) echo "pattern \"$pattern\" starts with !; negation is not supported, so list the path as always-ask instead" >&2; return 1 ;;
    */) echo "pattern \"$pattern\" ends with /; write ${pattern}** for everything under that directory" >&2; return 1 ;;
    *'['*|*']'*|*'{'*|*'}'*|*'\'*) echo "pattern \"$pattern\" contains one of [ ] { } \\, which are not supported" >&2; return 1 ;;
  esac
  IFS=/ read -r -a segs <<< "$pattern"
  n=${#segs[@]}
  for ((i = 0; i < n; i++)); do
    seg=${segs[i]}
    case "$seg" in
      ''|.|..)
        echo "pattern \"$pattern\" has an empty, \".\", or \"..\" path segment" >&2
        return 1
        ;;
      '**')
        if [ "$prev_doublestar" -eq 1 ]; then
          echo "pattern \"$pattern\" repeats ** in consecutive segments" >&2
          return 1
        fi
        if [ "$i" -eq $((n - 1)) ]; then
          # Trailing: one or more further segments, or every path alone.
          if [ "$i" -eq 0 ]; then out='.+'; else out="$out/.+"; fi
        elif [ "$i" -eq 0 ]; then
          out='(.*/)?'
        else
          out="$out/(.*/)?"
        fi
        prev_doublestar=1
        continue
        ;;
      *'**'*)
        echo "pattern \"$pattern\" uses ** inside a segment; ** must be a whole path segment" >&2
        return 1
        ;;
    esac
    [ "$i" -eq 0 ] || [ "$prev_doublestar" -eq 1 ] || out="$out/"
    prev_doublestar=0
    while [ -n "$seg" ]; do
      char=${seg:0:1}
      seg=${seg:1}
      case "$char" in
        '*') out="$out[^/]*" ;;
        '?') out="$out[^/]" ;;
        '.'|'+'|'('|')'|'|'|'^'|'$') out="$out\\$char" ;;
        *) out="$out$char" ;;
      esac
    done
  done
  printf '^%s$\n' "$out"
}

# Read the declaration for one project. Returns 0 when the project has at
# least one low-risk rule, 1 when it has none (including an absent file), and
# 2 when the file cannot be read or any line in it is malformed. Sets
# FM_MERGE_TIER_ERROR to a clause naming the cause for 1 and 2.
fm_merge_tier_load() {  # <config-dir> <project-name>
  local dir=$1 project=$2 file line lineno=0 kind pattern name regex nf want
  local -a fields
  FM_MERGE_TIER_ERROR=
  FM_MERGE_TIER_LOW_RISK_PATTERNS=()
  FM_MERGE_TIER_LOW_RISK_REGEXES=()
  FM_MERGE_TIER_ALWAYS_ASK_PATTERNS=()
  FM_MERGE_TIER_ALWAYS_ASK_REGEXES=()
  file="$dir/merge-tiers"
  read -r -a fields <<< "$project"
  want="${fields[*]}"
  if [ -z "$want" ]; then
    FM_MERGE_TIER_ERROR="the task names no project, so no low-risk merge tier can apply to it"
    return 1
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_MERGE_TIER_ERROR="no low-risk merge tier is declared for $want: $file does not exist"
    return 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_MERGE_TIER_ERROR="$file is not a readable regular file"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    read -r -a fields <<< "$line"
    nf=${#fields[@]}
    [ "$nf" -gt 0 ] || continue
    case "${fields[0]}" in '#'*) continue ;; esac
    if [ "$nf" -lt 3 ]; then
      FM_MERGE_TIER_ERROR="$file line $lineno is not \"<project> low-risk <pattern>\" or \"<project> always-ask <pattern>\""
      return 2
    fi
    pattern=${fields[nf - 1]}
    kind=${fields[nf - 2]}
    name="${fields[*]:0:nf-2}"
    case "$kind" in
      low-risk|always-ask) ;;
      *)
        FM_MERGE_TIER_ERROR="$file line $lineno names kind \"$kind\"; the kinds are low-risk and always-ask"
        return 2
        ;;
    esac
    if ! regex=$(fm_merge_tier_pattern_regex "$pattern" 2>&1); then
      FM_MERGE_TIER_ERROR="$file line $lineno: $regex"
      return 2
    fi
    [ "$name" = "$want" ] || continue
    if [ "$kind" = low-risk ]; then
      FM_MERGE_TIER_LOW_RISK_PATTERNS+=("$pattern")
      FM_MERGE_TIER_LOW_RISK_REGEXES+=("$regex")
    else
      FM_MERGE_TIER_ALWAYS_ASK_PATTERNS+=("$pattern")
      FM_MERGE_TIER_ALWAYS_ASK_REGEXES+=("$regex")
    fi
  done < "$file"
  if [ "${#FM_MERGE_TIER_LOW_RISK_PATTERNS[@]}" -eq 0 ]; then
    FM_MERGE_TIER_ERROR="no low-risk merge tier is declared for $want: $file has no low-risk rule for it"
    return 1
  fi
  return 0
}

# Judge one repository-relative path against the built-in always-ask paths and
# the rules fm_merge_tier_load read. Sets FM_MERGE_TIER_VERDICT to low-risk,
# always-ask, or unmatched, and FM_MERGE_TIER_REASON to why.
fm_merge_tier_verdict() {  # <path>
  local path=$1 i
  case "$path" in
    .github/workflows/*|.forgejo/workflows/*|.gitea/workflows/*|.gitlab-ci.yml)
      FM_MERGE_TIER_VERDICT=always-ask
      FM_MERGE_TIER_REASON='always ask: a CI workflow file'
      return 0
      ;;
  esac
  # Spelled out letter by letter, because Bash 3.2 has no case-folding
  # expansion and a subprocess per path would slow a large pull request.
  case "${path##*/}" in
    [aA][gG][eE][nN][tT][sS].[mM][dD]|[cC][lL][aA][uU][dD][eE].[mM][dD])
      FM_MERGE_TIER_VERDICT=always-ask
      FM_MERGE_TIER_REASON='always ask: an agent instruction file'
      return 0
      ;;
  esac
  for ((i = 0; i < ${#FM_MERGE_TIER_ALWAYS_ASK_REGEXES[@]}; i++)); do
    if [[ $path =~ ${FM_MERGE_TIER_ALWAYS_ASK_REGEXES[i]} ]]; then
      FM_MERGE_TIER_VERDICT=always-ask
      FM_MERGE_TIER_REASON="always ask: matches ${FM_MERGE_TIER_ALWAYS_ASK_PATTERNS[i]}"
      return 0
    fi
  done
  for ((i = 0; i < ${#FM_MERGE_TIER_LOW_RISK_REGEXES[@]}; i++)); do
    if [[ $path =~ ${FM_MERGE_TIER_LOW_RISK_REGEXES[i]} ]]; then
      FM_MERGE_TIER_VERDICT=low-risk
      FM_MERGE_TIER_REASON="low risk: matches ${FM_MERGE_TIER_LOW_RISK_PATTERNS[i]}"
      return 0
    fi
  done
  FM_MERGE_TIER_VERDICT=unmatched
  FM_MERGE_TIER_REASON='matches no low-risk pattern'
}

# Judge every path read from stdin, one per line. Returns 0 only when at least
# one path was judged and every one is low risk. Otherwise returns 1 and sets
# FM_MERGE_TIER_BLOCKERS to one "  - <path> (<reason>)" line per refused path,
# naming at most FM_MERGE_TIER_NAMED_MAX of them and counting the rest.
fm_merge_tier_judge() {
  local path named=0
  FM_MERGE_TIER_BLOCKERS=
  FM_MERGE_TIER_BLOCKED_COUNT=0
  FM_MERGE_TIER_JUDGED_COUNT=0
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    FM_MERGE_TIER_JUDGED_COUNT=$((FM_MERGE_TIER_JUDGED_COUNT + 1))
    fm_merge_tier_verdict "$path"
    [ "$FM_MERGE_TIER_VERDICT" = low-risk ] && continue
    FM_MERGE_TIER_BLOCKED_COUNT=$((FM_MERGE_TIER_BLOCKED_COUNT + 1))
    if [ "$named" -lt "$FM_MERGE_TIER_NAMED_MAX" ]; then
      FM_MERGE_TIER_BLOCKERS="$FM_MERGE_TIER_BLOCKERS  - $path ($FM_MERGE_TIER_REASON)
"
      named=$((named + 1))
    fi
  done
  if [ "$FM_MERGE_TIER_BLOCKED_COUNT" -gt "$named" ]; then
    FM_MERGE_TIER_BLOCKERS="$FM_MERGE_TIER_BLOCKERS  - and $((FM_MERGE_TIER_BLOCKED_COUNT - named)) more
"
  fi
  [ "$FM_MERGE_TIER_JUDGED_COUNT" -gt 0 ] && [ "$FM_MERGE_TIER_BLOCKED_COUNT" -eq 0 ]
}
