#!/usr/bin/env bash
# fm-nm-rounds.sh - count no-mistakes fix rounds per validation step, hold a
# driving worker to the fix-round cap, and keep each finished task's rounds to
# pass so projects whose reviews churn show up.
#
# Usage:
#   fm-nm-rounds.sh check --step <step> [--cap <n>] [--out-dir <dir>] [--worktree <dir>]
#   fm-nm-rounds.sh record <task-id>
#   fm-nm-rounds.sh report [--json] [--project <name>] [--limit <n>]
#
# This header is the one owner of what a fix round is, of the cap's default,
# of the check verdict and its escalation line, and of the rounds ledger schema.
# The generated no-mistakes brief (bin/fm-dod-lib.sh) tells the worker when to
# run check; .agents/skills/ask-user-authority owns what firstmate does with a
# cap escalation.
#
# Fix rounds. no-mistakes keeps one step_rounds row per execution of a step in
# a run. Round 1 is `initial`, and every later round that no-mistakes started
# by fixing the previous round's findings carries trigger_type `auto_fix`,
# whoever chose that fix: the previous round's selection_source is `user` when
# the driving worker chose it with `axi respond --action fix`, and `auto_fix`
# when the pipeline's own automatic fixing chose it. A step's fix rounds in a
# run are therefore its `auto_fix` rows; by_worker and by_pipeline split them
# by that previous selection_source, and a fix round with neither counts in
# fix_rounds only. A step executed again from scratch inside the same run (for
# example review again after a ci repair rebased the branch) records another
# `initial` row, which is not a fix round.
# `no-mistakes axi` reports none of this history (v1.79.0): `axi status` names
# only the current round of a running or fixing step in its active_steps table
# (`round N`, `fix N`, `auto-fix N/M`), and a gate prints no round count. So
# this script reads the state database read-only (mode=ro), located by
# bin/fm-nm-run-lib.sh's fm_nm_state_db, bounded by 30 seconds per no-mistakes
# or database call, as bin/fm-pipeline-spend.sh does.
# What it cannot see:
#   - edits an agent makes inside one execution of a step (document and lint
#     apply their changes in their own initial round, and test may edit while
#     it runs) are that step's own work, not fix rounds, and are not counted;
#   - fix rounds of another run on the same branch belong to that run: the cap
#     is per run, and the ledger keeps every run;
#   - a fix round still under way counts once it completes;
#   - when no-mistakes or its database cannot be read, the verdict is unknown.
#     The worker then counts its own `--action fix` responses to the step in
#     this run, which cannot see the pipeline's own automatic fix rounds.
#
# check: run where the task copy is (or name it with --worktree) while the
# current branch's run waits at <step>'s gate, before answering that gate with
# `--action fix`. It resolves the run from `no-mistakes axi status` (the id in
# its `run:` block) and prints `key: value` lines:
#   run, step, fix_rounds, by_worker, by_pipeline, cap
#   verdict      under-cap, cap-reached (fix_rounds >= cap), or unknown
#   reason       why the verdict is unknown (unknown only)
#   findings     the newest round's finding ids, comma separated, or none
#   returning    finding ids that appear in more than one round of the step
#   file         the rounds history it wrote (cap-reached with --out-dir)
#   escalation   the exact status line to append (cap-reached only):
#     needs-decision [at=<epoch>] [key=nm-<run>-<step>]: fix-round cap rounds=<n> findings=<ids> file=<file>
#     The key is the brief's ask-user key, so the decision binds to the run
#     exactly as an ask-user gate does; without --out-dir it has no file=.
# With --out-dir and the cap reached, it writes <dir>/nm-<run>-<step>-rounds.txt:
# every round of the step oldest first, who started it, and each finding
# verbatim (id, severity, file, line, action, description), then the returning
# ids, so the findings that kept returning can be read without the pipeline.
# The default cap is 3; --cap raises it when a captain decision allows more
# rounds. Exit status: 0 under-cap, 3 cap-reached, 1 unknown, 2 bad usage.
#
# record: append the task's fix rounds as one JSON object on one line of
# data/pipeline-rounds.jsonl, at most once per task incarnation (task id plus
# the record's spawn_gen), so a retried cleanup never counts a task twice.
# bin/fm-teardown.sh calls it for every no-mistakes ship task whose local copy
# it cleans up, before it deletes the task branch this script attributes runs
# by and before it removes state/<id>.meta. A task's runs are the ones
# fm_nm_task_run_attribution in bin/fm-nm-run-lib.sh attributes to it. The
# ledger is private and gitignored with the rest of data/.
# Exit status: 0 when a record was recorded or already present, or its source
# is unavailable; 1 when the task record is missing, names a secondmate, or the
# record could not be built or written; 2 for bad usage.
#
# Record schema (one JSON object):
#   task, spawn_gen         the task id and the incarnation recorded in its meta
#   project                 the task's data folder name (bin/fm-task-data-lib.sh)
#   pr                      the task's recorded pr= URL, or null
#   recorded_at             UTC time the record was built
#   source                  "no-mistakes-state", or "unavailable" when the runs
#                           could not be read; reason then says why, runs is
#                           empty, and rounds_to_pass is null
#   repo, branch, since     the attribution (since as UTC time or null)
#   runs[]                  {id, status, created_at, steps[]}, oldest first;
#                           steps[] is {step, fix_rounds, by_worker,
#                           by_pipeline} for every step that ran
#   rounds_to_pass          {run, total, max, steps[] {step, fix_rounds}} from
#                           the newest completed run, listing only steps with a
#                           fix round; run is null and the counts are null when
#                           no run completed
#
# report: the by-project view of that ledger, rounds to pass per PR. Each
# project row counts its recorded PRs (records whose rounds to pass are known),
# their total and mean fix rounds, the most any one step took, how many
# reached the cap on some step, and how many records are unknown. Projects with
# PRs at the cap sort first, then by mean. Each PR row names the project, task,
# PR, total, max, and the steps that took fix rounds, newest first; prs_total
# counts them all and --limit keeps only the newest <n>. TOON by default;
# --json prints {cap, projects[], prs_total, prs[]}. --project limits the view
# to one project.
# bin/fm-bearings-snapshot.sh projects this view; it is not a second owner.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-task-data-lib.sh
. "$SCRIPT_DIR/fm-task-data-lib.sh"

CAP_DEFAULT=3
TIMEOUT=30

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-nm-rounds: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'fm-nm-rounds: %s\n' "$*" >&2
  exit 2
}
positive_int() {
  case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
}

# The Python reader shared by check and record: the fix rounds of each step of
# one run, oldest round first, with every round's findings.
ROUNDS_PY='
import json
import sqlite3
from contextlib import closing
from pathlib import Path


def connect(database):
    path = Path(database)
    if not path.is_absolute():
        raise ValueError("state database path %s is not absolute" % database)
    if not path.exists():
        raise ValueError("no state database at %s" % database)
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    for table, needed in (("step_results", {"id", "run_id", "step_name", "step_order"}),
                          ("step_rounds", {"step_result_id", "round", "trigger_type"})):
        columns = {r["name"] for r in db.execute("PRAGMA table_info(%s)" % table)}
        if not needed <= columns:
            db.close()
            raise ValueError("table %s lacks %s" % (table, ", ".join(sorted(needed - columns))))
    return db


def findings_of(raw):
    try:
        value = json.loads(raw) if raw else None
    except ValueError:
        return []
    if isinstance(value, dict):
        value = value.get("findings")
    if not isinstance(value, list):
        return []
    return [f for f in value if isinstance(f, dict)]


def run_steps(db, run_id, only_step=None):
    columns = {r["name"] for r in db.execute("PRAGMA table_info(step_rounds)")}
    optional = ", ".join("x.%s AS %s" % (c, c) if c in columns else "NULL AS %s" % c
                         for c in ("selection_source", "findings_json"))
    query = ("SELECT s.step_name AS step, x.round AS round, x.trigger_type AS trigger_type, %s "
             "FROM step_results s JOIN step_rounds x ON x.step_result_id = s.id "
             "WHERE s.run_id = ?" % optional)
    params = [run_id]
    if only_step is not None:
        query += " AND s.step_name = ?"
        params.append(only_step)
    query += " ORDER BY s.step_order, x.round, x.rowid"
    steps = {}
    order = []
    for row in db.execute(query, params):
        step = steps.get(row["step"])
        if step is None:
            step = steps[row["step"]] = {"step": row["step"], "fix_rounds": 0, "by_worker": 0,
                                         "by_pipeline": 0, "rounds": []}
            order.append(row["step"])
        started_by = "start"
        if row["trigger_type"] == "auto_fix":
            step["fix_rounds"] += 1
            previous = step["rounds"][-1]["selection_source"] if step["rounds"] else None
            if previous == "user":
                step["by_worker"] += 1
                started_by = "worker fix"
            elif previous == "auto_fix":
                step["by_pipeline"] += 1
                started_by = "pipeline fix"
            else:
                started_by = "fix"
        step["rounds"].append({"round": row["round"], "trigger": row["trigger_type"],
                               "started_by": started_by, "selection_source": row["selection_source"],
                               "findings": findings_of(row["findings_json"])})
    return [steps[name] for name in order]
'

cmd_check() {
  local step='' cap=$CAP_DEFAULT out_dir='' wt=$PWD status run_id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step) [ "$#" -ge 2 ] || usage_error "--step needs a value"; step=$2; shift 2 ;;
      --cap) [ "$#" -ge 2 ] || usage_error "--cap needs a value"; cap=$2; shift 2 ;;
      --out-dir) [ "$#" -ge 2 ] || usage_error "--out-dir needs a value"; out_dir=$2; shift 2 ;;
      --worktree) [ "$#" -ge 2 ] || usage_error "--worktree needs a value"; wt=$2; shift 2 ;;
      *) usage_error "unknown check argument: $1" ;;
    esac
  done
  case "$step" in ''|*[!A-Za-z0-9_-]*) usage_error "--step must name a pipeline step" ;; esac
  positive_int "$cap" || usage_error "--cap must be a positive integer"
  if [ -n "$out_dir" ]; then
    case "$out_dir" in /*) ;; *) usage_error "--out-dir must be an absolute path" ;; esac
    [ -d "$out_dir" ] || usage_error "--out-dir $out_dir is not a directory"
  fi
  [ -d "$wt" ] || usage_error "--worktree $wt is not a directory"

  unknown() {
    printf 'step: %s\ncap: %s\nverdict: unknown\nreason: %s\n' "$step" "$cap" "$1"
    exit 1
  }
  command -v no-mistakes >/dev/null 2>&1 || unknown "no-mistakes is not installed"
  command -v python3 >/dev/null 2>&1 || unknown "python3 is required to read no-mistakes' state database"
  status=$(fm_nm_run_checked "$wt" "$TIMEOUT" axi status) || unknown "no-mistakes axi status failed"
  # The current branch's run is the `run:` block; `other_branch_run:` is never
  # this copy's run.
  run_id=$(printf '%s\n' "$status" | awk '
    /^run:[[:space:]]*$/ { inrun = 1; next }
    inrun && /^[^[:space:]]/ { exit }
    inrun && /^[[:space:]]+id:/ { sub(/^[[:space:]]+id:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
  ')
  case "$run_id" in
    '') unknown "no run on the current branch" ;;
    *[!A-Za-z0-9]*) unknown "unreadable run id" ;;
  esac
  fm_nm_bounded "$wt" "$TIMEOUT" python3 -c "$ROUNDS_PY"'
import sys
import time

database, run_id, step_name, cap, out_dir = sys.argv[1:]
cap = int(cap)


def say(key, value):
    print("%s: %s" % (key, value))


try:
    with closing(connect(database)) as db:
        steps = run_steps(db, run_id, step_name)
except (ValueError, OSError, sqlite3.Error) as err:
    say("run", run_id); say("step", step_name); say("cap", cap)
    say("verdict", "unknown"); say("reason", "cannot read no-mistakes state: %s" % err)
    sys.exit(1)
if not steps:
    say("run", run_id); say("step", step_name); say("cap", cap)
    say("verdict", "unknown"); say("reason", "run %s has no recorded round of step %s" % (run_id, step_name))
    sys.exit(1)
step = steps[0]
seen = {}
for r in step["rounds"]:
    for f in r["findings"]:
        fid = str(f.get("id", ""))
        if fid:
            seen.setdefault(fid, set()).add(r["round"])
current = [str(f.get("id")) for f in step["rounds"][-1]["findings"] if f.get("id")]
returning = [fid for fid in seen if len(seen[fid]) > 1]
reached = step["fix_rounds"] >= cap
say("run", run_id)
say("step", step_name)
for key in ("fix_rounds", "by_worker", "by_pipeline"):
    say(key, step[key])
say("cap", cap)
say("verdict", "cap-reached" if reached else "under-cap")
say("findings", ",".join(current) or "none")
say("returning", ",".join(returning) or "none")
if not reached:
    sys.exit(0)
path = ""
if out_dir:
    path = "%s/nm-%s-%s-rounds.txt" % (out_dir, run_id, step_name)
    lines = ["run: %s" % run_id, "step: %s" % step_name,
             "fix_rounds: %d (worker %d, pipeline %d)" % (step["fix_rounds"], step["by_worker"], step["by_pipeline"]),
             "returning: %s" % (",".join(returning) or "none"), ""]
    for r in step["rounds"]:
        lines.append("## round %s (%s)" % (r["round"], r["started_by"]))
        if not r["findings"]:
            lines.append("no findings")
        for f in r["findings"]:
            line = f.get("line")
            lines.append("- id: %s" % f.get("id", ""))
            lines.append("  severity: %s" % f.get("severity", ""))
            lines.append("  file: %s%s" % (f.get("file", ""), ":%s" % line if line not in (None, "") else ""))
            lines.append("  action: %s" % f.get("action", ""))
            lines.append("  seen_in_rounds: %s" % ",".join(str(n) for n in sorted(seen.get(str(f.get("id", "")), ()))))
            lines.append("  description: |")
            lines.extend("    " + d for d in str(f.get("description", "")).splitlines())
        lines.append("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    say("file", path)
say("escalation", "needs-decision [at=%d] [key=nm-%s-%s]: fix-round cap rounds=%d findings=%s%s"
    % (time.time(), run_id, step_name, step["fix_rounds"], ",".join(current) or "none",
       " file=%s" % path if path else ""))
sys.exit(3)
' "$(fm_nm_state_db "$wt")" "$run_id" "$step" "$cap" "$out_dir"
}

cmd_record() {
  [ "$#" -eq 1 ] || usage_error "record takes one task id"
  local id=$1 meta wt spawn_gen project pr
  fm_task_id_path_safe "$id" || usage_error "invalid task id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "no task record for $id"
  meta_value() {  # <key>
    grep "^$1=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
  }
  [ "$(meta_value kind)" != secondmate ] || fail "$id is a secondmate, not a task"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read no-mistakes' state database"
  [ -d "$DATA" ] || fail "data directory $DATA is missing"
  wt=$(meta_value worktree)
  spawn_gen=$(meta_value spawn_gen)
  project=$(fm_task_data_project_dirname "$DATA" "$(meta_value project)" 2>/dev/null)
  pr=$(meta_value pr)
  fm_nm_task_run_attribution "$wt" "$TIMEOUT"
  local run_dir=$wt
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || run_dir=$STATE
  fm_nm_bounded "$run_dir" "$TIMEOUT" python3 -c "$ROUNDS_PY"'
import fcntl
import os
import sys
import time

(ledger, task, spawn_gen, project, pr, repo, branch, since, database, reason) = sys.argv[1:]


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def read_runs():
    with closing(connect(database)) as db:
        repo_rows = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchall()
        if len(repo_rows) != 1:
            raise ValueError("no repository %s" % repo)
        runs = db.execute(
            "SELECT id, status, created_at FROM runs WHERE repo_id = ? AND branch = ? AND created_at >= ? "
            "ORDER BY created_at, id",
            (repo_rows[0]["id"], branch, int(since) if since else 0),
        ).fetchall()
        return [{"id": run["id"], "status": run["status"], "created_at": utc(run["created_at"]),
                 "steps": [{k: s[k] for k in ("step", "fix_rounds", "by_worker", "by_pipeline")}
                           for s in run_steps(db, run["id"])]}
                for run in runs]


record = {
    "task": task, "spawn_gen": spawn_gen or None, "project": project or None, "pr": pr or None,
    "recorded_at": utc(time.time()), "source": "no-mistakes-state", "reason": None,
    "repo": repo or None, "branch": branch or None, "since": utc(int(since)) if since else None,
}
runs = []
if not reason:
    try:
        runs = read_runs()
    except (ValueError, OSError, sqlite3.Error) as err:
        reason = "cannot read no-mistakes state: %s" % err
if reason:
    record.update(source="unavailable", reason=reason, runs=[], rounds_to_pass=None)
else:
    passed = [run for run in runs if run["status"] == "completed"]
    if passed:
        steps = [{"step": s["step"], "fix_rounds": s["fix_rounds"]} for s in passed[-1]["steps"] if s["fix_rounds"]]
        rounds = {"run": passed[-1]["id"], "total": sum(s["fix_rounds"] for s in steps),
                  "max": max([s["fix_rounds"] for s in steps] or [0]), "steps": steps}
    else:
        rounds = {"run": None, "total": None, "max": None, "steps": []}
    record.update(runs=runs, rounds_to_pass=rounds)
line = json.dumps(record, separators=(",", ":"))

try:
    fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        content = f.read()
        for existing in content.splitlines():
            try:
                row = json.loads(existing)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("task") == task and row.get("spawn_gen") == record["spawn_gen"]:
                print("already recorded %s %s" % (task, spawn_gen or "-"))
                sys.exit(0)
        f.write(("\n" if content and not content.endswith("\n") else "") + line + "\n")
        f.flush()
        os.fsync(f.fileno())
except OSError as err:
    sys.stderr.write("fm-nm-rounds: cannot write %s: %s\n" % (ledger, err))
    sys.exit(1)
print("recorded %s %s" % (task, spawn_gen or "-"))
' "$DATA/pipeline-rounds.jsonl" "$id" "$spawn_gen" "$project" "$pr" \
    "$FM_NM_ATTR_REPO" "$FM_NM_ATTR_BRANCH" "$FM_NM_ATTR_SINCE" "$FM_NM_ATTR_DB" "$FM_NM_ATTR_REASON" \
    || fail "could not build the pipeline rounds record for $id"
}

cmd_report() {
  local format=toon project='' limit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) format=json; shift ;;
      --project) [ "$#" -ge 2 ] || usage_error "--project needs a value"; project=$2; shift 2 ;;
      --limit) [ "$#" -ge 2 ] || usage_error "--limit needs a value"; limit=$2; shift 2 ;;
      *) usage_error "unknown report argument: $1" ;;
    esac
  done
  [ "$limit" = 0 ] || positive_int "$limit" || usage_error "--limit must be a positive integer"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read the rounds ledger"
  python3 - "$DATA/pipeline-rounds.jsonl" "$format" "$project" "$CAP_DEFAULT" "$limit" <<'PY' || fail "could not read the pipeline rounds ledger"
import json
import os
import re
import sys

ledger, fmt, only, cap, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
records = []
if os.path.exists(ledger):
    with open(ledger, encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("task"):
                records.append(row)
records.sort(key=lambda r: r.get("recorded_at") or "", reverse=True)

projects = {}
prs = []
for r in records:
    name = r.get("project") or "-"
    if only and name != only:
        continue
    p = projects.setdefault(name, {"project": name, "prs": 0, "fix_rounds": 0, "mean": 0,
                                   "max": 0, "at_cap": 0, "unknown": 0})
    rounds = r.get("rounds_to_pass") or {}
    if r.get("source") != "no-mistakes-state" or rounds.get("total") is None:
        p["unknown"] += 1
        continue
    p["prs"] += 1
    p["fix_rounds"] += rounds["total"]
    p["max"] = max(p["max"], rounds["max"])
    if rounds["max"] >= cap:
        p["at_cap"] += 1
    prs.append({"project": name, "task": r["task"], "pr": r.get("pr") or "-",
                "fix_rounds": rounds["total"], "max": rounds["max"],
                "steps": ",".join("%s:%d" % (s["step"], s["fix_rounds"]) for s in rounds.get("steps", [])) or "-",
                "recorded_at": r.get("recorded_at") or "-"})
for p in projects.values():
    p["mean"] = round(p["fix_rounds"] / p["prs"], 1) if p["prs"] else 0
rows = sorted(projects.values(), key=lambda p: (-p["at_cap"], -p["mean"], p["project"]))
model = {"cap": cap, "projects": rows, "prs_total": len(prs), "prs": prs[:limit] if limit else prs}
if fmt == "json":
    print(json.dumps(model, separators=(",", ":")))
    sys.exit(0)


def q(v):
    # TOON scalar quoting, matching bin/fm-bearings-snapshot.sh's renderer.
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    needs = (s == "" or s != s.strip() or s in ("true", "false", "null")
             or re.match(r"^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$", s)
             or re.search(r"[:\"\\\[\]{},]", s) or re.search(r"[\x00-\x1f]", s) or s.startswith("-"))
    if not needs:
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def table(key, items, cols):
    if not items:
        print("%s: []" % key)
        return
    print("%s[%d]{%s}:" % (key, len(items), ",".join(cols)))
    for item in items:
        print("  " + ",".join(q(item[c]) for c in cols))


print("cap: %d" % cap)
table("projects", rows, ["project", "prs", "fix_rounds", "mean", "max", "at_cap", "unknown"])
print("prs_total: %d" % len(prs))
table("prs", model["prs"], ["project", "task", "pr", "fix_rounds", "max", "steps", "recorded_at"])
PY
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  check) shift; cmd_check "$@" ;;
  record) shift; cmd_record "$@" ;;
  report) shift; cmd_report "$@" ;;
  *) usage >&2; exit 2 ;;
esac
