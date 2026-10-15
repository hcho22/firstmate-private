#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Both bind a run
# by strict branch-and-head identity first, then by the run's own recorded
# submission of this copy's head (fm_nm_run_is_submitted_head_active below),
# and both then recognize a provable
# pipeline-owned continuation through fm_nm_runs_status_for_worktree below:
# crew-state for an ACTIVE run, so a fix round never reads as an older failed
# run, and teardown for a run PARKED at a gate, so cleanup concludes it
# instead of orphaning it. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
# fm-classify-lib.sh's wedge-deferral probe also sources it, to resolve an
# attributed run's own copy through fm_nm_run_worktree below.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Full commit sha for sha-ish $2 as seen from worktree $1's own object store;
# empty when the object is absent or ambiguous. Read-only: never fetches,
# never moves refs or custody.
fm_nm_resolve_commit() {  # <worktree> <sha-ish>
  git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null || true
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# A run head whose object this copy does not have cannot be proven here and is
# rejected; fm_nm_run_is_submitted_head_active below binds an active run by its
# own record of submitting this exact head, fm_nm_runs_status_for_worktree
# below owns the one ledger-anchored recognition for that case, and
# fm_nm_run_is_pipeline_owned_active below carries the custody exemption: a
# live run whose pipeline currently owns the branch binds without head
# equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(fm_nm_resolve_commit "$wt" "$run_head")
  [ -n "$run_full" ] || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The custody exemption to the head rule above: while the pipeline OWNS the
# branch (branch_sync.state=pipeline_owned), the daemon's own branch
# attribution IS the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# Scalar <key> directly under the `branch_sync.<block>` sub-block of captured
# `axi status` TOON $1, located by indentation so a same-named key elsewhere
# (the run's own `status:`, another sub-block's `head:`) never answers:
#   branch_sync:
#     pipeline:
#       run: "01M49AQW5W6RW2APH2FT58PM8B"
#       submitted_head: f26317d59169245a1a5c3fa8b36a6cfdeb329dbf
# Quotes stripped; empty when the block or key is absent.
fm_nm_branch_sync_field() {  # <toon-output> <block> <key>
  local v
  v=$(printf '%s\n' "$1" | awk -v blk="$2" -v key="$3" '
    function ind(s) { return match(s, /[^[:space:]]/) - 1 }
    function keyed(s, k,   t) {
      t = substr(s, ind(s) + 1)
      if (substr(t, 1, length(k) + 1) != k ":") return 0
      found = substr(t, length(k) + 2)
      return 1
    }
    /^[[:space:]]*$/ { next }
    depth == 0 { if ($0 ~ /^[[:space:]]*branch_sync:[[:space:]]*$/) { depth = 1; top = ind($0) }; next }
    { i = ind($0) }
    i <= top { exit }
    depth == 1 {
      if (child == "") child = i
      if (i == child && keyed($0, blk) && found ~ /^[[:space:]]*$/) { depth = 2; bi = i }
      next
    }
    i <= bi { exit }
    {
      if (grand == "") grand = i
      if (i == grand && keyed($0, key)) { print found; exit }
    }
  ')
  fm_nm_strip_quotes "$v"
}

# The submitted-head binding: an ACTIVE run binds to worktree $1 when its own
# branch_sync record names it as the pipeline run (pipeline.run equals the
# run's id) AND says that run was submitted from exactly this worktree's HEAD
# (pipeline.submitted_head equals the full local HEAD). The head rule above
# cannot see this once the pipeline pushes its own fix commits: the run head is
# then a commit the task copy never fetched, branch_sync reads `behind` rather
# than pipeline_owned, and a single-run branch has no older ledger row to
# anchor fm_nm_runs_status_for_worktree. The submission record is the
# pipeline's own, immutable for the run, and exact-equality only, so local work
# committed after submission, a run from an earlier task on a reused branch
# name, or another head's run never matches. Like the custody exemption it
# never applies to a terminal run.
fm_nm_run_is_submitted_head_active() {  # <worktree> <toon-output>
  local wt=$1 out=$2 run_id bound_run submitted local_full
  fm_nm_run_is_active "$out" || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  bound_run=$(fm_nm_branch_sync_field "$out" pipeline run)
  [ "$bound_run" = "$run_id" ] || return 1
  case "$(fm_nm_branch_sync_field "$out" pipeline status)" in
    completed|failed|cancelled) return 1 ;;
  esac
  submitted=$(fm_nm_branch_sync_field "$out" pipeline submitted_head)
  [ -n "$submitted" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  [ "$submitted" = "$local_full" ]
}

# ONE owner for attribution from the pipeline's own runs ledger, replacing a
# per-row scan-and-skip. The ledger is the real top-level `no-mistakes runs
# --limit N` listing (plain text, no run id, no quoting, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]"; the `axi` surface has no
# runs-listing subcommand - verified against the installed CLI). Prints the
# status word of the branch's CURRENT run row, or nothing when the ledger
# cannot prove attribution. When optional expected head $4 is supplied, its
# abbreviated commit identity must match the newest row. The branch's NEWEST
# row alone decides; older rows are history and never answer for the present:
#   - newest row's head resolves and matches the worktree (fm_nm_head_matches_worktree):
#     its status word
#   - newest row's head resolves but does not match: nothing (a newer run that
#     is not this worktree's makes every older row stale history)
#   - newest row's head does not resolve in this copy (the pipeline committed
#     its fix round in its own checkout and the task copy never fetched it):
#     recognized ONLY as a provable pipeline-owned continuation of the
#     submitted head, which requires ALL of: the row is ACTIVE (status
#     running), and the immediately older row for the SAME branch resolves to
#     EXACTLY the worktree HEAD. The pipeline's own ledger then proves an
#     unbroken run sequence from a run that ended at the submitted head to an
#     active run on the same branch - the anchored active row's status word is
#     printed. Anything else (no anchor row, an anchor that is merely an
#     ancestor, a terminal unresolvable row) prints nothing, so branch-name
#     coincidence, arbitrary remote state, and other tasks' runs never match.
# Read-only: git reads resolve objects in place; custody never changes.
fm_nm_runs_status_for_worktree() {  # <worktree> <branch> <runs-list-output> [expected-head]
  local wt=$1 branch=$2 list=$3 expected_head=${4:-}
  local local_full row st br sha day clock pr extra year_num month_num day_num max_day pending_st=''
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || return 0
    [ -z "$extra" ] || return 0
    case "$st" in *[!a-z_-]*|'') return 0 ;; esac
    case "$br" in *[!A-Za-z0-9._/-]*|'') return 0 ;; esac
    case "$sha" in *[!A-Fa-f0-9]*|'') return 0 ;; esac
    case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac
    case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 0 ;; esac
    case "$pr" in ''|https://*) ;; *) return 0 ;; esac
    [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || return 0
    year_num=$((10#${day%%-*}))
    month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
    day_num=$((10#${day##*-}))
    [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || return 0
    case "$month_num" in
      1|3|5|7|8|10|12) max_day=31 ;;
      4|6|9|11) max_day=30 ;;
      2)
        if (( year_num % 400 == 0 || (year_num % 4 == 0 && year_num % 100 != 0) )); then
          max_day=29
        else
          max_day=28
        fi
        ;;
    esac
    [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || return 0
    [ "$br" = "$branch" ] || continue
    if [ -n "$pending_st" ]; then
      # This is the row immediately older than the active unresolvable row:
      # the only admissible anchor, and only exact head equality proves the
      # worktree still sits at the submitted head.
      if [ "$(fm_nm_resolve_commit "$wt" "$sha")" = "$local_full" ]; then
        printf '%s' "$pending_st"
      fi
      return 0
    fi
    if [ -n "$expected_head" ]; then
      case "$expected_head" in *[!A-Fa-f0-9]*|'') return 0 ;; esac
      [ "${#expected_head}" -ge 7 ] && [ "${#expected_head}" -le 40 ] || return 0
      case "$expected_head" in
        "$sha"*) ;;
        *) case "$sha" in "$expected_head"*) ;; *) return 0 ;; esac ;;
      esac
    fi
    if [ -n "$(fm_nm_resolve_commit "$wt" "$sha")" ]; then
      if fm_nm_head_matches_worktree "$wt" "$sha"; then
        printf '%s' "$st"
      fi
      return 0
    fi
    [ "$st" = running ] || return 0
    pending_st=$st
  done <<< "$list"
  return 0
}

# Seconds in one compact duration as `axi status` renders it: `<n>s`,
# `<n>m<n>s`, `<n>h<n>m`, or `<n>d<n>h`. Prints nothing for anything else, so
# an unrecognized rendering reads as no activity rather than as fresh activity.
# The rendering truncates below its smallest unit, so `1h16m` is anywhere in
# [4560, 4620); with `ceil` the result is the largest value the rendering can
# stand for (4619) instead of the smallest.
fm_nm_compact_duration_secs() {  # <duration> [ceil]
  local d=$1 total=0 n unit last=''
  [ -n "$d" ] || return 0
  while [ -n "$d" ]; do
    n=${d%%[!0-9]*}
    [ -n "$n" ] || return 0
    d=${d#"$n"}
    unit=${d:0:1}
    d=${d:1}
    case "$unit" in
      d) total=$(( total + 10#$n * 86400 )) ;;
      h) total=$(( total + 10#$n * 3600 )) ;;
      m) total=$(( total + 10#$n * 60 )) ;;
      s) total=$(( total + 10#$n )) ;;
      *) return 0 ;;
    esac
    last=$unit
  done
  if [ "${2:-}" = ceil ]; then
    case "$last" in
      d) total=$(( total + 86399 )) ;;
      h) total=$(( total + 3599 )) ;;
      m) total=$(( total + 59 )) ;;
    esac
  fi
  printf '%s' "$total"
}

# The freshest activity among the run's active steps, from the `active_steps`
# table `axi status` prints while a step is running or fixing:
#   active_steps[N]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
#     test,fixing,2m35s,11s,"9s ago: claude producing output","84750",fix 1
# The pipeline refreshes a step's last_activity from its step log and from its
# own agent's output, and prefixes it with `quiet ` past step_quiet_warning;
# either way the age is the leading `<duration> ago`. A configured command the
# step runs itself (the test step's `commands.test`) records no agent_pid and
# refreshes last_activity only when it finishes. Columns are located by header
# name, cells may be double-quoted with embedded commas, and every row whose
# age cannot be read is skipped. Prints "<step> <age-secs> <active-secs>" for
# the freshest readable row, where <active-secs> is the most that row's
# active_for can stand for (how long ago, at most, the step started), or
# "<step> <age-secs>" when active_for cannot be read; nothing when the table is
# absent or unreadable.
fm_nm_freshest_step_activity() {  # <toon-output>
  local rows step age active best_step='' best_age='' best_active='' secs
  rows=$(printf '%s\n' "$1" | awk '
    function cells(line, out,   n, i, c, q, cur) {
      n = 0; q = 0; cur = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { q = !q; continue }
        if (c == "," && !q) { out[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      out[++n] = cur
      return n
    }
    !inside && /^[[:space:]]*active_steps\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      hdr = $0
      sub(/^[^{]*\{/, "", hdr); sub(/\}.*$/, "", hdr)
      nh = split(hdr, names, ",")
      sc = 0; ac = 0; fc = 0
      for (i = 1; i <= nh; i++) {
        if (names[i] == "step") sc = i
        if (names[i] == "last_activity") ac = i
        if (names[i] == "active_for") fc = i
      }
      ind = match($0, /[^[:space:]]/)
      inside = (sc && ac) ? 1 : 0
      next
    }
    inside {
      if (match($0, /[^[:space:]]/) <= ind || $0 ~ /^[[:space:]]*$/) exit
      line = $0; sub(/^[[:space:]]+/, "", line)
      delete row
      cells(line, row)
      printf "%s\037%s\037%s\n", row[sc], row[ac], (fc ? row[fc] : "")
    }
  ')
  while IFS=$'\037' read -r step age active; do
    [ -n "$step" ] || continue
    age=${age#quiet }
    case "$age" in *" ago"|*" ago:"*) age=${age%% ago*} ;; *) continue ;; esac
    secs=$(fm_nm_compact_duration_secs "$age")
    [ -n "$secs" ] || continue
    if [ -z "$best_age" ] || [ "$secs" -lt "$best_age" ]; then
      best_step=$step
      best_age=$secs
      best_active=$(fm_nm_compact_duration_secs "$active" ceil)
    fi
  done <<< "$rows"
  [ -n "$best_age" ] && printf '%s %s%s' "$best_step" "$best_age" "${best_active:+ $best_active}"
  return 0
}

# The physical path of run <run-id>'s own copy, where the pipeline runs its
# steps' commands and agents: <root>/worktrees/<repo-id>/<run-id>, under the
# same root the no-mistakes CLI resolves (NM_HOME, else ~/.no-mistakes), so it
# names the daemon that just answered `axi status` in this environment. The
# daemon binds a run's processes by this same working directory when it reaps
# them. Prints nothing unless <run-id> is a plain identifier naming exactly one
# such directory.
fm_nm_run_worktree() {  # <run-id>
  local id=$1 root match='' d
  case "$id" in ''|*[!A-Za-z0-9]*) return 0 ;; esac
  root=${NM_HOME:-${HOME:-}/.no-mistakes}
  [ -n "$root" ] && [ -d "$root/worktrees" ] || return 0
  for d in "$root/worktrees"/*/"$id"; do
    [ -d "$d" ] || continue
    [ -z "$match" ] || return 0
    match=$d
  done
  [ -n "$match" ] || return 0
  (cd "$match" 2>/dev/null && pwd -P)
  return 0
}
