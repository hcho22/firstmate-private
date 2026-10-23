#!/usr/bin/env bash
# End-to-end tests for captain-held tasks, part two: answers captured from bound
# channels, boards, and the chat channel, and the reconcile requests a captured
# selection opens; the legacy compatibility for pre-collapse decision identities
# and for holds migrated to the Beads backend; origin validation; the
# record-divergence guard over a captain call's two records; and how cleanup
# treats captain-held work and the body it retains.
# tests/fm-captain-hold-lifecycle.test.sh covers the core lifecycle; the two
# share tests/captain-hold-helpers.sh.
set -u

# shellcheck source=tests/captain-hold-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"

# --- markdown-to-beads migration resolution ----------------------------------
#
# A home on the Beads backend no longer carries the legacy markdown ids a scout
# report attested: fm-hold-migration rehomed each held row under a prefixed fm-
# id and recorded its markdown identity in the row's notes as the exact line
# "migrated from data/backlog.md id <legacy id>". The fixture graph is driven
# through bd directly where possible because the npm-published tasks-axi ships
# the markdown backend only; the hold itself needs a beads-capable tasks-axi,
# so that family probes once and skips itself with an explicit reason on
# markdown-only installs, mirroring tests/fm-control-relaunch.test.sh.

# Build a fixture home whose configured backend is a scratch Beads graph.
# Echoes "<home>|<graph-beads-dir>". The graph repo dir is named "fm" because
# bd derives the row-id prefix from the repo directory name.
make_beads_home() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph"
  (umask 077; mkdir -p "$home/state")
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  fb=$(fm_fakebin "$home")
  fm_shared_stub_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home|$graph/.beads"
}

bdrow() {  # <beads-dir> <args...>
  BEADS_DIR="$1" bd "${@:2}"
}

# One capability probe for the migration family: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot, and the
# hold fixture needs its beads backend; those installs skip with this reason.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  rm -rf "$probe_home" "$probe_graph"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 \
   && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

write_scout_with_attested_inventory() {  # <home> <scout-id> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}

test_verify_resolves_a_hold_migrated_to_beads_notes() {
  local fixture home beads scout
  require_tasks_axi_beads "verify against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-notes)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-beads-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "Origin: herald-retire
Decision key: github-delete
State: awaiting captain decision.

migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_scout_with_attested_inventory "$home" "$scout" \
    herald-retire-decision-github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the attested legacy id through its migrated beads row"
  pass "verify resolves a captain hold migrated to a beads row with a marker note"
}

# A tasks-axi stub that knows ONLY the row ids it is given. The real
# beads-capable tasks-axi resolves a bare legacy id onto its prefixed row
# itself, answering before any migration lookup runs; against this stub the
# migrated-hold resolution order is what has to answer.
write_known_rows_stub() {  # <fakebin> <row-id...>
  local fb=$1 known
  shift
  known=$(printf '%s|' "$@")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '  --kind captain'
    ;;
  show)
    case "${2:-}" in
      @KNOWN@) ;;
      *) printf 'error: no task %s in this backlog\ncode: NOT_FOUND\n' "${2:-}" >&2; exit 1 ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$2"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain' '  body: ""'
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@KNOWN@%${known%|}%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

test_verify_resolves_a_hold_migrated_under_the_configured_prefix() {
  local fixture home scout out
  require_tasks_axi_beads "verify against a prefix-migrated hold" || return 0
  fixture=$(make_beads_home migrated-prefix)
  home=${fixture%%|*}
  scout=sample-prefix-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-other-legacy-row \
    "Second migrated hold" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the prefix-migrated fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-other-legacy-row \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the prefix-migrated fixture row"
  # No row in this graph carries a marker note, so the narrowed prefix guess is
  # the only resolution left for the attested legacy id.
  write_known_rows_stub "$(fm_fakebin "$home")" fm-other-legacy-row
  write_scout_with_attested_inventory "$home" "$scout" other-legacy-row

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the legacy id under the configured prefix"
  out=$(run_captain "$home" complete "$scout" other-legacy-row) \
    || fail "the completion gate refused the prefix-resolved hold"
  assert_contains "$out" "other-legacy-row=fm-other-legacy-row" \
    "completion did not name the row the prefix guess attested against"
  pass "verify resolves a captain hold whose id is the legacy id under the configured prefix"
}

# The prefix guess is a name, not evidence: when a row actually carries the
# migration marker, that row is the one attested even though an unrelated
# captain-held task occupies the <prefix>-<legacy id> name.
test_marker_noted_row_wins_over_a_prefix_namesake() {
  local fixture home beads scout row out
  require_tasks_axi_beads "prefer a marker-noted row over a prefix namesake" || return 0
  fixture=$(make_beads_home migrated-marker-wins)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-marker-wins-scout
  for row in fm-dual-row fm-marked-dual-row fm-solo-row; do
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$row" "Captain call $row" \
      --repo sample) >/dev/null 2>&1 || fail "could not create the fixture row $row"
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$row" --kind captain \
      --reason "captain must decide") >/dev/null 2>&1 \
      || fail "could not hold the fixture row $row"
  done
  bdrow "$beads" note fm-marked-dual-row \
    "migrated from data/backlog.md id dual-row on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_known_rows_stub "$(fm_fakebin "$home")" \
    fm-dual-row fm-marked-dual-row fm-solo-row
  write_scout_with_attested_inventory "$home" "$scout" "dual-row,solo-row"

  out=$(run_captain "$home" complete "$scout" dual-row solo-row) \
    || fail "the completion gate refused an inventory carrying both migrated shapes"
  assert_not_contains "$out" "dual-row=fm-dual-row" \
    "the bare prefix namesake shadowed the row carrying the migration marker"
  assert_contains "$out" "solo-row=fm-solo-row" \
    "completion did not name the row the prefix guess attested against"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve both migrated shapes after completion"
  pass "the marker-noted row wins over an unrelated row holding the prefix namesake"
}

test_complete_accepts_a_migrated_inventory_on_beads() {
  local fixture home scout
  require_tasks_axi_beads "complete against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-complete)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-complete-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  mkdir -p "$home/data/$scout"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"

  run_captain "$home" complete "$scout" herald-retire-decision-github-delete >/dev/null \
    || fail "the completion gate refused an inventory resolved through a migrated beads row"
  assert_grep "decision_keys=herald-retire-decision-github-delete" \
    "$home/state/$scout.meta" \
    "the attestation did not record the attested legacy id"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve the attested legacy id after completion"
  pass "the completion gate attests an inventory resolved through a migrated beads row"
}

test_verify_names_the_unresolvable_legacy_id_once() {
  local fixture home scout err rc
  require_tasks_axi_beads "verify an unresolvable beads legacy id" || return 0
  fixture=$(make_beads_home migrated-absent)
  home=${fixture%%|*}
  scout=sample-absent-scout
  write_scout_with_attested_inventory "$home" "$scout" ghost-legacy-id

  rc=0
  err=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an attested id that resolves to nothing"
  assert_contains "$err" "ghost-legacy-id" \
    "the refusal did not name the id it could not resolve"
  [ "$(printf '%s\n' "$err" | grep -c '^fm-captain-hold:')" = 1 ] \
    || fail "the refusal emitted more than one line: $err"
  pass "an unresolvable legacy id is refused once, naming the id"
}

test_verify_resolves_a_pre_collapse_key_through_its_derived_marker() {
  local fixture home beads scout
  require_tasks_axi_beads "verify a derived pre-collapse key" || return 0
  fixture=$(make_beads_home migrated-derived)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-derived-scout
  # The row was migrated under the DERIVED pre-collapse identity, keyed by a
  # bare decision key the origin's old metadata attests.
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-dec-call \
    "Migrated pre-collapse call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the derived-marker fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-dec-call \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the derived-marker fixture row"
  bdrow "$beads" note fm-dec-call \
    "migrated from data/backlog.md id $scout-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the derived-id marker note"
  write_scout_with_attested_inventory "$home" "$scout" github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not probe the derived pre-collapse identity for its migrated row"
  pass "a pre-collapse key resolves through its derived identity's migration marker"
}

# The captain-hold mutation wrapper must address the configured backend like
# the transition library does: on a beads-configured home its hold/answer/done
# calls reach tasks-axi with no markdown file override. Fully portable - the
# stubbed tasks-axi fakes the beads backend, so no bd or beads-capable install
# is needed.
test_captain_hold_mutations_address_the_beads_backend() {
  local home id fb log
  home="$TMP_ROOT/captain-stub-beads/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"
EOF
  id=fm-stub-held-row
  fb=$(fm_fakebin "$home")
  log="$home/tasks-axi-calls"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "@LOG@"
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads update received a markdown file override' >&2
        exit 1
        ;;
    esac
    stub_prev=
    stub_path=
    for stub_arg in "$@"; do
      if [ "$stub_prev" = --body-file ]; then stub_path=$stub_arg; fi
      stub_prev=$stub_arg
    done
    [ -n "$stub_path" ] && cp -- "$stub_path" "@HOME@/last-body"
    printf 'ok: update %s\n' "${2:-}"
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain' ; exit 0 ;;
      *" --file "*)
        printf '%s\n' 'error: beads hold received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: hold %s\n' "${2:-}"
    ;;
  done)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads done received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: done %s\n' "${2:-}"
    ;;
  show)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads show received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "@ID@"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain'
    if [ -f "@HOME@/last-body" ]; then
      printf '%s' '  body: '
      perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)' < "@HOME@/last-body"
      printf '\n'
    else
      printf '%s\n' '  body: ""'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s|@HOME@|$home|g; s|@ID@|$id|g; s|@LOG@|$log|g" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"

  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain must decide" >/dev/null \
    || fail "holding on a beads-configured home failed without a markdown backlog"
  assert_grep "hold $id" "$log" \
    "the captain-hold mutation never reached the configured backend"

  decision="$home/captain-decision.txt"
  printf 'Ship the gold-only plan.\n' > "$decision"
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$decision" >/dev/null \
    || fail "answering on a beads-configured home failed without a markdown backlog"
  assert_grep "update $id --body-file" "$log" \
    "the captain answer never reached the configured backend"
  assert_grep "done $id" "$log" \
    "the captain answer close never reached the configured backend"
  assert_no_grep " --file " "$log" \
    "a captain-hold mutation passed a markdown file override to a beads home"
  pass "captain-hold mutations address the beads backend without a markdown override"
}

# A Beads workspace with due.required and no types.custom captain type is the
# live fleet shape. hold must still create a fresh captain row there: waive
# due rather than invent one, and map to native type task rather than register
# a Beads captain issue type.
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type() {
  local fixture home beads id show issue_type
  require_tasks_axi_beads "captain-hold create under due.required without types.custom" || return 0
  fixture=$(make_beads_home due-required-no-custom-type)
  home=${fixture%%|*}
  beads=${fixture##*|}
  printf '\ndue:\n    required: true\n' >> "$beads/config.yaml"
  if bdrow "$beads" create "raw task" --id fm-raw-task --type task --json >/dev/null 2>&1; then
    fail "bd created a task without --due; the due.required fixture is not in force"
  fi
  if bdrow "$beads" create "raw captain" --id fm-raw-captain --type captain --due 2099-01-01 --json >/dev/null 2>&1; then
    fail "bd accepted --type captain; the fixture still has a types.custom captain registration"
  fi
  id=fm-fresh-captain-call
  run_captain "$home" hold "$id" --title "Choose the sample route" \
    --reason "captain must decide" --repo sample >/dev/null \
    || fail "hold could not create a captain row under due.required without types.custom"
  show=$(tasks_in "$home" show "$id") || fail "the created captain row is missing"
  assert_contains "$show" "hold_kind: captain" \
    "the created row is not captain-held"
  assert_contains "$show" "kind: captain" \
    "the created row lost its captain backlog kind"
  issue_type=$(bdrow "$beads" show "$id" --json \
    | jq -r 'if type == "array" then .[0].issue_type else .issue_type end')
  [ "$issue_type" = task ] \
    || fail "create did not map to native Beads type task, got ${issue_type:-empty}"
  pass "hold creates a captain row when Beads requires due and has no captain type"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-source-reconcile --title "Captain call: reconcile" \
    --reason "captain re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-bare-reconcile --title "Captain call: bare reconcile" \
    --reason "captain bare re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-shape --title "Captain call: old board shape" \
    --reason "captain old board pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile --title "Captain call: old bare reconcile" \
    --reason "captain old bare reconcile pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile-note --title "Captain call: old annotated reconcile" \
    --reason "captain old annotated reconcile pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-source-reconcile sample-bare-reconcile sample-old-shape sample-old-reconcile \
    sample-old-reconcile-note sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_shared_stub_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[13]{uid,prompt,selector,tag,text}:
  "1","Reconcile first\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile"
  "2","Membership: gold-only - captain detail\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-membership-call\",\n  \"selection\": \"gold-only\",\n  \"note\": \"captain detail\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only - captain detail"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-gated-work\",\n  \"selection\": \"go\",\n  \"note\": \"\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-nonexistent-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "7","Reconcile this - re-check latest publication\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"re-check latest publication\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile - re-check latest publication"
  "8","Second reconcile\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-bare-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(7)",choice,"Reconcile"
  "9","Headline final: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "10","Old board answer\n\nContext data:\n{\n  \"question\": \"sample-old-shape\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(8)",choice,"Old answer: yes"
  "11","Old board reconcile\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile\",\n  \"answer\": \"reconcile\"\n}","section#call > form:nth-of-type(9)",choice,"Old reconcile"
  "12","Old board reconcile note\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile-note\",\n  \"answer\": \"reconcile - verify publication\"\n}","section#call > form:nth-of-type(10)",choice,"Old reconcile note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" \
    "a repeated reconcile selection deleted another card's answer"
  assert_contains "$out" "sample-headline-call	f1-when-fp-gold" \
    "a repeated ordinary selection was not preserved"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"
  assert_not_contains "$out" "sample-source-reconcile" \
    "a reconcile selection leaked into keyed answers"
  assert_contains "$out" "sample-old-shape	yes" \
    "an ordinary legacy board choice was discarded during rollout"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile-shaped value reached keyed answers"
  out=$(run_lavish "$home" reconciles "$result") || fail "could not read captured reconcile selections"
  [ "$out" = "$(printf 'sample-source-reconcile\tre-check latest publication\nsample-bare-reconcile')" ] \
    || fail "current or legacy selections lost or invented a reconcile task id: $out"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
  reconciles) exec "$ROOT/bin/fm-procevent-lavish.sh" reconciles "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1 \
    || fail "the process-event runner failed on the fixture channel"
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  assert_contains "$show" "captain detail" "the annotated normal answer lost the captain's note"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"
  out=$(run_captain "$home" reconcile list)
  assert_contains "$out" "sample-source-reconcile" \
    "the bound captured reconcile selection did not create a request"
  assert_contains "$out" "captain note: re-check latest publication" \
    "the annotated reconcile selection lost its note provenance"
  show=$(tasks_in "$home" show sample-old-shape --full)
  assert_contains "$show" "state: done" "an ordinary legacy board choice did not close its task"
  assert_contains "$show" "Resolution mode: answered" \
    "an ordinary legacy board choice did not use the keyed-answer intake"
  show=$(tasks_in "$home" show sample-old-reconcile --full)
  assert_contains "$show" "state: queued" "a bare legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "a bare legacy reconcile value released its task"
  show=$(tasks_in "$home" show sample-old-reconcile-note --full)
  assert_contains "$show" "state: queued" "an annotated legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "an annotated legacy reconcile value released its task"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile value created a generationless request"
  show=$(tasks_in "$home" show sample-bare-reconcile --full)
  assert_contains "$show" "state: queued" "a bare captured reconcile selection closed its task"
  assert_contains "$show" "held: yes" "a bare captured reconcile selection released its task"
  printf 'The captured call is moot.\n' > "$home/source-reconcile-evidence.txt"
  run_captain "$home" reconcile close sample-source-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the annotated captured request did not authorize evidence-backed closure"
  run_captain "$home" reconcile close sample-bare-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the bare captured request did not authorize evidence-backed closure"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" answer sample-old-reconcile --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the bare legacy reconcile call"
  run_captain "$home" answer sample-old-reconcile-note --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the annotated legacy reconcile call"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# A reconcile is "go re-check reality", never the captain's answer. The value is
# reserved at the one keyed-answer intake, so no channel and no card-declared
# close mode can turn it into a close or a release, and the obligation to verify
# survives as a durable request instead of evaporating with the wake.
test_reconcile_never_closes_through_the_keyed_answer_intake() {
  local home out rc show list
  home=$(make_home reconcile-intake)
  tasks_in "$home" add sample-reconcile-call "Captain call: still current?" --repo sample >/dev/null \
    || fail "could not create the reconcile call"
  tasks_in "$home" add sample-reconcile-gated "Gated work" --repo sample >/dev/null \
    || fail "could not create the gated work item"
  run_captain "$home" hold sample-reconcile-call --reason "is this still current?" >/dev/null \
    || fail "could not hold the reconcile call"
  run_captain "$home" hold sample-reconcile-gated --reason "waiting on the captain" >/dev/null \
    || fail "could not hold the gated work item"

  set +e
  out=$(printf 'sample-reconcile-call\treconcile\tReconcile\n%s\n' \
    "$(printf 'sample-reconcile-gated\treconcile\tReconcile\trelease')" \
    | run_captain "$home" answers --source "captain chat" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the shared answer intake accepted reconcile as an answer"
  assert_contains "$out" "refused: sample-reconcile-call" \
    "the shared intake did not visibly refuse reconcile: $out"
  case "$out" in
    *"closed: sample-reconcile"*) fail "a reconcile row closed a captain call: $out" ;;
  esac

  show=$(tasks_in "$home" show sample-reconcile-call --full)
  assert_contains "$show" "state: queued" "a reconcile row completed a captain call"
  assert_contains "$show" "held: yes" "a reconcile row released a captain call"
  case "$show" in
    *"Resolution recorded by"*) fail "a reconcile row wrote a resolution record" ;;
  esac
  show=$(tasks_in "$home" show sample-reconcile-gated --full)
  assert_contains "$show" "held: yes" "a release-mode reconcile row lifted a captain hold"

  list=$(run_captain "$home" reconcile list) || fail "could not list the reconcile requests"
  assert_contains "$list" "reconcile-requests: 0" \
    "the shared answer intake created a reconcile request: $list"
  set +e
  out=$(printf 'sample-reconcile-call\n' \
    | run_captain "$home" reconcile-requests --source-id unbound-src --source "captured board" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound captured source created a reconcile request"
  request_reconciles "$home" board-src sample-reconcile-call sample-reconcile-gated \
    || fail "the bound captured source did not create reconcile requests"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-call" "the reconcile obligation was not recorded durably: $list"
  assert_contains "$list" "reconcile-requests: 2" "the reconcile requests were not both recorded: $list"

  request_reconciles "$home" board-src sample-reconcile-call \
    || fail "replaying a captured reconcile selection failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 2" "a replayed reconcile selection duplicated the obligation: $list"
  pass "only a bound captured source creates reconcile requests"
}

test_normal_answers_retire_pending_reconcile_requests() {
  local home list id
  home=$(make_home reconcile-normal-answer)
  for id in sample-direct-close sample-direct-release sample-keyed-close; do
    tasks_in "$home" add "$id" "Captain call $id" --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting for the captain" >/dev/null
  done
  request_reconciles "$home" board-src sample-direct-close sample-direct-release sample-keyed-close \
    || fail "could not create reconcile requests before normal answers"

  printf 'Captain said close.\n' > "$home/close.txt"
  printf 'Captain said release.\n' > "$home/release.txt"
  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close answer failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release answer failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed normal answer failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "normal answers left stranded reconcile requests: $list"

  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close replay failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release replay failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed answer replay failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "an idempotent normal-answer replay restored a reconcile request: $list"
  pass "normal answers and their replays retire reconcile requests"
}

# The two verification outcomes, and the honesty of the record each writes.
test_reconcile_closes_with_evidence_or_keeps_the_call_open() {
  local home show list rc out
  home=$(make_home reconcile-outcomes)
  tasks_in "$home" add sample-moot-call "Captain call: ship 0.1.37?" --repo sample >/dev/null
  tasks_in "$home" add sample-active-call "Captain call: which admission order?" --repo sample >/dev/null
  tasks_in "$home" add sample-mode-call "Captain call: verify replay mode?" --repo sample >/dev/null
  run_captain "$home" hold sample-moot-call --reason "ship 0.1.37?" >/dev/null
  run_captain "$home" hold sample-active-call --reason "which admission order?" >/dev/null
  run_captain "$home" hold sample-mode-call --reason "verify replay mode?" >/dev/null
  printf '0.1.38 was published on 2026-09-05, so the 0.1.37 question is moot.\n' > "$home/evidence.txt"
  printf 'Still open: nothing has shipped and the choice is unchanged.\n' > "$home/note.txt"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile closed a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated close refusal did not name the missing board request: $out"
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile annotated a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated note refusal did not name the missing board request: $out"

  request_reconciles "$home" board-src sample-moot-call sample-active-call sample-mode-call \
    || fail "could not file the reconcile requests"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconcile close was accepted with no evidence"
  assert_contains "$out" "evidence" "the refusal did not name the missing evidence: $out"

  cp "$home/state/reconcile-requests/sample-mode-call.request" "$home/mode-request.backup"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "could not record the normal answer for the mode fixture"
  cp "$home/mode-request.backup" "$home/state/reconcile-requests/sample-mode-call.request"
  set +e
  out=$(run_captain "$home" reconcile close sample-mode-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a normal captain answer replayed as a reconciliation"
  assert_contains "$out" "was not closed by reconciliation" \
    "the reconcile replay refusal did not identify the incompatible resolution mode: $out"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "the normal answer replay did not retire its restored pending request"

  run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "could not close the moot call with evidence"
  show=$(tasks_in "$home" show sample-moot-call --full)
  assert_contains "$show" "state: done" "the moot call did not close"
  assert_contains "$show" "Resolution mode: reconciled" "the moot call did not record how it closed"
  assert_contains "$show" "Reconciliation evidence:" "the moot call did not record the evidence"
  assert_contains "$show" "0.1.38 was published" "the recorded evidence was lost"
  case "$show" in
    *"Captain decision:"*) fail "a reconciled close was recorded as the captain's own words" ;;
  esac
  set +e
  out=$(run_captain "$home" answer sample-moot-call --decision-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconciled resolution replayed as a captain answer"
  assert_contains "$out" "not a captain-answer replay" \
    "the answer replay refusal did not identify the incompatible resolution mode: $out"

  run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" >/dev/null \
    || fail "could not annotate the still-active call"
  show=$(tasks_in "$home" show sample-active-call --full)
  assert_contains "$show" "state: queued" "annotating a still-active call closed it"
  assert_contains "$show" "held: yes" "annotating a still-active call released it"
  assert_contains "$show" "Captain hold reconciled:" "the re-check left no dated note"
  assert_contains "$show" "Still open: nothing has shipped" "the note body was lost"
  case "$show" in
    *"Resolution recorded by"*) fail "annotating a still-active call wrote a resolution record" ;;
  esac
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a retired reconcile request appended a duplicate note"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the duplicate-note refusal did not name the retired request: $out"

  printf 'sample-active-call\n' \
    | FM_CAPTAIN_HOLD_NOW=2026-09-07T06:00:00Z run_captain "$home" reconcile-requests \
        --source-id board-src --source "captured board result sequence 2" >/dev/null \
    || fail "could not create the second reconcile request"
  FM_CAPTAIN_HOLD_NOW=2026-09-07T06:01:00Z run_captain "$home" reconcile note sample-active-call \
    --note-file "$home/note.txt" >/dev/null \
    || fail "the second request with the same finding was not recorded"
  show=$(tasks_in "$home" show sample-active-call --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold reconciled:' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a later reconcile request with the same note did not append its own record"
  assert_contains "$show" "Captain hold reconciled: 2026-09-07T06:01:00Z" \
    "the second reconcile request lost its own dated note"

  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "the verified requests were not retired: $list"
  pass "reconcile closes a moot call with evidence and keeps an active one open with a note"
}

test_reconcile_outcomes_retry_partial_failures_once() {
  local home out show list rc
  home=$(make_home reconcile-partial-retry)
  tasks_in "$home" add sample-reconcile-close-retry "Close retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-note-retry "Note retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-retire-retry "Retire retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-close-retire "Close retire" --repo sample >/dev/null
  tasks_in "$home" add sample-answer-retire "Answer retire" --repo sample >/dev/null
  run_captain "$home" hold sample-reconcile-close-retry --reason "verify close" >/dev/null
  run_captain "$home" hold sample-reconcile-note-retry --reason "verify note" >/dev/null
  run_captain "$home" hold sample-reconcile-retire-retry --reason "verify retire" >/dev/null
  run_captain "$home" hold sample-reconcile-close-retire --reason "verify close retirement" >/dev/null
  run_captain "$home" hold sample-answer-retire --reason "verify answer retirement" >/dev/null
  request_reconciles "$home" board-src sample-reconcile-close-retry sample-reconcile-note-retry \
    sample-reconcile-retire-retry sample-reconcile-close-retire sample-answer-retire \
    || fail "could not create partial-retry requests"
  printf 'Verified moot.\n' > "$home/retry-evidence.txt"
  printf 'Verified active.\n' > "$home/retry-note.txt"
  printf 'Verified retirement retry.\n' > "$home/retry-retire-note.txt"
  printf 'Verified close retirement.\n' > "$home/close-retire-evidence.txt"
  printf 'Captain answered despite retirement failure.\n' > "$home/answer-retire.txt"
  fm_shared_stub "$home/fakebin" "tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-reconcile-close-retry ] \
  && [ ! -e "$FM_HOME/reconcile-close-failed" ]; then
  : > "$FM_HOME/reconcile-close-failed"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-reconcile-note-retry ]; then
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/reconcile-note-updated"
  exit 0
fi
if [ "${1:-}" = show ] && [ "${2:-}" = sample-reconcile-note-retry ] \
  && [ -e "$FM_HOME/reconcile-note-updated" ] && [ ! -e "$FM_HOME/reconcile-note-show-failed" ]; then
  : > "$FM_HOME/reconcile-note-show-failed"
  exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH

  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced reconcile close failure reported success"
  run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" >/dev/null \
    || fail "reconcile close did not recover from its partial failure"
  show=$(tasks_in "$home" show sample-reconcile-close-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Resolution mode: reconciled')" -eq 1 ] \
    || fail "reconcile close duplicated its resolution record on retry"

  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced post-note probe failure reported success"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a note retry succeeded after the request was retired"
  show=$(tasks_in "$home" show sample-reconcile-note-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "reconcile note duplicated its durable annotation"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed close request retirement reported success"
  assert_contains "$out" "sample-reconcile-close-retire" \
    "the close retirement failure did not name its task: $out"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-close-retire" \
    "the failed close retirement hid its pending request"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" >/dev/null \
    || fail "the closed reconciliation could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" answer sample-answer-retire \
    --decision-file "$home/answer-retire.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed answer-boundary retirement reported success"
  show=$(tasks_in "$home" show sample-answer-retire --full)
  assert_contains "$show" "state: done" "retirement failure reversed the durable captain answer"
  assert_contains "$show" "Captain answered despite retirement failure" \
    "retirement failure lost the durable captain answer"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" answer sample-answer-retire --decision-file "$home/answer-retire.txt" >/dev/null \
    || fail "the answer replay could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$home/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "a failed request retirement reported note success"
  assert_not_contains "$out" "still-open:" "failed retirement reported a successful outcome"
  run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" >/dev/null \
    || fail "the applied note could not finish request retirement on retry"
  show=$(tasks_in "$home" show sample-reconcile-retire-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "failed request retirement duplicated the reconcile note"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "partial retries left a reconcile request pending"
  pass "reconcile outcomes apply durable mutations once across partial failures"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_shared_stub_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# A board answer must reach the keyed-answer intake through the RUNNER, not just
# through a hand-fed `answers` call. The captain answered ten calls on a bearings
# board, the board accepted them, and nothing collected them: the source that
# collects a board is a supervised process, and while it was not running the
# board went on presenting as armed. Everything between the captured result and
# the closed task is asserted here end to end - capture, the wake that tells
# firstmate to look, and the recorded answer - because each of those was intact
# on its own while the chain as a whole delivered nothing.
test_board_answer_reaches_the_keyed_answer_intake() {
  local home sid stub out queue show
  home=$(make_home board-channel)
  sid=lavish-b0a4d0000000f1e2
  fm_test_track_procevent_home "$home" "$home/procevent-claims"

  run_captain "$home" hold sample-board-call --title "Choose the sample board route" \
    --reason "captain board route choice pending" --repo sample >/dev/null \
    || fail "could not register the board call"

  # One published Lavish poll response carrying the captain's structured answer,
  # in the shape the adapter's own reader parses: a declared field order, an
  # indented CSV row, and the versioned answer context inside its prompt.
  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-board-call\",\"selection\":\"north\",\"note\":\"\"}"
OUT
SH
  chmod +x "$stub"

  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the board source to the keyed-answer intake"

  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the board source runner did not complete: $out"
  assert_contains "$out" "$sid.1.result" "the board answer was never durably captured: $out"
  assert_contains "$out" "answers-fed: $sid" \
    "the captured board answer never reached the keyed-answer intake: $out"

  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "check: procevent lavish $sid 1" \
    "the captured board answer produced no wake: $queue"

  show=$(tasks_in "$home" show sample-board-call --full)
  assert_contains "$show" "state: done" "the board answer did not close the captain call"
  assert_contains "$show" "north" "the board answer lost the captain's selection"
  assert_contains "$show" "the captured result $sid sequence 1" \
    "the recorded answer did not name the board result that carried it"
  pass "a board answer reaches the keyed-answer intake and wakes firstmate"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show list
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" hold sample-chat-reconcile --title "Reconcile from chat" \
    --reason "captain chat reconcile pending" --repo sample >/dev/null \
    || fail "could not register the chat reconcile call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup \
    sample-chat-reconcile >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  fm_shared_stub "$fb" "tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  : > "$home/send.log"
  set +e
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-reconcile reconcile >/dev/null 2>&1
  set -e
  show=$(tasks_in "$home" show sample-chat-reconcile --full)
  assert_contains "$show" "state: queued" "a chat reconcile answer closed the call"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "a chat reconcile answer created a board request"
  printf 'Chat cannot authorize this closure.\n' > "$home/chat-reconcile.txt"
  if run_captain "$home" reconcile close sample-chat-reconcile \
    --evidence-file "$home/chat-reconcile.txt" >/dev/null 2>&1; then
    fail "a chat reconcile answer authorized evidence-backed closure"
  fi
  run_captain "$home" answer sample-chat-reconcile --decision-file "$home/chat-reconcile.txt" >/dev/null \
    || fail "could not close the chat reconcile fixture normally"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

test_retained_row_artifacts_survive_captain_answers() {
  local home retained_id precedence_id rejected_id rejected_local_id report_question_id
  local approved_id released_id local_id answered_id reportless_scout_id legacy_id
  local repo wt
  local local_repo local_wt
  local precedence_pr rejected_pr approved_pr released_pr json show
  home=$(make_home retained-row-artifacts)
  perl -0pi -e 's/done_keep = 10/done_keep = 20/' "$home/.tasks.toml"
  retained_id=sample-retained-report
  mkdir -p "$home/data/$retained_id"
  tasks_in "$home" add "$retained_id" "Investigate retained report evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the retained report fixture"
  write_origin_meta "$home" "$retained_id"
  printf 'done: report complete\n' > "$home/state/$retained_id.status"
  printf '# Retained report\n\nThe captain must choose the follow-up.\n' \
    > "$home/data/$retained_id/report.md"
  run_captain "$home" hold "$retained_id" --reason "captain must choose the report follow-up" \
    >/dev/null || fail "could not hold the retained report"
  complete_through_sibling "$home" "$retained_id" >/dev/null \
    || fail "completion gate failed for the retained report"
  run_teardown "$home" "$retained_id" > "$home/retained-teardown.out" \
    2> "$home/report-teardown.err" \
    || fail "retained report cleanup failed: $(cat "$home/report-teardown.err")"
  printf 'Proceed with the report follow-up.\n' > "$home/report-answer.txt"
  run_captain "$home" answer "$retained_id" --decision-file "$home/report-answer.txt" >/dev/null \
    || fail "could not answer the retained report call"

  precedence_id=sample-retained-report-pr-title
  precedence_pr=https://github.com/sample/sample/pull/21
  mkdir -p "$home/data/$precedence_id"
  tasks_in "$home" add "$precedence_id" "Investigate $precedence_pr regression" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the report precedence fixture"
  write_origin_meta "$home" "$precedence_id"
  printf 'done: report complete\n' > "$home/state/$precedence_id.status"
  printf '# Retained report with pull request context\n' \
    > "$home/data/$precedence_id/report.md"
  run_captain "$home" hold "$precedence_id" \
    --reason "captain must choose the report follow-up" >/dev/null \
    || fail "could not hold the report precedence fixture"
  complete_through_sibling "$home" "$precedence_id" >/dev/null \
    || fail "completion gate failed for the report precedence fixture"
  run_teardown "$home" "$precedence_id" > "$home/precedence-teardown.out" \
    2> "$home/precedence-teardown.err" \
    || fail "report precedence cleanup failed: $(cat "$home/precedence-teardown.err")"
  printf 'Proceed with the pull-request regression report.\n' \
    > "$home/precedence-answer.txt"
  run_captain "$home" answer "$precedence_id" \
    --decision-file "$home/precedence-answer.txt" >/dev/null \
    || fail "could not answer the report precedence call"
  show=$(tasks_in "$home" show "$precedence_id" --full) \
    || fail "the report precedence row disappeared"
  assert_contains "$show" "state: done" "the report precedence answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report precedence row lost its retained-scout evidence"

  rejected_id=sample-rejected-merge
  rejected_pr="https://github.com/sample/sample/pull/22"
  tasks_in "$home" add "$rejected_id" "Decide whether $rejected_pr may merge" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected merge fixture"
  run_captain "$home" hold "$rejected_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the rejected merge"
  printf 'Do not merge this pull request.\n' > "$home/rejected-answer.txt"
  run_captain "$home" answer "$rejected_id" --decision-file "$home/rejected-answer.txt" \
    >/dev/null || fail "could not record the rejected merge"
  show=$(tasks_in "$home" show "$rejected_id" --full) || fail "the rejected merge disappeared"
  assert_contains "$show" "state: done" "the rejected merge answer did not close its call"
  assert_contains "$show" "hold_kind: captain" "the rejected merge lost its non-release evidence"

  rejected_local_id=sample-rejected-local
  tasks_in "$home" add "$rejected_local_id" "Decide whether to land local main" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected local fixture"
  run_captain "$home" hold "$rejected_local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the rejected local merge"
  printf 'Do not land this change locally.\n' > "$home/rejected-local-answer.txt"
  run_captain "$home" answer "$rejected_local_id" \
    --decision-file "$home/rejected-local-answer.txt" >/dev/null \
    || fail "could not record the rejected local merge"
  show=$(tasks_in "$home" show "$rejected_local_id" --full) \
    || fail "the rejected local merge disappeared"
  assert_contains "$show" "state: done" "the rejected local answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the rejected local merge lost its non-release evidence"

  report_question_id=sample-report-path-question
  tasks_in "$home" add "$report_question_id" \
    "Decide whether data/$report_question_id/report.md should be published" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the report-path question fixture"
  run_captain "$home" hold "$report_question_id" \
    --reason "captain report publication decision pending" >/dev/null \
    || fail "could not hold the report-path question"
  printf 'Do not publish this report.\n' > "$home/report-question-answer.txt"
  run_captain "$home" answer "$report_question_id" \
    --decision-file "$home/report-question-answer.txt" >/dev/null \
    || fail "could not record the report-path answer"
  show=$(tasks_in "$home" show "$report_question_id" --full) \
    || fail "the report-path question disappeared"
  assert_contains "$show" "state: done" "the report-path answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report-path question lost its non-release evidence"

  approved_id=sample-approved-merge
  approved_pr="https://github.com/sample/sample/pull/23"
  repo="$home/projects/sample-approved"
  wt="$home/projects/$approved_id"
  fm_git_worktree "$repo" "$wt" fm/approved-merge
  tasks_in "$home" add "$approved_id" "Ship the approved pull request $approved_pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the approved merge fixture"
  fm_write_meta "$home/state/$approved_id.meta" \
    "window=firstmate:fm-$approved_id" "endpoint_task_id=$approved_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$approved_pr" "spawn_gen=fixture-$approved_id"
  printf 'done: PR %s merged\n' "$approved_pr" > "$home/state/$approved_id.status"
  run_captain "$home" hold "$approved_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the approved merge"
  printf 'Merge the approved pull request.\n' > "$home/approved-answer.txt"
  run_captain "$home" answer "$approved_id" --release \
    --decision-file "$home/approved-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$approved_id" --full) || fail "the approved merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" "merge approval retained its captain hold kind"
  run_teardown "$home" "$approved_id" > "$home/approved-teardown.out" \
    2> "$home/approved-teardown.err" \
    || fail "approved merge cleanup failed: $(cat "$home/approved-teardown.err")"

  local_id=sample-released-local
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'landed locally\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local delivery'
  tasks_in "$home" add "$local_id" "Land the approved local-only change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$home/state/$local_id.status"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the released local merge"
  printf 'Land the approved change locally.\n' > "$home/local-answer.txt"
  run_captain "$home" answer "$local_id" --release \
    --decision-file "$home/local-answer.txt" >/dev/null \
    || fail "could not release the local merge"
  show=$(tasks_in "$home" show "$local_id" --full) || fail "the released local merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "local merge approval retained its captain hold kind"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local-merge.out" 2> "$home/local-merge.err" \
    || fail "approved local merge failed: $(cat "$home/local-merge.err")"
  run_teardown "$home" "$local_id" > "$home/local-teardown.out" \
    2> "$home/local-teardown.err" \
    || fail "released local cleanup failed: $(cat "$home/local-teardown.err")"

  released_id=sample-released-report
  released_pr=https://github.com/sample/sample/pull/24
  mkdir -p "$home/data/$released_id"
  tasks_in "$home" add "$released_id" "Investigate $released_pr report evidence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the released report fixture"
  write_origin_meta "$home" "$released_id"
  printf 'done: report complete\n' > "$home/state/$released_id.status"
  printf '# Released report\n' > "$home/data/$released_id/report.md"
  run_captain "$home" hold "$released_id" --reason "captain report release pending" \
    >/dev/null || fail "could not hold the released report"
  complete_through_sibling "$home" "$released_id" >/dev/null \
    || fail "completion gate failed for the released report"
  printf 'Release the completed report.\n' > "$home/released-answer.txt"
  run_captain "$home" answer "$released_id" --release \
    --decision-file "$home/released-answer.txt" >/dev/null \
    || fail "could not release the completed report"
  run_teardown "$home" "$released_id" > "$home/released-teardown.out" \
    2> "$home/released-teardown.err" \
    || fail "released report cleanup failed: $(cat "$home/released-teardown.err")"

  answered_id=sample-artifactless-captain-answer
  tasks_in "$home" add "$answered_id" "Choose the artifactless route" --kind captain \
    --repo sample --start >/dev/null || fail "could not create the artifactless captain call"
  run_captain "$home" hold "$answered_id" --reason "captain route choice pending" \
    >/dev/null || fail "could not hold the artifactless captain call"
  printf 'Continue without a delivery artifact.\n' > "$home/artifactless-answer.txt"
  run_captain "$home" answer "$answered_id" --release \
    --decision-file "$home/artifactless-answer.txt" >/dev/null \
    || fail "could not release the artifactless captain call"
  tasks_in "$home" 'done' "$answered_id" >/dev/null \
    || fail "could not complete the released artifactless captain call"

  decision_local_id=sample-released-local-worded-decision
  tasks_in "$home" add "$decision_local_id" "Land the reviewed change" --kind ship \
    --repo sample --start >/dev/null \
    || fail "could not create the local-worded decision fixture"
  run_captain "$home" hold "$decision_local_id" --reason "captain landing route pending" \
    >/dev/null || fail "could not hold the local-worded decision fixture"
  printf 'local main\n' > "$home/local-worded-answer.txt"
  run_captain "$home" answer "$decision_local_id" --release \
    --decision-file "$home/local-worded-answer.txt" >/dev/null \
    || fail "could not release the local-worded decision fixture"
  tasks_in "$home" 'done' "$decision_local_id" >/dev/null \
    || fail "could not complete the local-worded decision fixture"

  reportless_scout_id=sample-reportless-scout
  tasks_in "$home" add "$reportless_scout_id" "Investigate without a report" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the reportless scout"
  tasks_in "$home" 'done' "$reportless_scout_id" >/dev/null \
    || fail "could not complete the reportless scout"

  legacy_id=sample-kindless-legacy-delivery
  tasks_in "$home" add "$legacy_id" "Complete the legacy work" --repo sample --start \
    >/dev/null || fail "could not create the kindless legacy delivery"
  tasks_in "$home" 'done' "$legacy_id" >/dev/null \
    || fail "could not complete the kindless legacy delivery"

  json=$(run_bearings "$home" --all-landed) \
    || fail "Bearings failed after retained delivery answers"
  printf '%s' "$json" | jq -e \
    --arg retained_id "$retained_id" --arg retained "data/$retained_id/report.md" \
    --arg precedence_id "$precedence_id" \
    --arg precedence "data/$precedence_id/report.md" \
    --arg rejected_id "$rejected_id" --arg rejected_local_id "$rejected_local_id" \
    --arg report_question_id "$report_question_id" \
    --arg approved_id "$approved_id" --arg local_id "$local_id" \
    --arg approved_pr "$approved_pr" --arg released_id "$released_id" \
    --arg answered_id "$answered_id" --arg reportless_scout_id "$reportless_scout_id" \
    --arg legacy_id "$legacy_id" --arg decision_local_id "$decision_local_id" \
    --arg released "data/$released_id/report.md" '
      (.landed | any(.id == $retained_id and .artifact == $retained))
        and (.landed | any(.id == $precedence_id and .artifact == $precedence))
        and (.landed | any(.id == $rejected_id) | not)
        and (.landed | any(.id == $rejected_local_id) | not)
        and (.landed | any(.id == $report_question_id) | not)
        and (.landed | any(.id == $approved_id and .artifact == $approved_pr))
        and (.landed | any(.id == $local_id))
        and (.landed | any(.id == $released_id and .artifact == $released))
        # Without the explicit captain-kind boundary, the artifactless answered
        # call falls through the compatibility path and this assertion fails.
        and (.landed | any(.id == $answered_id) | not)
        # Without the explicit scout-kind boundary, this row is rendered with
        # an empty artifact even though a scout has no delivery without a report.
        and (.landed | any(.id == $reportless_scout_id) | not)
        # Requiring a present non-captain kind would also remove this older
        # artifactless delivery, so the compatibility boundary stays observable.
        and (.landed | any(.id == $legacy_id))
        # The captain worded this decision "local main" and the work closed
        # with no artifact, so reading that prose as a recorded note would
        # publish a local-only landing that never happened.
        and (.landed | any(.id == $decision_local_id and .artifact == "-"))
    ' >/dev/null || fail "released, retained, or rejected deliveries were misclassified: $json"
  pass "release and scout report retention distinguish deliveries from rejected merge answers"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  git -C "$home/projects/sample" init -q || fail "could not initialize cleanup-failure project fixture"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  fm_shared_stub "$home/fakebin" "treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_shared_stub_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

test_answer_before_cleanup_replay_preserves_the_retained_report() {
  local home id wt rc bootstrap json
  home=$(make_home answer-before-cleanup-replay)
  id=sample-answer-before-cleanup-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate answer before cleanup replay" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the answer-before-replay fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Interrupted cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the answer-before-replay fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the answer-before-replay fixture"
  fm_shared_stub "$home/fakebin" "treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer before cleanup replay"
  fm_shared_stub_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e \
    --arg id "$id" --arg report "data/$id/report.md" \
    '.landed | any(.id == $id and .artifact == $report)' >/dev/null \
    || fail "the retained report disappeared when the captain answered before replay: $json"
  pass "an answer before cleanup replay preserves the retained report"
}

test_answer_before_cleanup_replay_notes_a_retained_gerrit_change() {
  local home id repo wt rc show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home answer-before-replay-gerrit)
  id=sample-answer-before-replay-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/answer-before-replay-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit answer fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  real_tasks_axi=$(command -v tasks-axi)
  fm_shared_stub "$home/fakebin" "tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  fm_shared_stub "$home/fakebin" "treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the landed change.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer a Gerrit task before cleanup replay"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered Gerrit row is gone"
  assert_contains "$show" "state: done" "the answer did not close the Gerrit row"
  assert_contains "$show" "Gerrit change $gerrit_url" \
    "the answer dropped the retained Gerrit change URL"
  pass "an answer before cleanup replay notes the retained Gerrit change"
}

test_unusable_pending_close_record_names_its_reason() {
  local home id wt rc err marker
  home=$(make_home unusable-pending-close-reason)
  id=sample-unusable-pending-close
  wt="$home/projects/$id"
  marker="$home/state/$id.backlog-close"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample" "$home/elsewhere"
  tasks_in "$home" add "$id" "Investigate the unusable pending close" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the unusable pending-close fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Unusable pending close\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the unusable pending-close fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the unusable pending-close fixture"
  fm_shared_stub "$home/fakebin" "treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$marker" "the interrupted cleanup lost its retained-artifact record"
  sed "s|^data=.*$|data=$home/elsewhere|" "$marker" > "$marker.rewritten" \
    || fail "could not rewrite the pending-close record"
  mv "$marker.rewritten" "$marker"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  set +e
  err=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the unusable pending-close record was answered as if it were valid"
  assert_contains "$err" "$marker" \
    "the refusal did not name the pending-close record the captain must repair"
  assert_contains "$err" "foreign data directory" \
    "the refusal did not name why the pending-close record could not be used"
  pass "an unusable pending-close record names its reason instead of a bare refusal"
}

test_relocated_report_does_not_wedge_an_answer_before_replay() {
  local home data id wt rc show bootstrap json
  home=$(make_home relocated-answer-before-replay)
  data="$home/données"
  mv "$home/data" "$data"
  id=sample-relocated-answer-before-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data" "$data/$id" "$wt" "$home/projects/sample"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated answer replay" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated answer-before-replay fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated interrupted cleanup\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose after relocated interrupted cleanup" >/dev/null \
    || fail "could not hold the relocated answer-before-replay fixture"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated answer-before-replay fixture"
  fm_shared_stub "$home/fakebin" "treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "relocated cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted relocated cleanup lost its pending record"

  printf 'Proceed despite the reporting limitation.\n' > "$home/answer.txt"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" \
    >/dev/null || fail "the unsupported relocated report wedged the captain's answer"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the answered relocated row disappeared"
  assert_contains "$show" "state: done" "the relocated report kept the answered call open"
  assert_contains "$show" "held: no" "the relocated report kept the answered call held"

  fm_shared_stub_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay relocated cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.meta" "session start left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the relocated pending record behind"
  json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings failed after the relocated answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" \
    '.landed | any(.id == $id) | not' >/dev/null \
    || fail "the unsupported relocated report was published as a landed delivery: $json"
  pass "an unsupported relocated report does not wedge the captain's answer"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

test_teardown_retains_a_gerrit_captain_call_with_its_change_url() {
  local home id repo wt show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home teardown-held-gerrit)
  id=sample-held-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/held-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  fm_shared_stub "$home/fakebin" "tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held Gerrit task failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held Gerrit row is gone after cleanup"
  assert_contains "$show" "state: queued" "the held Gerrit row still reads as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: Gerrit change $gerrit_url" \
    "the Gerrit change URL was not recorded on the still-open row"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  pass "cleanup keeps a captain-held Gerrit task open and records its change URL"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  fm_shared_stub "$home/fakebin" "tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

# A shown scalar field is a JSON-encoded bare string, and JSON::PP accepts one
# only when allow_nonref is on. Recent releases default it on, so this case
# forces the older default back off for every perl the command spawns - the same
# rejection a host with JSON::PP 2.27202 produces - then drives both paths that
# read a body back: holding a task for the captain, and the cleanup that retains
# a captain-held row with its deliverable.
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default() {
  local home shim id show probe scout
  home=$(make_home nonref-default)
  shim="$home/no-nonref-default"
  mkdir -p "$shim"
  cat > "$shim/FmNoNonrefDefault.pm" <<'PM'
package FmNoNonrefDefault;
require JSON::PP;
my $new = \&JSON::PP::new;
{
  no warnings 'redefine';
  *JSON::PP::new = sub { my $self = $new->(@_); $self->allow_nonref(0); $self };
}
1;
PM

  # Without this the case would pass on any decode path at all, including the
  # one this regression exists to catch.
  probe=$(printf '%s' '"probe"' | PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    perl -MJSON::PP -e 'local $/; eval { decode_json(<STDIN>) };
      print $@ ? "rejects" : "accepts";')
  [ "$probe" = rejects ] \
    || fail "the simulated older default still accepted a bare scalar"

  id=sample-nonref-body
  tasks_in "$home" add "$id" "Work carrying a body" --kind ship --repo sample \
    --body 'First line of the plan.' >/dev/null \
    || fail "could not create the task carrying a body"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_captain "$home" hold "$id" --reason "captain go needed" >/dev/null \
    || fail "a captain hold failed where allow_nonref is not on by default"
  show=$(tasks_in "$home" show "$id" --full) || fail "the held row disappeared"
  assert_contains "$show" "hold_kind: captain" "the hold lost its captain kind"
  assert_contains "$show" "Captain hold set:" "the hold lost its hold-set stamp"
  assert_contains "$show" "First line of the plan." "the hold lost the original body"

  # Cleanup reads the same body back to append the finished work's deliverable.
  scout=sample-nonref-scout
  mkdir -p "$home/data/$scout"
  tasks_in "$home" add "$scout" "Investigate the sample body decode" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Sample body decode\n\nOne captain choice remains.\n' \
    > "$home/data/$scout/report.md"
  run_captain "$home" hold "$scout" --reason "captain must choose" >/dev/null \
    || fail "could not hold the investigation for the captain"
  complete_through_sibling "$home" "$scout" >/dev/null \
    || fail "the completion gate failed with the origin as its own captain call"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_teardown "$home" "$scout" > "$home/nonref.out" 2> "$home/nonref.err" \
    || fail "cleanup of a captain-held row failed where allow_nonref is not on by default: $(cat "$home/nonref.err")"
  show=$(tasks_in "$home" show "$scout" --full) || fail "the retained row disappeared"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$scout/report.md" \
    "cleanup lost the deliverable it could not decode a body to append to"
  assert_contains "$show" "Captain hold set:" "cleanup lost the hold-set stamp"
  pass "both body-decoding paths work without the allow_nonref default"
}

# Cleanup rewrites a captain-held row's body to append the finished work's
# deliverable, so every byte of that body has to survive the decode. The
# assertions below are on bytes, not characters: a decoder that prints a
# character string to a stream with no :raw layer emits a codepoint at or below
# U+00FF as one latin-1 byte, which is not valid UTF-8, and the comparison of
# decoded strings would not notice.
#
# The two characters go in separate rows on purpose. A string that holds any
# character above U+00FF is printed as UTF-8 whatever the layer, so mixing them
# in one body hides the latin-1 case entirely.

# Take one captain-held row carrying <body> all the way through cleanup, which
# is the path that reads the body back to append the deliverable.
retain_row_with_body() {  # <home> <id> <body>
  local home=$1 id=$2 body=$3
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample body bytes" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the fixture for $id"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample body bytes\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" update "$id" --body "$body" >/dev/null \
    || fail "could not give $id a body carrying non-ASCII characters"
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold $id for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "the completion gate failed for $id"
  run_teardown "$home" "$id" > "$home/$id.out" 2> "$home/$id.err" \
    || fail "cleanup of captain-held $id failed: $(cat "$home/$id.err")"
}

test_retained_body_keeps_its_utf8_bytes() {
  local home accented wide narrow_id wide_id stored
  home=$(make_home retain-utf8)
  # Built from escapes so this file stays ASCII and the intended bytes are
  # explicit: U+00E9 is the latin-1-representable case, U+2014 the wider one.
  accented=$(printf 'caf\xc3\xa9')
  wide=$(printf '\xe2\x80\x94')
  stored="$home/data/backlog.md"

  # A body whose characters are all at or below U+00FF.
  narrow_id=sample-utf8-narrow
  retain_row_with_body "$home" "$narrow_id" "Serve the $accented black, no sugar."
  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  assert_grep "Deliverable of the finished work: report data/$narrow_id/report.md" "$stored" \
    "cleanup did not rewrite the retained body, so nothing decoded it"
  LC_ALL=C grep -qF "$accented" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character at or below U+00FF"
  ! LC_ALL=C grep -q "$(printf '[\xe9]')" "$stored" \
    || fail "the retained body holds a lone latin-1 byte, so it is no longer valid UTF-8"

  # A body carrying a character above U+00FF keeps its bytes and stays quiet.
  wide_id=sample-utf8-wide
  retain_row_with_body "$home" "$wide_id" "Serve it $wide black, no sugar."
  LC_ALL=C grep -qF "$wide" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character above U+00FF"
  assert_no_grep "Wide character" "$home/$wide_id.err" \
    "cleanup warned about a wide character instead of writing raw bytes"

  pass "cleanup preserves every byte of a retained body's non-ASCII characters"
}

set -e
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default
test_retained_body_keeps_its_utf8_bytes
test_bound_channel_answers_close_at_answer_time
test_reconcile_never_closes_through_the_keyed_answer_intake
test_normal_answers_retire_pending_reconcile_requests
test_reconcile_closes_with_evidence_or_keeps_the_call_open
test_reconcile_outcomes_retry_partial_failures_once
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_board_answer_reaches_the_keyed_answer_intake
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_teardown_never_closes_a_captain_held_task
test_retained_row_artifacts_survive_captain_answers
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_answer_before_cleanup_replay_preserves_the_retained_report
test_answer_before_cleanup_replay_notes_a_retained_gerrit_change
test_unusable_pending_close_record_names_its_reason
test_relocated_report_does_not_wedge_an_answer_before_replay
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_teardown_retains_a_gerrit_captain_call_with_its_change_url
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_verify_resolves_a_hold_migrated_to_beads_notes
test_verify_resolves_a_hold_migrated_under_the_configured_prefix
test_marker_noted_row_wins_over_a_prefix_namesake
test_complete_accepts_a_migrated_inventory_on_beads
test_verify_names_the_unresolvable_legacy_id_once
test_verify_resolves_a_pre_collapse_key_through_its_derived_marker
test_captain_hold_mutations_address_the_beads_backend
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type
