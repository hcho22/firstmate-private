#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-rounds.sh through its public commands: check
# holds a driving worker to the fix-round cap on one step of the current
# branch's run, record keeps a finished task's rounds to pass in
# data/pipeline-rounds.jsonl, and report lists those rounds per PR by project.
# Each case seeds a real SQLite state database shaped like no-mistakes' own
# (repos, runs, step_results, step_rounds) under a private NM_HOME, and a fake
# no-mistakes CLI that answers `axi status` with the current branch's run and
# `axi` with the resolved repository.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-nm-rounds)
ROUNDS="$ROOT/bin/fm-nm-rounds.sh"
NOW=$(date +%s)
BRANCH_EPOCH=$((NOW - 100000))

# make_case <name>: echo a case dir holding a Firstmate home (home/state,
# home/data), a project clone, a task copy (wt) on branch fm/task created at
# BRANCH_EPOCH, the task's meta, an NM_HOME (nm), and a fake no-mistakes whose
# `axi status` names run FAKE_NM_RUN (no run block when it is empty) and whose
# `axi` prints `repo: <project>`.
make_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/nm" "$d/fakebin" "$d/out"
  fm_git_init_commit "$d/project"
  GIT_COMMITTER_DATE="@$BRANCH_EPOCH +0000" git -C "$d/project" worktree add -q -b fm/task "$d/wt"
  fm_write_meta "$d/home/state/task.meta" \
    "worktree=$d/wt" \
    "project=$d/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=s1" \
    "pr=https://example.invalid/acme/project/pull/9"
  cat > "$d/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
case "\$*" in
  axi) printf 'repo: %s\ncurrent_branch: fm/task\n' '$d/project' ;;
  'axi status')
    if [ -n "\${FAKE_NM_RUN:-}" ]; then
      printf 'current_branch: fm/task\nrun:\n  id: "%s"\n  branch: fm/task\n  status: running\n' "\$FAKE_NM_RUN"
    else
      printf 'current_branch: fm/task\nother_branch_run:\n  id: "OTHER"\n'
    fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/fakebin/no-mistakes"
  printf '%s\n' "$d"
}

# seed_db <case-dir>: build nm/state.sqlite from stdin rows, times given as
# offsets from BRANCH_EPOCH and "-" meaning NULL:
#   repo <id> <working_path>
#   run <id> <repo-id> <branch> <status> <created-offset>
#   round <run-id> <step> <round> <initial|auto_fix> <selection_source> <finding-ids,...>
seed_db() {
  SEED_ROWS=$(cat) python3 - "$1/nm/state.sqlite" "$BRANCH_EPOCH" <<'PY'
import json
import os
import sqlite3
import sys

database, base = sys.argv[1], int(sys.argv[2])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
                               step_order INTEGER NOT NULL);
    CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
                              trigger_type TEXT NOT NULL, findings_json TEXT, selection_source TEXT);
""")
order = {"review": 3, "test": 4, "document": 5}
for n, line in enumerate(os.environ["SEED_ROWS"].splitlines()):
    f = line.split()
    if not f:
        continue
    if f[0] == "repo":
        db.execute("INSERT INTO repos VALUES (?, ?)", (f[1], f[2]))
    elif f[0] == "run":
        db.execute("INSERT INTO runs VALUES (?, ?, ?, ?, ?)", (f[1], f[2], f[3], f[4], base + int(f[5])))
    elif f[0] == "round":
        step_id = "%s-%s" % (f[1], f[2])
        db.execute("INSERT OR IGNORE INTO step_results VALUES (?, ?, ?, ?)", (step_id, f[1], f[2], order[f[2]]))
        findings = [{"id": i, "severity": "warning", "file": "src/a.go", "line": 3, "action": "auto-fix",
                     "description": "finding %s" % i} for i in f[6].split(",") if i != "-"]
        db.execute("INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?)",
                   ("r%03d" % n, step_id, int(f[3]), f[4], json.dumps({"findings": findings}),
                    None if f[5] == "-" else f[5]))
db.commit()
PY
}

# rounds <case-dir> <args...>: run the script from the case's task copy
# against its home, NM_HOME, and fake no-mistakes.
rounds() {
  local d=$1
  shift
  ( cd "$d/wt" && env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$d/home" NM_HOME="$d/nm" \
      PATH="$d/fakebin:$PATH" "$ROUNDS" "$@" )
}

value() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

test_three_fix_rounds_on_one_step_reach_the_cap_and_escalate() {
  local d out rc=0 file
  d=$(make_case three)
  seed_db "$d" <<EOF
repo r1 $d/project
run run3 r1 fm/task running 10
round run3 review 1 initial user review-1,review-2
round run3 review 2 auto_fix user r2-1,review-2
round run3 review 3 auto_fix auto_fix r3-1
round run3 review 4 auto_fix user r4-1,review-2
round run3 test 1 initial - -
EOF
  out=$(FAKE_NM_RUN=run3 rounds "$d" check --step review --out-dir "$d/out") || rc=$?
  [ "$rc" -eq 3 ] || fail "three rounds: check exited $rc, not 3: $out"
  [ "$(value "$out" verdict)" = cap-reached ] || fail "three rounds: verdict is not cap-reached: $out"
  [ "$(value "$out" fix_rounds)" = 3 ] \
    || fail "three rounds: worker and pipeline fix rounds are not all counted: $out"
  [ "$(value "$out" findings)" = r4-1,review-2 ] || fail "three rounds: current findings are wrong: $out"
  [ "$(value "$out" returning)" = review-2 ] || fail "three rounds: the returning finding is not named: $out"
  file=$(value "$out" file)
  [ "$file" = "$d/out/nm-run3-review-rounds.txt" ] || fail "three rounds: wrong history file: $out"
  grep -q '^## round 1 (initial)$' "$file" || fail "three rounds: history lacks the initial round: $(cat "$file")"
  grep -q '^## round 4 (fix)$' "$file" || fail "three rounds: history lacks a fix round: $(cat "$file")"
  grep -q 'seen_in_rounds: 1,2,4' "$file" || fail "three rounds: history lacks the recurrence: $(cat "$file")"
  grep -q '    finding r2-1' "$file" || fail "three rounds: history lacks a verbatim finding: $(cat "$file")"
  printf '%s\n' "$(value "$out" escalation)" | grep -Eq \
    "^needs-decision \[at=[0-9]+\] \[key=nm-run3-review\]: fix-round cap rounds=3 findings=r4-1,review-2 file=$d/out/nm-run3-review-rounds.txt$" \
    || fail "three rounds: escalation line is not the keyed needs-decision shape: $out"
  pass "three fix rounds on one step reach the cap and print the keyed escalation"
}

test_two_fix_rounds_stay_under_the_cap() {
  local d out rc=0
  d=$(make_case two)
  seed_db "$d" <<EOF
repo r1 $d/project
run run2 r1 fm/task running 10
round run2 review 1 initial user review-1
round run2 review 2 auto_fix user r2-1
round run2 review 3 auto_fix user r3-1
round run2 document 1 initial - -
round run2 document 2 auto_fix auto_fix -
EOF
  out=$(FAKE_NM_RUN=run2 rounds "$d" check --step review --out-dir "$d/out") || rc=$?
  [ "$rc" -eq 0 ] || fail "two rounds: check exited $rc, not 0: $out"
  [ "$(value "$out" verdict)" = under-cap ] || fail "two rounds: verdict is not under-cap: $out"
  [ "$(value "$out" fix_rounds)" = 2 ] || fail "two rounds: fix_rounds is not 2: $out"
  [ -z "$(value "$out" escalation)" ] || fail "two rounds: an under-cap check printed an escalation: $out"
  [ -z "$(find "$d/out" -type f)" ] || fail "two rounds: an under-cap check wrote a history file"
  pass "two fix rounds on one step stay under the cap and escalate nothing"
}

test_a_raised_cap_lets_more_rounds_through() {
  local d out rc=0
  d=$(make_case raised)
  seed_db "$d" <<EOF
repo r1 $d/project
run run4 r1 fm/task running 10
round run4 review 1 initial user a
round run4 review 2 auto_fix user b
round run4 review 3 auto_fix user c
round run4 review 4 auto_fix user d
EOF
  out=$(FAKE_NM_RUN=run4 rounds "$d" check --step review --cap 5) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(value "$out" verdict)" = under-cap ] \
    || fail "raised cap: three rounds under a cap of 5 did not pass (exit $rc): $out"
  rc=0
  out=$(FAKE_NM_RUN=run4 rounds "$d" check --step review) || rc=$?
  [ "$rc" -eq 3 ] || fail "raised cap: the default cap did not apply without --cap: $out"
  printf '%s\n' "$(value "$out" escalation)" | grep -q 'rounds=3 findings=d$' \
    || fail "raised cap: an escalation without --out-dir must carry no file: $out"
  pass "a cap raised by --cap lets more rounds through, and the default stays 3"
}

test_an_uncountable_step_is_unknown_not_under_cap() {
  local d out rc=0
  d=$(make_case unknown)
  seed_db "$d" <<EOF
repo r1 $d/project
run run5 r1 fm/task running 10
round run5 review 1 initial user a
EOF
  out=$(FAKE_NM_RUN='' rounds "$d" check --step review) || rc=$?
  [ "$rc" -eq 1 ] && [ "$(value "$out" verdict)" = unknown ] \
    || fail "unknown: a branch with no run did not read as unknown (exit $rc): $out"
  value "$out" reason | grep -q 'no run on the current branch' \
    || fail "unknown: the reason does not name the missing run: $out"
  rc=0
  out=$(FAKE_NM_RUN=run5 rounds "$d" check --step test) || rc=$?
  [ "$rc" -eq 1 ] && [ "$(value "$out" verdict)" = unknown ] \
    || fail "unknown: a step with no recorded round did not read as unknown (exit $rc): $out"
  rm -f "$d/nm/state.sqlite"
  rc=0
  out=$(FAKE_NM_RUN=run5 rounds "$d" check --step review) || rc=$?
  [ "$rc" -eq 1 ] || fail "unknown: a missing database did not read as unknown (exit $rc): $out"
  value "$out" reason | grep -q 'no state database' \
    || fail "unknown: a missing database is not named as the reason: $out"
  [ ! -e "$d/nm/state.sqlite" ] || fail "unknown: the check created a state database"
  rc=0
  rounds "$d" check --step 'bad step' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown: an invalid step name was not a usage error (exit $rc)"
  pass "an uncountable step reads as unknown rather than under the cap"
}

test_record_counts_every_run_of_the_task_once_per_incarnation() {
  local d out ledger json
  d=$(make_case record)
  seed_db "$d" <<EOF
repo r1 $d/project
run early r1 fm/task completed -500
run failed1 r1 fm/task failed 100
run passed1 r1 fm/task completed 200
run sibling r1 fm/other completed 300
round early review 1 initial user a
round early review 2 auto_fix user b
round failed1 review 1 initial user a
round failed1 review 2 auto_fix user b
round failed1 review 3 auto_fix user c
round failed1 review 4 auto_fix user d
round passed1 review 1 initial user a
round passed1 review 2 auto_fix user b
round passed1 test 1 initial auto_fix -
round passed1 test 2 auto_fix - -
round passed1 document 1 initial - -
EOF
  out=$(rounds "$d" record task)
  [ "$out" = "recorded task s1" ] || fail "record: unexpected output: $out"
  ledger=$d/home/data/pipeline-rounds.jsonl
  jq -e --arg project "$(basename "$d/project")" '
    .task == "task" and .spawn_gen == "s1" and .project == $project
    and .pr == "https://example.invalid/acme/project/pull/9"
    and .source == "no-mistakes-state" and .branch == "fm/task"
    and [.runs[].id] == ["failed1", "passed1"]
    and (.runs[0].steps[] | select(.step == "review") | .fix_rounds) == 3
    and .rounds_to_pass == {"total": 5, "max": 3,
                            "steps": [{"step": "review", "fix_rounds": 4}, {"step": "test", "fix_rounds": 1}]}
  ' "$ledger" >/dev/null || fail "record: the recorded rounds are wrong: $(cat "$ledger")"
  json=$(rounds "$d" report --json)
  printf '%s\n' "$json" | jq -e '
    .projects[0].at_cap == 1 and .projects[0].max == 3
    and .prs == [{"project": .projects[0].project, "task": "task", "pr": "https://example.invalid/acme/project/pull/9",
                  "fix_rounds": 5, "max": 3, "steps": "review:4,test:1", "recorded_at": .prs[0].recorded_at}]
  ' >/dev/null || fail "record: the PR does not report the cap its earlier run reached: $json"
  out=$(rounds "$d" record task)
  [ "$out" = "already recorded task s1" ] || fail "record: a repeat was not deduplicated: $out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] || fail "record: a repeat appended a second line"
  pass "record counts the fix rounds of every run the task had, once per incarnation"
}

test_record_without_a_run_or_source_is_explicit() {
  local d ledger
  d=$(make_case record-unknown)
  seed_db "$d" <<EOF
repo r1 $d/project
run early r1 fm/task completed -500
run sibling r1 fm/other completed 100
round early review 1 initial user a
EOF
  rounds "$d" record task >/dev/null
  ledger=$d/home/data/pipeline-rounds.jsonl
  jq -e '.runs == [] and .rounds_to_pass == {"total": null, "max": null, "steps": []}' "$ledger" >/dev/null \
    || fail "record-unknown: a task with no run claimed rounds to pass: $(cat "$ledger")"
  rm -f "$ledger" "$d/nm/state.sqlite"
  rounds "$d" record task >/dev/null
  jq -e '.source == "unavailable" and .rounds_to_pass == null and (.reason | contains("no state database"))' \
    "$ledger" >/dev/null || fail "record-unknown: an unreadable source was not recorded as unavailable: $(cat "$ledger")"
  pass "record states a task with no run or an unreadable source instead of guessing"
}

test_report_lists_rounds_per_pr_by_project() {
  local d out json
  d=$(make_case report)
  cat > "$d/home/data/pipeline-rounds.jsonl" <<'EOF'
{"task":"calm-1","spawn_gen":"g","project":"Calm","pr":"https://example.invalid/o/calm/pull/1","recorded_at":"2026-10-01T00:00:00Z","source":"no-mistakes-state","runs":[],"rounds_to_pass":{"total":1,"max":1,"steps":[{"step":"review","fix_rounds":1}]}}
{"task":"churn-1","spawn_gen":"g","project":"Churn","pr":"https://example.invalid/o/churn/pull/1","recorded_at":"2026-10-02T00:00:00Z","source":"no-mistakes-state","runs":[],"rounds_to_pass":{"total":5,"max":4,"steps":[{"step":"review","fix_rounds":4},{"step":"test","fix_rounds":1}]}}
{"task":"churn-2","spawn_gen":"g","project":"Churn","pr":"https://example.invalid/o/churn/pull/2","recorded_at":"2026-10-03T00:00:00Z","source":"no-mistakes-state","runs":[],"rounds_to_pass":{"total":1,"max":1,"steps":[{"step":"review","fix_rounds":1}]}}
{"task":"churn-3","spawn_gen":"g","project":"Churn","pr":null,"recorded_at":"2026-10-04T00:00:00Z","source":"unavailable","runs":[],"rounds_to_pass":null}
not json
EOF
  json=$(rounds "$d" report --json)
  printf '%s\n' "$json" | jq -e '
    .cap == 3
    and [.projects[].project] == ["Churn", "Calm"]
    and .projects[0] == {"project":"Churn","prs":2,"fix_rounds":6,"mean":3.0,"max":4,"at_cap":1,"unknown":1}
    and .prs_total == 3 and [.prs[].task] == ["churn-2", "churn-1", "calm-1"]
    and (.prs[] | select(.task == "churn-1") | .steps) == "review:4,test:1"
  ' >/dev/null || fail "report: the by-project view is wrong: $json"
  json=$(rounds "$d" report --json --limit 1)
  printf '%s\n' "$json" | jq -e '.prs_total == 3 and [.prs[].task] == ["churn-2"] and (.projects | length) == 2' \
    >/dev/null || fail "report: --limit did not keep only the newest PR rows: $json"
  out=$(rounds "$d" report)
  printf '%s\n' "$out" | grep -qx 'projects\[2\]{project,prs,fix_rounds,mean,max,at_cap,unknown}:' \
    || fail "report: the TOON projects table is missing: $out"
  printf '%s\n' "$out" | grep -qx '  Churn,2,6,3.0,4,1,1' || fail "report: the TOON project row is wrong: $out"
  printf '%s\n' "$out" | grep -q '"review:4,test:1"' || fail "report: a TOON value with commas is not quoted: $out"
  rm -f "$d/home/data/pipeline-rounds.jsonl"
  json=$(rounds "$d" report --json)
  [ "$json" = '{"cap":3,"projects":[],"prs_total":0,"prs":[]}' ] || fail "report: an absent ledger is not an empty view: $json"
  pass "report lists rounds per PR by project, churning projects first"
}

test_three_fix_rounds_on_one_step_reach_the_cap_and_escalate
test_two_fix_rounds_stay_under_the_cap
test_a_raised_cap_lets_more_rounds_through
test_an_uncountable_step_is_unknown_not_under_cap
test_record_counts_every_run_of_the_task_once_per_incarnation
test_record_without_a_run_or_source_is_explicit
test_report_lists_rounds_per_pr_by_project
