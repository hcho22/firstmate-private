#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, release and deferral, out-of-band closes, and routing between main
# and secondmate homes. tests/fm-captain-hold-records.test.sh covers captured
# answer channels, legacy decision identities, the record-divergence guard, and
# cleanup; the two share tests/captain-hold-helpers.sh.
set -u

# shellcheck source=tests/captain-hold-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_shared_stub_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_shared_stub_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    "$channel" "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    "$channel" "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    "$channel" "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    "$channel" "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    "$channel" "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
