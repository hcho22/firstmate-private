#!/usr/bin/env bash
# Behavior tests for bin/fm-scorebook.sh through its public commands: a
# question put to the captain round-trips through ask, answer, and report; the
# match flag and the hand-off threshold count the way the header documents; a
# kind without the captain's recorded yes still reaches him; and the record
# never lands on a path a git work tree tracks. Questions carried by a task held
# for the captain run against a real backlog through bin/fm-captain-hold.sh and
# skip with a reason when tasks-axi is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fm_git_identity
SCOREBOOK="$ROOT/bin/fm-scorebook.sh"
TMP_ROOT=$(fm_test_tmproot fm-scorebook)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

score() {  # <home> <command args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$SCOREBOOK" "$@"
}

report_field() {  # <home> <kind> <field>
  score "$1" report --json | jq -r --arg k "$2" --arg f "$3" '.[] | select(.kind == $k) | .[$f]'
}

# Records <n> chat questions of <kind>, each answered with <matched>.
answer_n() {  # <home> <kind> <n> <yes|no>
  local home=$1 kind=$2 n=$3 matched=$4 i id
  i=0
  while [ "$i" -lt "$n" ]; do
    id=$(score "$home" ask --kind "$kind" --recommend "keep scope" \
      --question "question $i" --project sample) || fail "ask failed for $kind"
    score "$home" answer "$id" --matched "$matched" --answer "answer $i" \
      || fail "answer failed for $id"
    i=$((i + 1))
  done
}

test_chat_round_trip() {
  local home id out rc
  home=$(make_home round-trip)
  id=$(score "$home" ask --kind design --recommend "option A" \
    --question "Which layout?" --task sample-task --project sample) \
    || fail "ask refused a chat question"
  assert_contains "$id" "chat-" "a chat question did not get a chat id"
  out=$(score "$home" pending)
  assert_contains "$out" "$id"$'\t'"design"$'\t'"chat" "pending did not list the open chat question"
  assert_equals 1 "$(report_field "$home" design open)" "report did not count the open question"

  rc=0
  score "$home" ask --kind design --recommend "option A" --question "Which layout?" \
    --held "$id" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "ask accepted both --held and --question"
  rc=0
  score "$home" answer "$id" --matched yes >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a chat answer without the captain's words"
  rc=0
  score "$home" answer "$id" --matched maybe --answer x >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an answer with a match flag other than yes or no"

  score "$home" answer "$id" --matched no --answer "Option B instead" \
    || fail "answer refused a chat answer"
  out=$(score "$home" pending)
  assert_equals "" "$out" "an answered question is still pending"
  assert_equals 1 "$(report_field "$home" design asked)" "report lost the asked question"
  assert_equals 1 "$(report_field "$home" design answered)" "report did not count the answer"
  assert_equals 0 "$(report_field "$home" design matched)" "a mismatched answer counted as matched"
  assert_equals captain-only "$(report_field "$home" design status)" "design is not a hand-off kind"
  out=$(jq -c "select(.id == \"$id\")" "$home/data/captain-scorebook.jsonl")
  assert_contains "$out" '"recommendation":"option A"' "the record lost the recommendation"
  assert_contains "$out" '"answer":"Option B instead"' "the record lost the captain's answer"
  assert_contains "$out" '"task":"sample-task"' "the record lost the task"
  assert_contains "$out" '"project":"sample"' "the record lost the project"
  assert_contains "$out" '"matched":false' "the record lost the match flag"

  rc=0
  score "$home" answer "$id" --matched yes --answer again >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a second answer to an already answered question"
  pass "a chat question round-trips through ask, pending, answer, and report"
}

test_match_flag_and_withdraw() {
  local home id
  home=$(make_home match)
  answer_n "$home" finding-scope 3 yes
  answer_n "$home" finding-scope 2 no
  id=$(score "$home" ask --kind finding-scope --recommend r --question moot) || fail "ask failed"
  score "$home" withdraw "$id" --reason "premise was false" || fail "withdraw failed"
  assert_equals 6 "$(report_field "$home" finding-scope asked)" "asked count is wrong"
  assert_equals 5 "$(report_field "$home" finding-scope answered)" "a withdrawn question counted as answered"
  assert_equals 3 "$(report_field "$home" finding-scope matched)" "matched count is wrong"
  assert_equals 1 "$(report_field "$home" finding-scope withdrawn)" "withdrawn count is wrong"
  assert_equals 0 "$(report_field "$home" finding-scope open)" "a withdrawn question stayed open"
  pass "the match flag counts matched answers and withdrawn questions never count"
}

test_threshold() {
  local home
  home=$(make_home threshold)
  answer_n "$home" finding-design 9 yes
  assert_equals not-yet "$(report_field "$home" finding-design status)" "a kind qualified below the threshold"
  answer_n "$home" finding-design 1 yes
  assert_equals qualifies "$(report_field "$home" finding-design status)" \
    "a kind with 10 matching answers did not qualify"
  answer_n "$home" finding-design 1 no
  assert_equals not-yet "$(report_field "$home" finding-design status)" \
    "a kind still qualified with a mismatch among its 10 most recent answers"
  assert_equals 9 "$(report_field "$home" finding-design recent_matched)" "the recent window is wrong"
  answer_n "$home" finding-design 10 yes
  assert_equals qualifies "$(report_field "$home" finding-design status)" \
    "a kind did not qualify again once the mismatch left the recent window"
  answer_n "$home" merge 10 yes
  assert_equals captain-only "$(report_field "$home" merge status)" \
    "a captain-only kind qualified for hand-off"
  assert_contains "$(score "$home" report)" "qualifies at 10 answered questions" \
    "the text report does not state the threshold"
  pass "a hand-off kind qualifies only with 10 recent answers all matched"
}

test_grant_requires_captain_yes() {
  local home rc
  home=$(make_home grant)
  answer_n "$home" finding-repeat 10 yes
  assert_equals qualifies "$(report_field "$home" finding-repeat status)" "fixture did not qualify"
  rc=0
  score "$home" granted finding-repeat || rc=$?
  expect_code 1 "$rc" "a qualifying kind without the captain's recorded yes was granted"

  rc=0
  score "$home" grant finding-repeat >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "grant without the captain's words"
  : > "$home/empty.txt"
  rc=0
  score "$home" grant finding-repeat --captain-words-file "$home/empty.txt" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "grant with an empty captain words file"
  rc=0
  score "$home" granted finding-repeat || rc=$?
  expect_code 1 "$rc" "a refused grant still granted the kind"

  printf 'Yes, decide repeated findings yourself.\n' > "$home/yes.txt"
  rc=0
  score "$home" grant destructive --captain-words-file "$home/yes.txt" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "grant of a captain-only kind"
  printf '{"event":"grant","at":"2026-01-01T00:00:00Z","kind":"merge","captain_words":"x"}\n' \
    >> "$home/data/captain-scorebook.jsonl"
  rc=0
  score "$home" granted merge || rc=$?
  expect_code 1 "$rc" "a captain-only kind read as granted from a hand-written record"

  score "$home" grant finding-repeat --captain-words-file "$home/yes.txt" || fail "grant refused the captain's yes"
  score "$home" granted finding-repeat || fail "a kind with the captain's recorded yes is not granted"
  assert_equals granted "$(report_field "$home" finding-repeat status)" "report does not show the grant"
  assert_grep 'Yes, decide repeated findings yourself.' "$home/data/captain-scorebook.jsonl" \
    "grant did not record the captain's words"
  rc=0
  score "$home" granted finding-scope || rc=$?
  expect_code 1 "$rc" "a grant for one kind granted another"

  score "$home" revoke finding-repeat --reason "captain asked to see these again" || fail "revoke failed"
  rc=0
  score "$home" granted finding-repeat || rc=$?
  expect_code 1 "$rc" "a revoked kind is still granted"
  rc=0
  score "$home" granted not-a-kind 2>/dev/null || rc=$?
  expect_code 2 "$rc" "granted with an unknown kind"
  pass "a kind is firstmate's to decide only after the captain's recorded yes"
}

test_record_stays_off_tracked_paths() {
  local repo home rc
  repo="$TMP_ROOT/tracked-repo"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/data" "$repo/state"
  rc=0
  FM_HOME="$repo" "$SCOREBOOK" ask --kind other --recommend r --question q >/dev/null 2>"$repo.err" || rc=$?
  expect_code 1 "$rc" "ask wrote into a data directory a git work tree tracks"
  assert_absent "$repo/data/captain-scorebook.jsonl" "a refused ask still wrote the record"
  assert_grep "not ignored" "$repo.err" "the refusal does not say why"

  home="$TMP_ROOT/ignored-home"
  fm_git_init_commit "$home"
  mkdir -p "$home/data" "$home/state"
  printf 'data/\nstate/\n' > "$home/.gitignore"
  git -C "$home" add .gitignore && git -C "$home" commit -qm ignore
  FM_HOME="$home" "$SCOREBOOK" ask --kind other --recommend r --question q >/dev/null \
    || fail "ask refused an ignored data directory"
  assert_present "$home/data/captain-scorebook.jsonl" "ask did not write the record"
  assert_equals "" "$(git -C "$home" status --porcelain)" "the record left a tracked or untracked change"
  pass "the record is written only where git ignores it"
}

test_held_questions_reuse_hold_records() {
  local home fakebin id rc
  if [ -z "$TASKS_AXI_BIN" ]; then
    echo "skip: tasks-axi not found; held-question cases need a real backlog"
    return 0
  fi
  home=$(make_home held)
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_shared_stub_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  captain() {
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
  }
  heldscore() {
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" score "$home" "$@"
  }

  rc=0
  heldscore ask --kind finding-design --recommend "keep the queue" --held sample-call \
    >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "ask --held accepted a task that is not held for the captain"

  captain hold sample-call --title "Pick the queue shape" \
    --reason "captain picks the queue shape" --repo sample >/dev/null || fail "could not hold the fixture task"
  id=$(heldscore ask --kind finding-design --recommend "keep the queue" --held sample-call --project sample) \
    || fail "ask --held refused an open captain call"
  assert_equals sample-call "$id" "a held question's id is not its task id"
  assert_no_grep '"question"' "$home/data/captain-scorebook.jsonl" \
    "a held question copied the hold reason into the record"
  rc=0
  heldscore ask --kind finding-design --recommend again --held sample-call >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a second open question on the same held task"

  rc=0
  heldscore answer sample-call --matched yes >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "answer recorded before the captain's words were on the task"
  printf 'Keep the queue.\n' > "$home/decision.txt"
  captain answer sample-call --decision-file "$home/decision.txt" >/dev/null || fail "captain-hold answer failed"
  rc=0
  heldscore answer sample-call --matched yes --answer "Keep the queue." >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a held answer copied the captain's words into the record"
  heldscore answer sample-call --matched yes || fail "answer refused a held question the captain answered"
  assert_equals 1 "$(report_field "$home" finding-design matched)" "the held answer did not count"
  assert_no_grep 'Keep the queue.' "$home/data/captain-scorebook.jsonl" \
    "the captain's words were written twice"
  pass "a held question reuses the hold reason and the recorded answer"
}

test_unknown_kind_and_help() {
  local home rc
  home=$(make_home usage)
  rc=0
  score "$home" ask --kind nonsense --recommend r --question q >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "ask accepted an unknown kind"
  assert_contains "$(score "$home" kinds)" "finding-scope"$'\t'"hand-off" "kinds does not mark hand-off kinds"
  assert_contains "$(score "$home" kinds)" "credential"$'\t'"captain-only" "kinds does not mark captain-only kinds"
  assert_contains "$(score "$home" --help)" "fm-scorebook.sh report" "help does not show usage"
  assert_absent "$home/data/captain-scorebook.jsonl" "a refused or read-only command wrote the record"
  pass "unknown kinds are refused and read-only commands write nothing"
}

test_chat_round_trip
test_match_flag_and_withdraw
test_threshold
test_grant_requires_captain_yes
test_record_stays_off_tracked_paths
test_held_questions_reuse_hold_records
test_unknown_kind_and_help
