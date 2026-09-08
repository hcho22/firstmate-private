#!/usr/bin/env bash
# Filesystem, race, collision, and recovery coverage for protected evidence staging.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

SUBJECT="$ROOT/bin/fm-evidence-import-stage.py"
FIXTURE="$ROOT/tests/fixtures/evidence-import-stage/stable"
TMP_ROOT=$(fm_test_tmproot evidence-import-stage)
WORKTREE="$TMP_ROOT/project-worktree"
OUT="$TMP_ROOT/out.json"
ERR="$TMP_ROOT/err.json"

mkdir -p "$WORKTREE"
printf 'project bytes stay fixed\n' > "$WORKTREE/tracked.txt"

digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

tree_snapshot() {
  local root=$1
  {
    find "$root" -print
    find "$root" -type f -exec shasum -a 256 {} \;
  } | LC_ALL=C sort
}

copy_bundle() {
  local destination="$TMP_ROOT/$1"
  mkdir -p "$destination"
  cp -R "$FIXTURE/." "$destination/"
  printf '%s\n' "$destination"
}

write_contract() {
  local bundle=$1 destination=${2:-github-pr:hcho22/example#17} output=$3
  jq -n \
    --arg manifest "$(digest "$bundle/manifest.json")" \
    --arg report "$(digest "$bundle/report/evidence.md")" \
    --arg baseline "$(digest "$bundle/artifacts/baseline.png")" \
    --arg candidate "$(digest "$bundle/artifacts/candidate.webp")" \
    --arg destination "$destination" \
    '{
      schema_version:"1.0",
      manifest_sha256:$manifest,
      report:{path:"report/evidence.md",sha256:$report,media_type:"text/markdown"},
      artifacts:[
        {path:"artifacts/candidate.webp",sha256:$candidate,media_type:"image/webp"},
        {path:"artifacts/baseline.png",sha256:$baseline,media_type:"image/png"}
      ],
      approval_identity:"approval-fixture",
      run_binding:"run-fixture",
      reviewed_head:("e" * 40),
      destination:$destination
    }' > "$output"
}

run_stage() {
  local home=$1 contract=$2 bundle=$3 manifest=${4:-manifest.json} worktree=${5:-$WORKTREE} rc=0
  NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$bundle" \
    --manifest "$manifest" --worktree "$worktree" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_refusal() {
  local code=$1 home=$2 contract=$3 bundle=$4 description=$5
  local manifest=${6:-manifest.json} worktree=${7:-$WORKTREE} rc=0
  run_stage "$home" "$contract" "$bundle" "$manifest" "$worktree" || rc=$?
  [ "$rc" -eq 2 ] || fail "$description: expected exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$description: refusal wrote stdout"
  jq -e --arg code "$code" '.code == $code' "$ERR" >/dev/null \
    || fail "$description: expected $code, got $(cat "$ERR")"
  if [ -d "$home/evidence-imports" ]; then
    [ -z "$(find "$home/evidence-imports" -maxdepth 1 -name '.incomplete-*' -print)" ] \
      || fail "$description: handled refusal retained incomplete evidence"
  fi
}

wait_exited() {
  local pid=$1 state attempts=0
  while [ "$attempts" -lt 500 ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ') || true
    case "$state" in
      '' | Z*) return 0 ;;
    esac
    attempts=$((attempts + 1))
    sleep 0.01
  done
  return 1
}

wait_stopped() {
  local pid=$1 state attempts=0
  while [ "$attempts" -lt 500 ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ') || true
    case "$state" in
      T*) return 0 ;;
      '') fail "import process exited before the requested race point" ;;
    esac
    attempts=$((attempts + 1))
    sleep 0.01
  done
  fail "import process did not stop at the requested race point"
}

assert_no_final_import() {
  local home=$1 description=$2 count=0
  if [ -d "$home/evidence-imports" ]; then
    count=$(find "$home/evidence-imports" -mindepth 1 -maxdepth 1 -type d ! -name '.incomplete-*' | wc -l | tr -d ' ')
  fi
  [ "$count" -eq 0 ] || fail "$description: failed import published a final directory"
  [ ! -e "$home/publications" ] || fail "$description: import created publication state"
}

test_stable_bundle_and_idempotency() {
  local bundle contract home final first second
  bundle=$(copy_bundle stable-valid)
  contract="$TMP_ROOT/stable-contract.json"
  home="$TMP_ROOT/stable-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  run_stage "$home" "$contract" "$bundle" || fail "stable bundle was refused: $(cat "$ERR")"
  first=$(cat "$OUT")
  jq -e '.status == "finalized" and (.import_id | length == 64)' "$OUT" >/dev/null \
    || fail "stable import did not report atomic finalization"
  final=$(jq -r '.path' "$OUT")
  case "$final" in
    "$home"/evidence-imports/*) ;;
    *) fail "stable import finalized outside no-mistakes-owned state: $final" ;;
  esac
  case "$final" in
    "$WORKTREE"/*) fail "stable import finalized inside the project worktree" ;;
  esac
  [ "$(digest "$final/manifest.json")" = "$(digest "$bundle/manifest.json")" ] \
    || fail "final manifest bytes do not match the offered bundle"
  [ "$(digest "$final/bundle/report/evidence.md")" = "$(jq -r '.report.sha256' "$contract")" ] \
    || fail "final report does not match its contract hash"
  while IFS=$'\t' read -r path expected; do
    [ "$(digest "$final/bundle/$path")" = "$expected" ] \
      || fail "final artifact does not match its contract hash: $path"
  done < <(jq -r '.artifacts[] | [.path,.sha256] | @tsv' "$contract")
  [ ! -e "$home/publications" ] || fail "staging a stable import created publication state"

  run_stage "$home" "$contract" "$bundle" \
    || fail "identical finalized import was refused: $(cat "$ERR")"
  second=$(cat "$OUT")
  printf '%s\n' "$second" | jq -e --arg path "$final" \
    '.status == "already-finalized" and .path == $path' >/dev/null \
    || fail "identical finalized import was not deterministic and idempotent"
  [ "$(printf '%s\n' "$first" | jq -r .import_id)" = "$(printf '%s\n' "$second" | jq -r .import_id)" ] \
    || fail "identical import changed its final identity"
  pass "stable evidence finalizes outside the worktree with manifest-bound bytes and idempotency"
}

test_symlink_and_traversal_refusals() {
  local bundle contract home outside traversal
  outside="$TMP_ROOT/outside.md"
  printf 'outside bytes\n' > "$outside"

  bundle=$(copy_bundle report-symlink)
  rm "$bundle/report/evidence.md"
  ln -s "$outside" "$bundle/report/evidence.md"
  contract="$TMP_ROOT/report-symlink.json"
  write_contract "$FIXTURE" github-pr:hcho22/example#17 "$contract"
  jq --arg hash "$(digest "$outside")" '.report.sha256 = $hash' "$contract" > "$contract.tmp"
  mv "$contract.tmp" "$contract"
  home="$TMP_ROOT/report-symlink-home"
  expect_refusal unsafe-source "$home" "$contract" "$bundle" "report symlink escape"
  assert_no_final_import "$home" "report symlink escape"

  bundle=$(copy_bundle artifact-symlink)
  rm "$bundle/artifacts/baseline.png"
  ln -s "$outside" "$bundle/artifacts/baseline.png"
  contract="$TMP_ROOT/artifact-symlink.json"
  write_contract "$FIXTURE" github-pr:hcho22/example#17 "$contract"
  jq --arg hash "$(digest "$outside")" '(.artifacts[] | select(.path == "artifacts/baseline.png").sha256) = $hash' \
    "$contract" > "$contract.tmp"
  mv "$contract.tmp" "$contract"
  home="$TMP_ROOT/artifact-symlink-home"
  expect_refusal unsafe-source "$home" "$contract" "$bundle" "artifact symlink escape"
  assert_no_final_import "$home" "artifact symlink escape"

  bundle=$(copy_bundle traversal)
  contract="$TMP_ROOT/traversal.json"
  traversal="$TMP_ROOT/traversal-mutated.json"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  jq '.report.path = "../outside.md"' "$contract" > "$traversal"
  home="$TMP_ROOT/traversal-home"
  expect_refusal unsafe-path "$home" "$traversal" "$bundle" "report traversal"
  assert_no_final_import "$home" "report traversal"

  home="$TMP_ROOT/manifest-traversal-home"
  expect_refusal unsafe-path "$home" "$contract" "$bundle" "manifest traversal" ../escape
  [ ! -e "$home" ] || fail "manifest traversal prepared import state before refusal"
  pass "report and artifact symlink escapes and traversal are refused without publication"
}

test_mutation_races() {
  local bundle contract home pid rc=0

  bundle=$(copy_bundle report-mutation)
  contract="$TMP_ROOT/report-mutation.json"
  home="$TMP_ROOT/report-mutation-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  NM_HOME="$home" FM_EVIDENCE_IMPORT_TEST_STOP='after-copy:report/evidence.md' \
    "$SUBJECT" stage --contract "$contract" --bundle "$bundle" --manifest manifest.json \
    --worktree "$WORKTREE" > "$OUT" 2> "$ERR" &
  pid=$!
  wait_stopped "$pid"
  printf 'mutation\n' >> "$bundle/report/evidence.md"
  kill -CONT "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 2 ] || fail "report mutation: expected exit 2, got $rc: $(cat "$ERR")"
  jq -e '.code == "source-changed"' "$ERR" >/dev/null \
    || fail "report mutation was not identified as source drift"
  assert_no_final_import "$home" "report mutation"

  rc=0
  bundle=$(copy_bundle artifact-mutation)
  contract="$TMP_ROOT/artifact-mutation.json"
  home="$TMP_ROOT/artifact-mutation-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  NM_HOME="$home" FM_EVIDENCE_IMPORT_TEST_STOP='after-copy:artifacts/baseline.png' \
    "$SUBJECT" stage --contract "$contract" --bundle "$bundle" --manifest manifest.json \
    --worktree "$WORKTREE" > "$OUT" 2> "$ERR" &
  pid=$!
  wait_stopped "$pid"
  printf 'mutation\n' >> "$bundle/artifacts/baseline.png"
  kill -CONT "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 2 ] || fail "artifact mutation: expected exit 2, got $rc: $(cat "$ERR")"
  jq -e '.code == "source-changed"' "$ERR" >/dev/null \
    || fail "artifact mutation was not identified as source drift"
  assert_no_final_import "$home" "artifact mutation"
  pass "report and artifact mutation races cannot reach finalized staging"
}

test_path_substitution_race() {
  local bundle contract home pid rc=0
  bundle=$(copy_bundle path-substitution)
  contract="$TMP_ROOT/path-substitution.json"
  home="$TMP_ROOT/path-substitution-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  NM_HOME="$home" FM_EVIDENCE_IMPORT_TEST_STOP='after-copy:artifacts/candidate.webp' \
    "$SUBJECT" stage --contract "$contract" --bundle "$bundle" --manifest manifest.json \
    --worktree "$WORKTREE" > "$OUT" 2> "$ERR" &
  pid=$!
  wait_stopped "$pid"
  mv "$bundle/artifacts/candidate.webp" "$bundle/artifacts/candidate.original"
  cp "$bundle/artifacts/candidate.original" "$bundle/artifacts/candidate.webp"
  kill -CONT "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 2 ] || fail "path substitution: expected exit 2, got $rc: $(cat "$ERR")"
  jq -e '.code == "source-changed"' "$ERR" >/dev/null \
    || fail "regular-file path substitution was not identified as source drift"
  assert_no_final_import "$home" "path substitution"
  pass "descriptor-relative revalidation refuses path substitution during import"
}

test_collision_and_state_root_boundary() {
  local bundle contract changed home final_before final_after inside_contract inside_home
  local overlap_before overlap_after overlap_contract overlap_home overlap_worktree rc=0
  bundle=$(copy_bundle collision)
  contract="$TMP_ROOT/collision.json"
  changed="$TMP_ROOT/collision-changed.json"
  home="$TMP_ROOT/collision-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  run_stage "$home" "$contract" "$bundle" || fail "collision setup import failed"
  final_before=$(tree_snapshot "$home/evidence-imports")
  jq '.destination = "github-pr:hcho22/example#99"' "$contract" > "$changed"
  expect_refusal destination-collision "$home" "$changed" "$bundle" "non-identical destination collision"
  final_after=$(tree_snapshot "$home/evidence-imports")
  [ "$final_before" = "$final_after" ] || fail "destination collision overwrote or merged final evidence"

  inside_home="$WORKTREE/.no-mistakes"
  inside_contract="$TMP_ROOT/inside-state.json"
  write_contract "$bundle" github-pr:hcho22/example#17 "$inside_contract"
  expect_refusal unsafe-state-root "$inside_home" "$inside_contract" "$bundle" "state root inside worktree"
  [ ! -e "$inside_home" ] || fail "unsafe in-worktree state root was created before refusal"

  overlap_home="$TMP_ROOT/overlap-home"
  overlap_worktree="$overlap_home/evidence-imports"
  overlap_contract="$TMP_ROOT/overlap-state.json"
  mkdir -p "$overlap_worktree/.incomplete-project-owned"
  chmod 0700 "$overlap_home" "$overlap_worktree" "$overlap_worktree/.incomplete-project-owned"
  printf 'project-owned bytes\n' > "$overlap_worktree/.incomplete-project-owned/tracked.txt"
  write_contract "$bundle" github-pr:hcho22/example#17 "$overlap_contract"
  overlap_before=$(tree_snapshot "$overlap_home")
  run_stage "$overlap_home" "$overlap_contract" "$bundle" manifest.json "$overlap_worktree" || rc=$?
  [ "$rc" -eq 2 ] || fail "overlapping stage: expected exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "overlapping stage wrote stdout"
  jq -e '.code == "unsafe-state-root"' "$ERR" >/dev/null \
    || fail "overlapping stage did not return a structured unsafe-state-root refusal"
  overlap_after=$(tree_snapshot "$overlap_home")
  [ "$overlap_before" = "$overlap_after" ] \
    || fail "overlapping evidence import state changed the project worktree"

  rc=0
  NM_HOME="$overlap_home" "$SUBJECT" recover --worktree "$overlap_worktree" \
    > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "overlapping recovery: expected exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "overlapping recovery wrote stdout"
  jq -e '.code == "unsafe-state-root"' "$ERR" >/dev/null \
    || fail "overlapping recovery did not return a structured unsafe-state-root refusal"
  overlap_after=$(tree_snapshot "$overlap_home")
  [ "$overlap_before" = "$overlap_after" ] \
    || fail "overlapping recovery removed project-owned incomplete state"
  pass "destination collisions and either-direction state overlap refuse before mutation"
}


test_case_insensitive_state_boundary() {
  local actual variant bundle contract home before after
  actual="$TMP_ROOT/Case-Project"
  variant="$TMP_ROOT/case-project"
  mkdir -p "$actual"
  if [ ! -d "$variant" ]; then
    pass "case-insensitive state overlap regression is not applicable on this filesystem"
    return
  fi

  bundle=$(copy_bundle case-insensitive-overlap)
  contract="$TMP_ROOT/case-insensitive-overlap.json"
  home="$variant/.import-state"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  before=$(tree_snapshot "$actual")
  expect_refusal unsafe-state-root "$home" "$contract" "$bundle" \
    "case-insensitive state root inside worktree" manifest.json "$actual"
  after=$(tree_snapshot "$actual")
  [ "$before" = "$after" ] \
    || fail "alternate-case state root spelling changed the project worktree"
  pass "inode ancestry refuses alternate-case worktree and import overlap"
}


test_replaceable_state_ancestor_refusal() {
  local after before home rc=0 replaceable_root
  replaceable_root="$TMP_ROOT/replaceable-root"
  home="$replaceable_root/parent/state"
  mkdir -p "$replaceable_root"
  chmod 0770 "$replaceable_root"
  printf 'ancestor sentinel\n' > "$replaceable_root/sentinel.txt"
  before=$(tree_snapshot "$replaceable_root")

  NM_HOME="$home" "$SUBJECT" recover --worktree "$WORKTREE" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "replaceable state ancestor: expected exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "replaceable state ancestor wrote stdout"
  jq -e '.code == "unsafe-state-root"' "$ERR" >/dev/null \
    || fail "replaceable state ancestor did not return a structured refusal"
  [ ! -e "$home" ] || fail "replaceable state ancestor created NM_HOME before refusal"
  after=$(tree_snapshot "$replaceable_root")
  [ "$before" = "$after" ] \
    || fail "replaceable state ancestor changed before refusal"
  pass "replaceable state ancestors refuse before mutation"
}


test_unsafe_state_permissions() {
  local bundle contract home lock mode target
  bundle=$(copy_bundle unsafe-permissions)
  contract="$TMP_ROOT/unsafe-permissions.json"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"

  for mode in 0730 0703; do
    home="$TMP_ROOT/unsafe-root-$mode"
    mkdir -p "$home"
    chmod "$mode" "$home"
    expect_refusal unsafe-state-root "$home" "$contract" "$bundle" "writable state root mode $mode"
    [ ! -e "$home/evidence-imports" ] \
      || fail "writable state root mode $mode created evidence import state"
  done

  for mode in 0730 0703; do
    home="$TMP_ROOT/unsafe-imports-$mode"
    target="$home/evidence-imports"
    mkdir -p "$target"
    chmod 0700 "$home"
    chmod "$mode" "$target"
    expect_refusal unsafe-state-root "$home" "$contract" "$bundle" \
      "writable evidence import directory mode $mode"
    [ ! -e "$target/.lock" ] \
      || fail "writable evidence import directory mode $mode created the lock"
  done

  for mode in 0620 0602; do
    home="$TMP_ROOT/unsafe-lock-$mode"
    lock="$home/evidence-imports/.lock"
    mkdir -p "$home/evidence-imports"
    chmod 0700 "$home" "$home/evidence-imports"
    : > "$lock"
    chmod "$mode" "$lock"
    expect_refusal unsafe-state-root "$home" "$contract" "$bundle" \
      "writable evidence import lock mode $mode"
    assert_no_final_import "$home" "writable evidence import lock mode $mode"
  done
  pass "group- and world-writable import state and locks are refused"
}


test_fifo_substitution_refusals() {
  local bundle contract description fifo home pid rc recovery
  for description in report artifact; do
    bundle=$(copy_bundle "$description-fifo")
    contract="$TMP_ROOT/$description-fifo.json"
    home="$TMP_ROOT/$description-fifo-home"
    if [ "$description" = report ]; then
      fifo="$bundle/report/evidence.md"
    else
      fifo="$bundle/artifacts/baseline.png"
    fi
    rm "$fifo"
    mkfifo "$fifo"
    write_contract "$FIXTURE" github-pr:hcho22/example#17 "$contract"
    rc=0
    NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$bundle" \
      --manifest manifest.json --worktree "$WORKTREE" > "$OUT" 2> "$ERR" &
    pid=$!
    if ! wait_exited "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "$description FIFO substitution blocked while holding the import lock"
    fi
    wait "$pid" || rc=$?
    [ "$rc" -eq 2 ] || fail "$description FIFO: expected exit 2, got $rc: $(cat "$ERR")"
    jq -e '.code == "unsafe-source"' "$ERR" >/dev/null \
      || fail "$description FIFO did not return a structured unsafe-source refusal"
    assert_no_final_import "$home" "$description FIFO substitution"
    recovery=$(NM_HOME="$home" "$SUBJECT" recover --worktree "$WORKTREE") \
      || fail "$description FIFO left recovery blocked"
    printf '%s\n' "$recovery" | jq -e '.status == "recovered" and .removed == 0' >/dev/null \
      || fail "$description FIFO recovery returned an unexpected result"
  done
  pass "report and artifact FIFO substitutions fail promptly without retaining the lock"
}


test_bounded_failure_state() {
  local bundle contract home
  bundle=$(copy_bundle oversized)
  contract="$TMP_ROOT/oversized.json"
  home="$TMP_ROOT/oversized-home"
  dd if=/dev/zero of="$bundle/artifacts/baseline.png" bs=1 count=0 seek=67108865 2>/dev/null \
    || fail "could not prepare oversized regular-file fixture"
  write_contract "$FIXTURE" github-pr:hcho22/example#17 "$contract"
  expect_refusal source-too-large "$home" "$contract" "$bundle" "oversized regular bundle member"
  assert_no_final_import "$home" "oversized regular bundle member"
  pass "handled failures retain no unbounded staged or publication state"
}


test_interruption_and_recovery() {
  local bundle contract home pid recovery rc=0
  bundle=$(copy_bundle interrupted)
  contract="$TMP_ROOT/interrupted.json"
  home="$TMP_ROOT/interrupted-home"
  write_contract "$bundle" github-pr:hcho22/example#17 "$contract"
  NM_HOME="$home" FM_EVIDENCE_IMPORT_TEST_STOP=before-finalize \
    "$SUBJECT" stage --contract "$contract" --bundle "$bundle" --manifest manifest.json \
    --worktree "$WORKTREE" > "$OUT" 2> "$ERR" &
  pid=$!
  wait_stopped "$pid"
  [ -n "$(find "$home/evidence-imports" -maxdepth 1 -name '.incomplete-*' -type d -print)" ] \
    || fail "pre-finalization interruption left no recoverable incomplete state"
  assert_no_final_import "$home" "pre-finalization interruption"
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "SIGKILL interruption unexpectedly exited successfully"

  recovery=$(NM_HOME="$home" "$SUBJECT" recover --worktree "$WORKTREE") \
    || fail "restart recovery failed"
  printf '%s\n' "$recovery" | jq -e '.status == "recovered" and .removed == 1' >/dev/null \
    || fail "restart recovery did not account for the incomplete import"
  [ -z "$(find "$home/evidence-imports" -maxdepth 1 -name '.incomplete-*' -print)" ] \
    || fail "restart recovery retained incomplete evidence"
  assert_no_final_import "$home" "restart recovery"
  pass "interruption immediately before rename remains unpublished and recovery removes it"
}

before_worktree=$(tree_snapshot "$WORKTREE")
test_stable_bundle_and_idempotency
test_symlink_and_traversal_refusals
test_mutation_races
test_path_substitution_race
test_collision_and_state_root_boundary
test_case_insensitive_state_boundary
test_replaceable_state_ancestor_refusal
test_unsafe_state_permissions
test_fifo_substitution_refusals
test_bounded_failure_state
test_interruption_and_recovery
after_worktree=$(tree_snapshot "$WORKTREE")
[ "$before_worktree" = "$after_worktree" ] || fail "evidence imports changed the project worktree"
pass "all import cases leave the project worktree byte-for-byte unchanged"
