#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate and the origin
# inventory it attests, its recorded answers and hold age, release and deferral,
# out-of-band closes, the merge entrypoints' refusal of captain-held work, the
# hold reason's round trip, and routing between main and secondmate homes.
# tests/fm-captain-hold-records.test.sh covers captured answer channels and
# reconcile requests, legacy and Beads-migrated identities, the record-divergence
# guard, and cleanup; the two share tests/captain-hold-helpers.sh.
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
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/$id.status" | grep -F 'captain-held [key=route]: tracked by sample-route-call' >/dev/null \
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
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
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
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

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

# The hold-set stamp must be durable before the captain hold becomes visible.
# A wrapper observes the real tasks-axi hold boundary, and a forced stamp-write
# failure proves the command never publishes the hold without its timestamp.
test_hold_stamp_precedes_hold_visibility() {
  local home show
  home=$(make_home hold-stamp-order)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-old-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)
- [ ] sample-stamp-failure - Existing task whose stamp fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  fm_shared_stub "$home/fakebin" "tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = sample-stamp-failure ]; then
  exit 92
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-old-call ]; then
  show=$("$REAL_TASKS_AXI" show "$2" --full) || exit 93
  printf '%s\n' "$show" | grep -F 'Captain hold set: 2026-07-14T12:00:00Z' >/dev/null || exit 94
  : > "$FM_HOME/hold-observed-after-stamp"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF

  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-old-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "hold was published before its hold-set stamp"
  assert_present "$home/hold-observed-after-stamp" \
    "the tasks-axi hold boundary was not observed"
  show=$(tasks_in "$home" show sample-old-call --full)
  assert_contains "$show" "hold_kind: captain" "the stamped task was not captain-held"
  assert_contains "$show" "Captain hold set: 2026-07-14T12:00:00Z" \
    "the visible captain hold lost its timestamp"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-stamp-failure \
    --reason "captain route choice pending" > "$home/stamp-failure.out" 2> "$home/stamp-failure.err"; then
    fail "hold succeeded after its timestamp update failed"
  fi
  show=$(tasks_in "$home" show sample-stamp-failure --full)
  assert_contains "$show" "held: no" "a failed timestamp update still published the hold"
  assert_contains "$show" 'hold_kind: "-"' "a failed timestamp update retained captain-hold provenance"
  pass "captain holds become visible only after their hold-set timestamp is durable"
}

test_interrupted_answer_preserves_hold_age() {
  local home snap show
  home=$(make_home interrupted-answer-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-interrupted-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-interrupted-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the interrupted-answer fixture"
  printf 'Not urgent in the historical answer.\n' > "$home/interrupted-answer.txt"
  mkdir -p "$home/at-close"
  fm_shared_stub "$home/fakebin" "tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/close-failed-once" ]; then
  cp "$FM_HOME/data/backlog.md" "$FM_HOME/at-close/backlog.md" || exit 93
  : > "$FM_HOME/close-failed-once"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = done ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the forced answer close failure reported success"
  fi
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/at-close" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at interrupted close boundary"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-interrupted-call")
    | .captain_actionable == true
      and .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "an interrupted answer lost the fresh hold age basis: $snap"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/normalize.out" 2> "$home/normalize.err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" "state: done" "the normalization failure undid the successful close"
  run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the closed answer could not normalize on retry"
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" 'body: "Resolution recorded by fm-captain-hold.' \
    "the matching done retry did not restore resolution-first body ordering"
  pass "an interrupted answer preserves its hold age until close retry"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-existing-call - Decide an existing sample task (repo: sample) (kind: captain) (since 2026-06-01)
- [ ] sample-near-marker - Decide a deferred sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  Captain hold set: 2026-07-14T12:00:00Z
  abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij DEFERRED
- [ ] sample-late-marker - Decide a documented sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  This deliberately long decision context fills the bounded display excerpt without changing the durable classification contract. Additional synthetic context keeps extending the body beyond that display boundary while remaining ordinary task prose. More synthetic context places the presentation marker after the excerpt cutoff. DEFERRED

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not hold the existing task"
  FM_CAPTAIN_HOLD_NOW=2026-07-20T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not repeat the existing task hold"
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
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and $existing.since == "2026-06-01" and $existing.hold_set == "2026-07-14T12:00:00Z"
      and $existing.hold_age_days == 0 and $existing.hold_bucket == "live"
      and ([.backlog.records[] | select(.id == "sample-near-marker")][0].hold_bucket == "live")
      and ([.backlog.records[] | select(.id == "sample-late-marker")][0].hold_bucket == "live")
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate, hold-set age, or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-existing-call"))
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
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == true
      and $existing.hold_age_days == 18 and $existing.hold_bucket == "aged"
  ' >/dev/null || fail "a due deferral did not resurface or a stamped hold did not age from its hold date"
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
  printf 'blocked [key=access]: waiting\ndone: report complete\nnote: cleanup complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "the shared fold retained a pre-terminal blocker"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  printf 'blocked [key=access]: reopened\nnote: more cleanup\n' >> "$home/state/$id.status"
  if run_captain "$home" complete "$id" --none > "$home/reopened.out" 2> "$home/reopened.err"; then
    fail "completion accepted a genuinely reopened post-terminal decision"
  fi
  if run_captain "$home" verify "$id" > "$home/reopened-verify.out" 2> "$home/reopened-verify.err"; then
    fail "verification accepted a genuinely reopened post-terminal decision"
  fi
  printf 'resolved [key=access]: answered\nfailed: investigation ended\nnote: final cleanup\n' >> "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null || fail "resolved reopening blocked completion"
  run_captain "$home" verify "$id" >/dev/null || fail "resolved reopening blocked verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'blocked [key=route]: waiting\ndone: heartbeat complete\nnote: cleanup complete\n' \
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
  fm_test_tasks_toml "$mate/.tasks.toml"
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
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\] \\[at=[0-9]+\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
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
  fm_test_tasks_toml "$mate/.tasks.toml"
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
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the closing answer did not close the second parent decision"
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

test_secondmate_reconcile_publishes_before_request_retirement() {
  local parent mate channel evidence out show rc request
  parent=$(make_home reconcile-parent-channel)
  mate=$(make_home reconcile-channel-mate)
  printf 'reconcile-channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  channel="$parent/state/reconcile-channel-mate.status"
  evidence="$mate/reconcile-evidence.txt"

  tasks_in "$mate" add reconcile-channel-call "Verify the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the reconcile channel call"
  run_captain "$mate" hold reconcile-channel-call --reason "verify current release state" >/dev/null \
    || fail "could not hold the reconcile channel call"
  request_reconciles "$mate" reconcile-board reconcile-channel-call \
    || fail "could not request the channel reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  request="$mate/state/reconcile-requests/reconcile-channel-call.request"

  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" reconcile close reconcile-channel-call \
    --evidence-file "$evidence" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed reconcile request retirement reported success"
  assert_contains "$out" "reconcile-channel-call" \
    "the reconcile retirement failure did not name its task: $out"
  show=$(tasks_in "$mate" show reconcile-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the reconciled close"
  assert_contains "$show" "Resolution mode: reconciled" \
    "request retirement failure lost the reconciled resolution mode"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the parent resolution was not published before retirement failed: $(cat "$channel")"

  run_captain "$mate" reconcile close reconcile-channel-call --evidence-file "$evidence" >/dev/null \
    || fail "the closed reconciliation could not finish publication and retirement"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the reconciliation retry duplicated or changed its parent resolution: $(cat "$channel")"
  tasks_in "$mate" add answer-channel-call "Answer the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the normal-answer channel call"
  run_captain "$mate" hold answer-channel-call --reason "captain answer needed" >/dev/null \
    || fail "could not hold the normal-answer channel call"
  request_reconciles "$mate" reconcile-board answer-channel-call \
    || fail "could not create the normal-answer retry trigger"
  printf 'Proceed with the release.\n' > "$mate/answer.txt"
  request="$mate/state/reconcile-requests/answer-channel-call.request"
  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed normal-answer request retirement reported success"
  show=$(tasks_in "$mate" show answer-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the captain answer"
  [ -f "$request" ] || fail "the normal-answer retry trigger retired after its forced failure"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal answer did not publish before retirement failed: $(cat "$channel")"
  run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" >/dev/null \
    || fail "the normal-answer retry could not finish request retirement"
  [ ! -e "$request" ] || fail "the normal-answer retry left its request pending"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal-answer retry duplicated its parent resolution: $(cat "$channel")"
  pass "secondmate resolutions publish before retiring durable retry triggers"
}

test_merge_approval_releases_before_zero_done_retention() {
  local home id archive repo wt pr show
  home=$(make_home zero-done-retention)
  id=sample-zero-retention-merge
  archive="$home/data/done-archive.md"
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  pr="https://github.com/sample/sample/pull/19"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/done-archive.md"' \
    'done_keep = 0' > "$home/.tasks.toml"
  fm_git_worktree "$repo" "$wt" fm/zero-retention-merge
  tasks_in "$home" add "$id" "Ship zero-retention merge $pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the zero-retention fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the zero-retention merge"
  printf 'Merge the approved change.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved zero-retention merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge row disappeared"
  assert_contains "$show" "state: in_flight" \
    "merge approval completed the zero-retention row before landing"
  assert_contains "$show" "Resolution mode: released" \
    "merge approval did not record the existing release mode"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "zero-retention cleanup failed: $(cat "$home/teardown.err")"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "zero-retention cleanup kept the completed row in the active backlog"
  assert_grep "$id" "$archive" "zero-retention cleanup did not archive the completed row"
  assert_grep "$pr" "$archive" "zero-retention archival lost the merged pull request"
  assert_grep "Merge the approved change." "$archive" \
    "zero-retention archival lost the recorded merge approval"
  assert_absent "$home/state/$id.meta" "zero-retention cleanup retained task metadata"
  assert_absent "$home/state/$id.backlog-close" \
    "zero-retention cleanup retained its pending close record"
  pass "merge approval releases before zero-retention cleanup records completion"
}

test_pr_merge_entrypoint_refuses_a_captain_held_task() {
  local home pr_id pr repo wt rc
  home=$(make_home held-merge-entrypoints)
  configure_merged_github "$home"

  pr_id=sample-held-pr-entrypoint
  pr=https://github.com/sample/sample/pull/31
  repo="$home/projects/sample-pr"
  wt="$home/projects/$pr_id"
  fm_git_worktree "$repo" "$wt" "fm/$pr_id"
  tasks_in "$home" add "$pr_id" "Ship the held pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held PR fixture"
  fm_write_meta "$home/state/$pr_id.meta" \
    "window=firstmate:fm-$pr_id" "endpoint_task_id=$pr_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$pr_id"
  run_captain "$home" hold "$pr_id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR entrypoint fixture"

  # Without the entrypoint guard, this run reaches gh and returns success even
  # though the task is still held for the captain.
  set +e
  run_pr_merge "$home" "$pr_id" "$pr" > "$home/pr.out" 2> "$home/pr.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted a still-held task"
  assert_no_grep 'pr merge 31 ' "$home/gh.log" \
    "the PR merge entrypoint reached the irreversible forge call for a held task"
  assert_grep "$pr_id is still held for the captain" "$home/pr.err" \
    "the PR merge refusal did not name the held task"
  assert_absent "$home/state/.control-$pr_id.lock" \
    "the refused PR merge left its task control lock held"
  pass "the PR merge entrypoint refuses a captain-held task before merging"
}

test_local_merge_entrypoint_refuses_a_captain_held_task() {
  local home local_id local_repo local_wt before after rc
  home=$(make_home held-local-merge-entrypoint)
  local_id=sample-held-local-entrypoint
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'held local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'held local delivery'
  tasks_in "$home" add "$local_id" "Ship the held local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the local entrypoint fixture"
  before=$(git -C "$local_repo" rev-parse main)

  # Without the entrypoint guard, this run fast-forwards main while the task
  # still carries the captain hold.
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local.out" 2> "$home/local.err"
  rc=$?
  set -e
  after=$(git -C "$local_repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted a still-held task"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main for a held task"
  assert_grep "$local_id is still held for the captain" "$home/local.err" \
    "the local merge refusal did not name the held task"
  assert_absent "$home/state/.control-$local_id.lock" \
    "the refused local merge left its task control lock held"
  pass "the local merge entrypoint refuses a captain-held task before merging"
}

test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id pr rc merge_count
  home=$(make_home missing-pr-authority-record)
  configure_merged_github "$home"
  id=sample-missing-pr-authority
  pr=https://github.com/sample/sample/pull/43
  write_origin_meta "$home" "$id" ship

  # A backlog that exists but cannot be read may hide a live captain hold, so
  # the merge must refuse without reaching the forge.
  chmod 000 "$home/data/backlog.md"
  set +e
  run_pr_merge "$home" "$id" "$pr" > "$home/missing-pr.out" 2> "$home/missing-pr.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted an unreadable captain-hold authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-pr.err" \
    "the PR merge refusal did not name its unreadable authority record"
  assert_no_grep 'pr merge 43 ' "$home/gh.log" \
    "the PR merge entrypoint reached the forge without a readable authority record"

  # A home with no backlog at all records no captain calls, so nothing can be
  # held and the merge proceeds.
  rm "$home/data/backlog.md"
  run_pr_merge "$home" "$id" "$pr" > "$home/absent-pr.out" 2> "$home/absent-pr.err" \
    || fail "the PR merge entrypoint refused a home carrying no backlog"
  merge_count=$(grep -c 'pr merge 43 ' "$home/gh.log" || true)
  [ "$merge_count" -eq 1 ] || fail "the absent backlog did not permit exactly one PR merge"
  pass "the PR merge entrypoint separates an unreadable authority record from an absent one"
}

test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id repo wt before after rc
  home=$(make_home missing-local-authority-record)
  id=sample-missing-local-authority
  repo="$home/projects/sample-local"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  printf 'untracked local delivery\n' > "$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'untracked local delivery'
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$id"
  before=$(git -C "$repo" rev-parse main)

  # Unreadable authority record: refuse, and leave the default branch where it was.
  chmod 000 "$home/data/backlog.md"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/missing-local.out" 2> "$home/missing-local.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  after=$(git -C "$repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted an unreadable captain-hold authority record"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main without a readable authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-local.err" \
    "the local merge refusal did not name its unreadable authority record"

  # No backlog at all: nothing can be held, so the landing proceeds.
  rm "$home/data/backlog.md"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/absent-local.out" 2> "$home/absent-local.err" \
    || fail "the local merge entrypoint refused a home carrying no backlog"
  after=$(git -C "$repo" rev-parse main)
  [ "$after" != "$before" ] || fail "the absent backlog did not permit the local merge"
  pass "the local merge entrypoint separates an unreadable authority record from an absent one"
}

test_merge_entrypoints_validate_identity_and_state_before_locking() {
  local home pr_state local_state bad_id rc
  home=$(make_home invalid-merge-entrypoint-inputs)
  configure_merged_github "$home"

  pr_state="$home/missing-pr-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$pr_state" \
    "$ROOT/bin/fm-pr-merge.sh" sample-missing-pr-state \
    https://github.com/sample/sample/pull/41 \
    > "$home/missing-pr-state.out" 2> "$home/missing-pr-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the PR merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the PR merge accepted a missing state directory"
  assert_absent "$pr_state" "the PR merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-pr-state.err" \
    "the PR merge did not identify its missing state directory"

  local_state="$home/missing-local-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$local_state" \
    "$ROOT/bin/fm-merge-local.sh" sample-missing-local-state \
    > "$home/missing-local-state.out" 2> "$home/missing-local-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the local merge accepted a missing state directory"
  assert_absent "$local_state" "the local merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-local-state.err" \
    "the local merge did not identify its missing state directory"

  bad_id=sample/bad-local-id
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" "$bad_id" \
    > "$home/bad-local-id.out" 2> "$home/bad-local-id.err"
  rc=$?
  set -e
  # Without canonical ID validation, the slash creates a nested lock path whose
  # absent parent makes the blocking acquisition retry until the bound expires.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever on a slash-containing task id"
  [ "$rc" -eq 2 ] || fail "the local merge returned $rc instead of rejecting the unsafe task id"
  assert_grep "invalid local merge request" "$home/bad-local-id.err" \
    "the local merge did not identify the unsafe task id"
  assert_absent "$home/state/.control-sample" \
    "the unsafe task id constructed a nested task control path"
  pass "merge entrypoints reject unsafe identities and absent state before locking"
}

test_merge_entrypoints_refuse_a_reused_task_incarnation() {
  local home id pr old_repo old_wt new_repo new_wt teardown_pid merge_pid
  local teardown_ready teardown_release merge_ready merge_release teardown_rc merge_rc
  local local_home local_id local_old_repo local_old_wt local_new_repo local_new_wt
  local local_teardown_pid local_merge_pid local_teardown_ready local_teardown_release
  local local_merge_ready local_merge_release local_teardown_rc local_merge_rc before after
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)

  home=$(make_home reused-pr-incarnation)
  configure_merged_github "$home"
  install_reused_task_barriers "$home"
  id=sample-reused-pr-incarnation
  pr=https://github.com/sample/sample/pull/42
  old_repo="$home/projects/sample-reused-pr-old"
  old_wt="$home/projects/$id"
  fm_git_worktree "$old_repo" "$old_wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the original pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$old_wt" \
    "project=$old_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=original-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"

  teardown_ready="$home/reuse-teardown-ready"
  teardown_release="$home/reuse-teardown-release"
  merge_ready="$home/reuse-merge-ready"
  merge_release="$home/reuse-merge-release"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$id" --force > "$home/reuse-teardown.out" \
    2> "$home/reuse-teardown.err" &
  teardown_pid=$!
  if ! wait_for_test_file "$teardown_ready" "$teardown_pid"; then
    : > "$teardown_release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "forced PR cleanup did not reach its task-locked synchronization point"
  fi

  FM_TEST_REUSE_MERGE=1 FM_TEST_REUSE_MERGE_ONCE="$home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$merge_ready" FM_TEST_REUSE_MERGE_RELEASE="$merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    run_pr_merge "$home" "$id" "$pr" > "$home/reuse-merge.out" \
    2> "$home/reuse-merge.err" &
  merge_pid=$!
  if ! wait_for_test_file "$merge_ready" "$merge_pid"; then
    : > "$teardown_release"
    : > "$merge_release"
    wait "$teardown_pid" 2>/dev/null || true
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not wait behind forced cleanup"
  fi

  : > "$teardown_release"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e
  if [ "$teardown_rc" -ne 0 ]; then
    : > "$merge_release"
    wait "$merge_pid" 2>/dev/null || true
    fail "forced PR cleanup failed before the task could be reused: $(cat "$home/reuse-teardown.err")"
  fi

  new_repo="$home/projects/sample-reused-pr-new"
  new_wt="$home/projects/reused-$id"
  fm_git_worktree "$new_repo" "$new_wt" "fm/$id"
  tasks_in "$home" reopen "$id" >/dev/null || fail "could not reopen the reused PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$new_wt" \
    "project=$new_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=replacement-$id"
  tasks_in "$home" start "$id" >/dev/null || fail "could not start the reused PR task"
  : > "$merge_release"
  set +e
  wait "$merge_pid"
  merge_rc=$?
  set -e

  # Without the pre-wait generation capture and locked comparison, the waiter
  # records and merges pull request 42 against the replacement task record.
  [ "$merge_rc" -ne 0 ] || fail "the PR merge accepted a replacement task incarnation"
  assert_no_grep 'pr merge 42 ' "$home/gh.log" \
    "the PR merge reached the forge for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$home/reuse-merge.err" \
    "the PR merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$id" "$home/state/$id.meta" \
    "the refused PR merge damaged the replacement task record"
  assert_absent "$home/state/.control-$id.lock" \
    "the reused-incarnation PR refusal left its task control lock held"

  local_home=$(make_home reused-local-incarnation)
  install_reused_task_barriers "$local_home"
  local_id=sample-reused-local-incarnation
  local_old_repo="$local_home/projects/sample-reused-local-old"
  local_old_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_old_repo" "$local_old_wt" "fm/$local_id"
  printf 'original local delivery\n' > "$local_old_wt/original.txt"
  git -C "$local_old_wt" add original.txt
  git -C "$local_old_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'original local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the original local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_old_wt" "project=$local_old_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=original-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"

  local_teardown_ready="$local_home/reuse-teardown-ready"
  local_teardown_release="$local_home/reuse-teardown-release"
  local_merge_ready="$local_home/reuse-merge-ready"
  local_merge_release="$local_home/reuse-merge-release"
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$local_home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$local_teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$local_teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$local_id" --force > "$local_home/reuse-teardown.out" \
    2> "$local_home/reuse-teardown.err" &
  local_teardown_pid=$!
  if ! wait_for_test_file "$local_teardown_ready" "$local_teardown_pid"; then
    : > "$local_teardown_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    fail "forced local cleanup did not reach its task-locked synchronization point"
  fi

  PATH="$local_home/fakebin:$PATH" FM_TEST_REUSE_MERGE=1 \
    FM_TEST_REUSE_MERGE_ONCE="$local_home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$local_merge_ready" \
    FM_TEST_REUSE_MERGE_RELEASE="$local_merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" > "$local_home/reuse-merge.out" \
    2> "$local_home/reuse-merge.err" &
  local_merge_pid=$!
  if ! wait_for_test_file "$local_merge_ready" "$local_merge_pid"; then
    : > "$local_teardown_release"
    : > "$local_merge_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    wait "$local_merge_pid" 2>/dev/null || true
    fail "the local merge did not wait behind forced cleanup"
  fi

  : > "$local_teardown_release"
  set +e
  wait "$local_teardown_pid"
  local_teardown_rc=$?
  set -e
  if [ "$local_teardown_rc" -ne 0 ]; then
    : > "$local_merge_release"
    wait "$local_merge_pid" 2>/dev/null || true
    fail "forced local cleanup failed before the task could be reused: $(cat "$local_home/reuse-teardown.err")"
  fi

  local_new_repo="$local_home/projects/sample-reused-local-new"
  local_new_wt="$local_home/projects/reused-$local_id"
  fm_git_worktree "$local_new_repo" "$local_new_wt" "fm/$local_id"
  printf 'replacement local delivery\n' > "$local_new_wt/replacement.txt"
  git -C "$local_new_wt" add replacement.txt
  git -C "$local_new_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'replacement local delivery'
  before=$(git -C "$local_new_repo" rev-parse main)
  tasks_in "$local_home" reopen "$local_id" >/dev/null \
    || fail "could not reopen the reused local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_new_wt" "project=$local_new_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=replacement-$local_id"
  tasks_in "$local_home" start "$local_id" >/dev/null \
    || fail "could not start the reused local task"
  : > "$local_merge_release"
  set +e
  wait "$local_merge_pid"
  local_merge_rc=$?
  set -e
  after=$(git -C "$local_new_repo" rev-parse main)

  # Without the pre-wait generation capture and locked comparison, the waiter
  # fast-forwards the replacement task's branch despite never approving it.
  [ "$local_merge_rc" -ne 0 ] || fail "the local merge accepted a replacement task incarnation"
  [ "$after" = "$before" ] || fail "the local merge moved main for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$local_home/reuse-merge.err" \
    "the local merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$local_id" "$local_home/state/$local_id.meta" \
    "the refused local merge damaged the replacement task record"
  assert_absent "$local_home/state/.control-$local_id.lock" \
    "the reused-incarnation local refusal left its task control lock held"
  pass "merge entrypoints refuse a replacement incarnation after waiting for cleanup"
}

test_merge_entrypoints_serialize_forced_teardown_before_task_reads() {
  local home id pr repo wt ready release merge_pid teardown_rc merge_rc real_grep
  local local_home local_id local_repo local_wt local_ready local_release local_pid
  local local_teardown_rc local_merge_rc real_git before after deadline

  home=$(make_home teardown-race-pr-entrypoint)
  configure_merged_github "$home"
  id=sample-teardown-race-pr
  pr=https://github.com/sample/sample/pull/33
  repo="$home/projects/sample-pr-race"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the released pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the PR teardown-race fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR teardown-race fixture"
  printf 'Merge the released pull request.\n' > "$home/race-answer.txt"
  run_captain "$home" answer "$id" --release --decision-file "$home/race-answer.txt" \
    >/dev/null || fail "could not release the PR teardown-race fixture"

  real_grep=$(command -v grep)
  ready="$home/pr-metadata-read-ready"
  release="$home/pr-metadata-read-release"
  fm_shared_stub "$home/fakebin" "grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -qxF ] && [ "${2:-}" = "pr=${FM_TEST_RACE_PR_URL:-}" ] \
    && [ "${3:-}" = "${FM_TEST_RACE_PR_META:-}" ]; then
  "$FM_TEST_REAL_GREP" "$@" || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  exit 0
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  FM_TEST_REAL_GREP="$real_grep" FM_TEST_RACE_PR_URL="$pr" \
    FM_TEST_RACE_PR_META="$home/state/$id.meta" FM_TEST_RACE_READY="$ready" \
    FM_TEST_RACE_RELEASE="$release" run_pr_merge "$home" "$id" "$pr" \
    > "$home/race-pr.out" 2> "$home/race-pr.err" &
  merge_pid=$!
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$ready" ] && break
    kill -0 "$merge_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not reach the post-metadata synchronization point"
  fi
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/race-pr-teardown.out" 2> "$home/race-pr-teardown.err"
  teardown_rc=$?
  set -e
  : > "$release"
  wait "$merge_pid"
  merge_rc=$?

  # Without early lock ownership, forced cleanup succeeds after metadata is
  # recorded, and the resumed forge call merges work whose task was retired.
  [ "$teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between PR metadata recording and merge"
  assert_grep "another lifecycle action is already running for task $id" \
    "$home/race-pr-teardown.err" \
    "PR cleanup was not refused by the merge's task control lock"
  [ "$merge_rc" -eq 0 ] || fail "the serialized PR merge failed after cleanup was refused"
  assert_present "$home/state/$id.meta" "the refused PR cleanup removed task metadata"
  assert_grep 'pr merge 33 ' "$home/gh.log" \
    "the serialized PR merge did not reach the forge after cleanup was refused"

  local_home=$(make_home teardown-race-local-entrypoint)
  local_id=sample-teardown-race-local
  local_repo="$local_home/projects/sample-local-race"
  local_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'serialized local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'serialized local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the released local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the local teardown-race fixture"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"
  run_captain "$local_home" hold "$local_id" \
    --reason "captain local merge approval pending" >/dev/null \
    || fail "could not hold the local teardown-race fixture"
  printf 'Land the released local change.\n' > "$local_home/race-answer.txt"
  run_captain "$local_home" answer "$local_id" --release \
    --decision-file "$local_home/race-answer.txt" >/dev/null \
    || fail "could not release the local teardown-race fixture"

  real_git=$(command -v git)
  local_ready="$local_home/local-validation-ready"
  local_release="$local_home/local-validation-release"
  fm_shared_stub "$local_home/fakebin" "git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-C ${FM_TEST_RACE_REPO:-} rev-parse --short main" ]; then
  output=$("$FM_TEST_REAL_GIT" "$@") || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  printf '%s\n' "$output"
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  before=$(git -C "$local_repo" rev-parse main)
  PATH="$local_home/fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" \
    FM_TEST_RACE_REPO="$local_repo" FM_TEST_RACE_READY="$local_ready" \
    FM_TEST_RACE_RELEASE="$local_release" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$local_home" FM_STATE_OVERRIDE="$local_home/state" \
    FM_DATA_OVERRIDE="$local_home/data" FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$local_home/race-local.out" 2> "$local_home/race-local.err" &
  local_pid=$!
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$local_ready" ] && break
    kill -0 "$local_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [ ! -e "$local_ready" ]; then
    : > "$local_release"
    wait "$local_pid" 2>/dev/null || true
    fail "the local merge did not reach the post-validation synchronization point"
  fi
  set +e
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" "$TEARDOWN" "$local_id" --force \
    > "$local_home/race-local-teardown.out" 2> "$local_home/race-local-teardown.err"
  local_teardown_rc=$?
  set -e
  : > "$local_release"
  wait "$local_pid"
  local_merge_rc=$?
  after=$(git -C "$local_repo" rev-parse main)

  # Without early lock ownership, forced cleanup succeeds after validation and
  # the resumed fast-forward lands work whose task was already retired.
  [ "$local_teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between local validation and merge"
  assert_grep "another lifecycle action is already running for task $local_id" \
    "$local_home/race-local-teardown.err" \
    "local cleanup was not refused by the merge's task control lock"
  [ "$local_merge_rc" -eq 0 ] || fail "the serialized local merge failed after cleanup was refused"
  [ "$after" != "$before" ] || fail "the serialized local merge did not fast-forward main"
  assert_present "$local_home/state/$local_id.meta" \
    "the refused local cleanup removed task metadata"
  pass "merge entrypoints own task state before forced cleanup can retire it"
}

# No regression covers a re-hold after a merge lands and before cleanup because
# that accepted window spans two separate lifecycle owners.
# Queued forge merges are also uncovered because they land asynchronously after
# the local merge command and its task control lock have returned.
test_released_merge_passes_the_entrypoint_and_lands() {
  local home id pr repo wt show json
  home=$(make_home released-merge-entrypoint)
  configure_merged_github "$home"
  id=sample-released-merge
  pr=https://github.com/sample/sample/pull/32
  repo="$home/projects/sample-released"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the approved pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released merge fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the released merge fixture"
  printf 'Merge the approved pull request.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge task disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "the approved merge remained captain-held after its release"
  run_pr_merge "$home" "$id" "$pr" > "$home/merge.out" 2> "$home/merge.err" \
    || fail "the released merge was refused: $(cat "$home/merge.err")"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "the released merge cleanup failed: $(cat "$home/teardown.err")"
  json=$(run_bearings "$home") || fail "Bearings failed after the released merge lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" --arg pr "$pr" \
    '.landed | any(.id == $id and .artifact == $pr)' >/dev/null \
    || fail "the released merge was absent from Recently Landed: $json"
  pass "a released merge passes the guarded entrypoint and remains recently landed"
}

# A refused hold must never read as a recorded one. The gate used to accept the
# origin as its own inventory whenever the origin row looked durable, so a hold
# that failed just before `complete <origin> <origin>` left a satisfied gate
# with no captain call recorded.
test_origin_is_never_its_own_inventory_entry() {
  local home id
  home=$(make_home origin-self-inventory)
  id=sample-self-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample self review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  if run_captain "$home" hold "$id" --reason "" >/dev/null 2> "$home/hold.err"; then
    fail "hold accepted an empty reason"
  fi
  if run_captain "$home" complete "$id" "$id" > "$home/self.out" 2> "$home/self.err"; then
    fail "complete accepted the origin as its own inventory after a failed hold"
  fi
  assert_grep "cannot be its own captain-call inventory entry" "$home/self.err" \
    "the refusal does not say why the origin was rejected"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  # Holding the origin row itself must not let it vouch for itself either.
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold the origin row"
  if run_captain "$home" complete "$id" "$id" > "$home/held.out" 2> "$home/held.err"; then
    fail "complete accepted a held origin row as its own inventory"
  fi
  pass "complete refuses the origin as its own captain-call inventory"
}

# `hold --origin` records which origin a call was held for, and `complete`
# refuses a task held for a different origin. A hold recorded before that
# record existed, or without --origin, still verifies and is flagged.
test_complete_refuses_an_entry_held_for_another_origin() {
  local home id other o out
  home=$(make_home origin-mismatch)
  id=sample-first-review
  other=sample-second-review
  for o in "$id" "$other"; do
    mkdir -p "$home/data/$o"
    tasks_in "$home" add "$o" "Investigate $o" --kind scout --repo sample --start >/dev/null \
      || fail "could not create the $o fixture"
    write_origin_meta "$home" "$o"
    printf 'done: report complete\n' > "$home/state/$o.status"
  done
  run_captain "$home" hold sample-other-call --title "Call for the second review" \
    --reason "captain must decide" --repo sample --origin "$other" >/dev/null \
    || fail "could not hold the call recorded for the second review"
  if run_captain "$home" complete "$id" sample-other-call > "$home/mismatch.out" 2> "$home/mismatch.err"; then
    fail "complete accepted an entry held for a different origin"
  fi
  assert_grep "was held for origin $other, not $id" "$home/mismatch.err" \
    "the refusal does not name both origins"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  run_captain "$home" hold sample-own-call --title "Call for the first review" \
    --reason "captain must decide" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the call recorded for the first review"
  out=$(run_captain "$home" complete "$id" sample-own-call) \
    || fail "complete refused an entry held for its own origin"
  assert_not_contains "$out" "no recorded origin" \
    "an entry with a recorded origin was flagged as unrecorded"

  tasks_in "$home" add sample-old-call "Call held before origins were recorded" --kind captain --repo sample >/dev/null \
    || fail "could not create the older call"
  tasks_in "$home" hold sample-old-call --reason "captain must decide" --kind captain >/dev/null \
    || fail "could not hold the older call"
  out=$(run_captain "$home" complete "$other" sample-old-call) \
    || fail "complete refused an older hold with no recorded origin"
  assert_contains "$out" "no recorded origin on: sample-old-call" \
    "an older hold with no recorded origin was not flagged"
  pass "complete refuses an entry held for another origin and flags one with none recorded"
}

test_hold_origins_precede_backend_holds() {
  local home phase timing failure id shown origin until_args=()
  for phase in new active released; do
    for timing in plain dated; do
      home=$(make_home "origin-failure-$phase-$timing")
      id=sample-call
      for origin in origin-a origin-b; do
        tasks_in "$home" add "$origin" "Review $origin" --kind scout --repo sample >/dev/null \
          || fail "could not create $origin"
        write_origin_meta "$home" "$origin"
      done
      if [ "$phase" != new ]; then
        run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
          --origin origin-a >/dev/null || fail "could not establish the original association"
      fi
      if [ "$phase" = released ]; then
        printf 'Release this work.\n' > "$home/answer.txt"
        run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
          || fail "could not release the original hold"
      fi
      fm_shared_stub "$home/fakebin" "tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = origin-b ] && [ -f "$FM_HOME/fail-lookup" ]; then
  : > "$FM_HOME/lookup-refused"
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "${1:-}" = update ] && [ -f "$FM_HOME/fail-write" ]; then
  previous=''
  for arg in "$@"; do
    if [ "$previous" = --body-file ] && grep -qx 'Captain hold origin: origin-b' "$arg"; then
      : > "$FM_HOME/write-refused"
      exit 9
    fi
    previous=$arg
  done
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  if [ -f "$FM_HOME/fail-hold" ]; then
    : > "$FM_HOME/hold-refused"
    exit 9
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
SH
      until_args=()
      [ "$timing" != dated ] || until_args=(--until 2099-01-01)
      for failure in lookup write hold; do
        : > "$home/fail-$failure"
        if run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for B" \
          --origin origin-b ${until_args[@]+"${until_args[@]}"} > "$home/hold.out" 2> "$home/hold.err"; then
          fail "$phase $timing hold succeeded despite an origin $failure failure"
        fi
        assert_present "$home/$failure-refused" "the failure did not reach the origin $failure"
        if [ "$failure" = hold ]; then
          assert_present "$home/before-backend-hold" "$phase $timing failure never reached the backend hold"
          assert_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
            "the failed backend hold did not see the new association"
          rm "$home/before-backend-hold"
        else
          assert_absent "$home/before-backend-hold" "$phase $timing origin $failure failure reached the backend hold"
        fi
        shown=$(tasks_in "$home" show "$id" --full)
        assert_not_contains "$shown" 'Captain hold origin: origin-b' \
          "$phase $timing origin $failure failure published the new association"
        if [ "$phase" = active ]; then
          assert_contains "$shown" 'held: yes' "an origin $failure failure lifted an existing hold"
        else
          assert_contains "$shown" 'held: no' "$phase $timing origin $failure failure left the task held"
        fi
        if [ "$phase" != new ]; then
          assert_contains "$shown" 'Captain hold origin: origin-a' \
            "$phase $timing origin $failure failure lost the original association"
        fi
        rm "$home/fail-$failure"
        if [ "$phase" = new ] && run_captain "$home" complete origin-a "$id" \
          > "$home/unrelated.out" 2> "$home/unrelated.err"; then
          fail "$timing origin $failure failure satisfied an unrelated inventory"
        fi
        if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
          fail "$phase $timing origin $failure failure satisfied completion for B"
        fi
        printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
        if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
          fail "$phase $timing origin $failure failure verified an inventory for B"
        fi
        if [ "$phase" != new ]; then
          run_captain "$home" complete origin-a "$id" >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated completion for A"
          run_captain "$home" verify origin-a >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated verification for A"
        fi
      done
      run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
        ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "$phase $timing successful retry failed"
      assert_present "$home/before-backend-hold" "the successful retry did not reach the backend hold"
      shown=$(cat "$home/before-backend-hold")
      assert_contains "$shown" 'Captain hold origin: origin-b' "the backend hold ran before the new origin was recorded"
      assert_not_contains "$shown" 'Captain hold origin: origin-a' "the backend hold ran with the old association"
      shown=$(tasks_in "$home" show "$id" --full)
      assert_contains "$shown" 'held: yes' "the successful retry did not hold the task"
      assert_contains "$shown" 'Captain hold origin: origin-b' "a successful hold lost its association"
      assert_not_contains "$shown" 'Captain hold origin: origin-a' "a successful hold retained the old association"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "a successful hold could not complete B"
      run_captain "$home" verify origin-b >/dev/null || fail "a successful hold could not verify B"
      if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/old-origin.err"; then
        fail "a successful reassociation still certified A"
      fi
    done
  done
  pass "new, active, and released holds require the origin first with and without deferral"
}

test_historical_self_inventory_has_workable_repair() {
  local home origin=sample-review keep=retained-call replacement=repair-call meta before out
  home=$(make_home historical-self-inventory)
  run_captain "$home" hold "$origin" --title "Old review call" --reason "Choose" >/dev/null \
    || fail "could not create the historical origin"
  write_origin_meta "$home" "$origin"
  for out in "$keep" "$replacement"; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$origin" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$origin.meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$origin" "$keep" >> "$meta"
  before=$(cat "$meta")
  for out in "$replacement" --none; do
    if run_captain "$home" complete "$origin" "$out" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "complete accepted the historical self-inventory"
    fi
    assert_grep "historical decision_keys in $meta still contains $origin" "$home/complete.err" \
      "the historical refusal did not identify the persisted entry"
    assert_grep 'replace only' "$home/complete.err" "the refusal omitted the repair instruction"
  done
  if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify accepted the historical self-inventory"
  fi
  assert_grep "historical decision_keys in $meta still contains $origin" "$home/verify.err" \
    "verify omitted the historical repair instruction"
  assert_equals "$before" "$(cat "$meta")" "refusing a historical inventory changed it"
  sed "s/^decision_keys=$origin,$keep$/decision_keys=$replacement,$keep/" "$meta" > "$meta.repaired"
  mv "$meta.repaired" "$meta"
  run_captain "$home" complete "$origin" "$replacement" >/dev/null \
    || fail "the documented historical repair did not allow completion"
  run_captain "$home" verify "$origin" >/dev/null || fail "the repaired inventory did not verify"
  assert_equals "decision_keys=$replacement,$keep" "$(grep '^decision_keys=' "$meta" | tail -1)" \
    "repair lost a sibling inventory entry"
  if run_captain "$home" complete "$origin" "$origin" >/dev/null 2> "$home/self.err"; then
    fail "repair allowed a new self-inventory"
  fi
  pass "historical self-inventories name a workable repair that preserves sibling entries"
}

test_inventory_compares_backend_identities() {
  local home origin entry shown before
  home=$(make_home backend-identities)
  run_captain "$home" hold fm-o --title "Origin" --reason "Choose" >/dev/null \
    || fail "could not create the canonical origin"
  tasks_in "$home" add fm-other "Other origin" --kind scout --repo sample >/dev/null \
    || fail "could not create the other origin"
  fm_shared_stub "$home/fakebin" "tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = o ] && [ -f "$FM_HOME/fail-identity" ]; then
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "$#" -ge 2 ]; then
  case "$2" in
    o|call|other) set -- "$1" "fm-$2" "${@:3}" ;;
  esac
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  for origin in fm-o o; do
    for entry in fm-o o; do
      write_origin_meta "$home" "$origin"
      if run_captain "$home" complete "$origin" "$entry" > "$home/self.out" 2> "$home/self.err"; then
        fail "complete accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'cannot be its own captain-call inventory entry' "$home/self.err" \
        "the alias refusal did not identify self-inventory"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$entry" >> "$home/state/$origin.meta"
      if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'historical decision_keys' "$home/verify.err" "the alias repair diagnostic was missing"
    done
    write_origin_meta "$home" "$origin"
  done
  run_captain "$home" hold fm-call --title "Separate call" --reason "Choose" --origin o >/dev/null \
    || fail "could not hold a call using the origin alias"
  shown=$(tasks_in "$home" show fm-call --full)
  assert_contains "$shown" 'Captain hold origin: fm-o' "hold did not store the backend origin identity"
  printf '%s\n' "$shown" | sed -n 's/^  body: //p' | jq -r . \
    | sed 's/^Captain hold origin: fm-o$/Captain hold origin: o/' > "$home/legacy-origin.txt"
  tasks_in "$home" update fm-call --body-file "$home/legacy-origin.txt" >/dev/null \
    || fail "could not create a legacy stored alias"
  for origin in fm-o o; do
    for entry in fm-call call; do
      run_captain "$home" complete "$origin" "$entry" >/dev/null \
        || fail "complete refused equivalent origin spellings for $origin/$entry"
      run_captain "$home" verify "$origin" >/dev/null \
        || fail "verify refused equivalent origin spellings for $origin/$entry"
    done
  done
  for origin in fm-other other; do
    write_origin_meta "$home" "$origin"
    if run_captain "$home" complete "$origin" call > "$home/other.out" 2> "$home/other.err"; then
      fail "complete accepted another origin through $origin"
    fi
    assert_grep "was held for origin o, not $origin" "$home/other.err" "the alias mismatch was not identified"
    printf 'decisions_reviewed=1\ndecision_keys=call\n' >> "$home/state/$origin.meta"
    if run_captain "$home" verify "$origin" >/dev/null 2> "$home/other-verify.err"; then
      fail "verify accepted another origin through $origin"
    fi
  done
  : > "$home/fail-identity"
  before=$(cat "$home/state/o.meta")
  if run_captain "$home" complete o fm-call >/dev/null 2> "$home/read.err"; then
    fail "an unreadable backend identity was treated as an absent origin"
  fi
  assert_grep 'could not resolve the backend identity of o' "$home/read.err" "the identity read failure was hidden"
  assert_equals "$before" "$(cat "$home/state/o.meta")" "a failed identity read changed the inventory"
  rm "$home/fail-identity"
  write_origin_meta "$home" report-only
  run_captain "$home" hold report-call --title "Report call" --reason "Choose" --origin report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not record a call"
  run_captain "$home" complete report-only report-call >/dev/null \
    || fail "an origin with metadata but no backlog row could not complete"
  run_captain "$home" verify report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not verify"
  pass "completion and verification compare backend identities for entries and current or stored origins"
}

# tasks-axi refuses parentheses and line breaks in a hold reason and stores the
# rest on one markdown line. The reason is encoded where it is written and
# decoded wherever it is shown, so prose with every awkward character survives.
test_hold_reason_round_trips_awkward_characters() {
  local home id reason stored json shown start verb fields out raw rc raw_rc mode
  local title legacy body quoted_reason quoted_title quoted_legacy expected_reason until_args=()
  local malformed index=0 malformed_reasons=(
    'fm-hold-v1:/w==' 'fm-hold-v1:bm9ydGg=$' 'fm-hold-v1:bm9ydGg' 'fm-hold-v1:Zh=='
  )
  home=$(make_home reason-round-trip)
  title='Investigate literal %28, "fm-hold-v1:bm9ydGg="'
  legacy='Visit https://example.test/%28literal%29 and %0A; fm-hold-v1:bm9ydGg='
  body=$'fm-hold-v1:bm9ydGg=\n  hold_reason: "%28"\n'
  quoted_title=$(jq -cn --arg value "$title" '$value')
  quoted_legacy=$(jq -cn --arg value "$legacy" '$value')
  tasks_in "$home" add sample-legacy-call "$title" --kind captain --repo sample >/dev/null \
    || fail "could not create the legacy call"
  tasks_in "$home" hold sample-legacy-call --reason "$legacy" --kind captain >/dev/null \
    || fail "could not hold the legacy call"
  printf '%s' "$body" > "$home/legacy-body.txt"
  tasks_in "$home" update sample-legacy-call --body-file "$home/legacy-body.txt" >/dev/null \
    || fail "could not write the legacy body"

  # Historical literal reasons are persisted input, not encoder output.
  for malformed in "${malformed_reasons[@]}"; do
    id="sample-malformed-$index"
    index=$((index + 1))
    tasks_in "$home" add "$id" "Historical reason $index" --kind captain --repo sample >/dev/null \
      || fail "could not create $id"
    tasks_in "$home" hold "$id" --reason "$malformed" --kind captain >/dev/null \
      || fail "could not store the historical literal reason"
    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id" --full) \
        || fail "public $verb failed on historical literal $malformed"
      raw=$(tasks_in "$home" "$verb" "$id" --full)
      assert_equals "$raw" "$out" "public $verb changed historical literal $malformed"
    done
  done

  for id in sample-reason-call sample-dated-call; do
    until_args=()
    reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
    if [ "$id" = sample-dated-call ]; then
      until_args=(--until 2099-01-01)
      reason='fm-hold-v1:bm9ydGg='
    fi
    quoted_reason=$(jq -cn --arg value "$reason" '$value')
    run_captain "$home" hold "$id" --title "$title" --reason "$reason" \
      --repo sample ${until_args[@]+"${until_args[@]}"} >/dev/null \
      || fail "hold refused the reason for $id"
    stored=$(grep "^- \[ \] $id " "$home/data/backlog.md") \
      || fail "the held row is not on one backlog line"
    assert_contains "$stored" "(hold: fm-hold-v1:" "the persisted reason has no encoding marker"
    assert_contains "$stored" "(hold-kind: captain)" "the reason broke the hold-kind tag"

    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id") \
        || fail "public $verb failed for $id"
      shown=$(printf '%s\n' "$out" | sed -n 's/^  hold_reason: //p')
      printf '%s\n' "$shown" | jq -e --arg reason "$reason" '. == $reason' >/dev/null \
        || fail "public $verb changed the reason for $id"
      assert_contains "$out" "  title: $quoted_title" "public $verb changed the title"
    done
    for fields in hold_reason,body body,hold_reason,hold_until; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list --fields "$fields") \
        || fail "public list failed with $fields"
      assert_contains "$out" "$quoted_reason" "public list changed the reason with $fields"
      assert_contains "$out" "$quoted_title" "public list changed the title with $fields"
      raw=$(tasks_in "$home" list --fields "$fields" | grep '^  sample-legacy-call,')
      shown=$(printf '%s\n' "$out" | grep '^  sample-legacy-call,')
      assert_equals "$raw" "$shown" "public list changed legacy or unrelated fields"
      for malformed in "${malformed_reasons[@]}"; do
        assert_contains "$out" "$malformed" "public list changed historical literal $malformed"
      done
    done
    json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
    printf '%s' "$json" | jq -e --arg id "$id" --arg reason "$reason" --arg title "$title" \
      '.backlog.records[] | select(.id == $id) | .hold_reason == $reason and .title == $title' >/dev/null \
      || fail "fleet changed the reason or title for $id"
    printf '%s' "$json" | jq -e --arg reason "$legacy" --arg title "$title" \
      '.backlog.records[] | select(.id == "sample-legacy-call") |
       .hold_reason == $reason and .title == $title and .body_lines[0] == "fm-hold-v1:bm9ydGg="' >/dev/null \
      || fail "fleet changed legacy or unrelated fields"
    for malformed in "${malformed_reasons[@]}"; do
      printf '%s' "$json" | jq -e --arg reason "$malformed" \
        'any(.backlog.records[]; .hold_reason == $reason)' >/dev/null \
        || fail "fleet changed historical literal $malformed"
    done
  done

  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show sample-legacy-call --full)
  raw=$(tasks_in "$home" show sample-legacy-call --full)
  assert_equals "$raw" "$out" "public show changed legacy or unrelated fields"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list)
  raw=$(tasks_in "$home" list)
  assert_equals "$raw" "$out" "public list changed output with no reason column"
  for verb in show list; do
    out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" --help)
    raw=$(tasks_in "$home" "$verb" --help)
    assert_equals "$raw" "$out" "public $verb changed help output"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show nonexistent-call 2>&1)
  rc=$?
  raw=$(tasks_in "$home" show nonexistent-call 2>&1)
  raw_rc=$?
  [ "$raw_rc" -ne 0 ] || fail "the missing-task fixture unexpectedly exists"
  expect_code "$raw_rc" "$rc" "public show missing task"
  assert_equals "$raw" "$out" "public show changed a read error"

  expected_reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
  quoted_reason=$(jq -cn --arg value "$expected_reason" '$value')
  for mode in tool manual fallback; do
    case "$mode" in
      manual) printf 'manual\n' > "$home/config/backlog-backend" ;;
      fallback)
        rm "$home/config/backlog-backend"
        fm_shared_stub "$home/fakebin" "tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'read failed: literal %%28 and fm-hold-v1:bm9ydGg=\n' >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
        ;;
    esac
    start=$(PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-session-start.sh" 2>&1 || true)
    assert_contains "$start" "$quoted_reason" "startup $mode changed the encoded reason"
    assert_contains "$start" 'Investigate literal %28' "startup $mode changed the title"
    assert_contains "$start" "$legacy" "startup $mode changed the legacy reason"
    assert_contains "$start" '"fm-hold-v1:bm9ydGg="' "startup $mode decoded a reason twice"
    for malformed in "${malformed_reasons[@]}"; do
      assert_contains "$start" "$malformed" "startup $mode changed historical literal $malformed"
    done
    if [ "$mode" = fallback ]; then
      assert_contains "$start" 'read failed: literal %28 and fm-hold-v1:bm9ydGg=' \
        "startup changed unrelated error text"
    fi
  done
  rm "$home/fakebin/tasks-axi"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-afk-return.sh" check 2>&1 || true)
  assert_contains "$out" "$quoted_reason" "return brief changed the encoded reason"
  assert_contains "$out" "$quoted_title" "return brief changed the title"
  assert_contains "$out" "$quoted_legacy" "return brief changed the legacy reason"
  for malformed in "${malformed_reasons[@]}"; do
    assert_contains "$out" "$malformed" "return brief changed historical literal $malformed"
  done
  pass "marked hold reasons round-trip through public reads, fleet, startup, and return without changing other fields"
}

test_hold_reason_round_trips_awkward_characters
test_hold_origins_precede_backend_holds
test_historical_self_inventory_has_workable_repair
test_inventory_compares_backend_identities
test_origin_is_never_its_own_inventory_entry
test_complete_refuses_an_entry_held_for_another_origin
test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_hold_stamp_precedes_hold_visibility
test_interrupted_answer_preserves_hold_age
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_secondmate_reconcile_publishes_before_request_retirement
test_merge_approval_releases_before_zero_done_retention
test_pr_merge_entrypoint_refuses_a_captain_held_task
test_local_merge_entrypoint_refuses_a_captain_held_task
test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_merge_entrypoints_validate_identity_and_state_before_locking
test_merge_entrypoints_refuse_a_reused_task_incarnation
test_merge_entrypoints_serialize_forced_teardown_before_task_reads
test_released_merge_passes_the_entrypoint_and_lands
