#!/usr/bin/env bash
# Authorization and security regressions for protected Evidence Import Consent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

SUBJECT="$ROOT/bin/fm-evidence-import-stage.py"
FIXTURE="$ROOT/tests/fixtures/evidence-import-stage/stable"
TMP_ROOT=$(fm_test_tmproot evidence-import-authorization)
WORKTREE="$TMP_ROOT/project-worktree"
BUNDLE="$TMP_ROOT/bundle"
OUT="$TMP_ROOT/out.json"
ERR="$TMP_ROOT/err.json"
ZERO_CONSENT_ID=$(printf '%064d' 0)

mkdir -p "$WORKTREE" "$BUNDLE"
cp -R "$FIXTURE/." "$BUNDLE/"
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

write_contract() {
  local output=$1
  jq -n \
    --arg manifest "$(digest "$BUNDLE/manifest.json")" \
    --arg report "$(digest "$BUNDLE/report/evidence.md")" \
    --arg baseline "$(digest "$BUNDLE/artifacts/baseline.png")" \
    --arg candidate "$(digest "$BUNDLE/artifacts/candidate.webp")" \
    '{
      schema_version:"1.0",
      manifest_sha256:$manifest,
      report:{path:"report/evidence.md",sha256:$report,media_type:"text/markdown"},
      artifacts:[
        {path:"artifacts/candidate.webp",sha256:$candidate,media_type:"image/webp"},
        {path:"artifacts/baseline.png",sha256:$baseline,media_type:"image/png"}
      ],
      approval_identity:"approval-security-fixture",
      run_binding:"run-security-fixture",
      reviewed_head:("e" * 40),
      destination:"github-pr:hcho22/example#17"
    }' > "$output"
}

write_control_record() {
  local home=$1 contract=$2 batch=$3 name=$4
  mkdir -p "$home/evidence-import-control"
  chmod 0700 "$home" "$home/evidence-import-control"
  write_control_payload "$home/evidence-import-control/$name" "$contract" "$batch"
}

write_control_payload() {
  local output=$1 contract=$2 batch=$3
  jq -n --slurpfile contract "$contract" --arg batch "$batch" '{
    schema_version:"1.0",
    decision:"evidence-import-consent",
    batch:$batch,
    contract:$contract[0]
  }' > "$output"
  chmod 0600 "$output"
}

admit() {
  local home=$1 name=$2 rc=0
  NM_HOME="$home" "$SUBJECT" admit --control-record "$name" --worktree "$WORKTREE" \
    > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

run_stage() {
  local home=$1 contract=$2 batch=$3 consent_id=${4:-} rc=0
  if [ -n "$consent_id" ]; then
    NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
      --manifest manifest.json --batch "$batch" --consent-id "$consent_id" \
      --worktree "$WORKTREE" > "$OUT" 2> "$ERR" || rc=$?
  else
    NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
      --manifest manifest.json --batch "$batch" --worktree "$WORKTREE" \
      > "$OUT" 2> "$ERR" || rc=$?
  fi
  return "$rc"
}

expect_refusal() {
  local expected=$1 description=$2 rc=${3:-0}
  [ "$rc" -eq 2 ] || fail "$description: expected exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$description: refusal wrote stdout"
  jq -e --arg code "$expected" '.code == $code and (.message | type == "string" and length > 0)' \
    "$ERR" >/dev/null || fail "$description: expected $expected, got $(cat "$ERR")"
}

assert_no_final_import() {
  local home=$1 description=$2 count=0
  if [ -d "$home/evidence-imports" ]; then
    count=$(find "$home/evidence-imports" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
      | wc -l | tr -d ' ')
  fi
  [ "$count" -eq 0 ] || fail "$description: unauthorized evidence reached finalized staging"
  [ ! -e "$home/publications" ] || fail "$description: unauthorized publication state exists"
}

wait_stopped() {
  local pid=$1 state attempts=0
  while [ "$attempts" -lt 500 ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ') || true
    case "$state" in
      T*) return 0 ;;
      '') fail "consent process exited before the requested recovery point" ;;
    esac
    attempts=$((attempts + 1))
    sleep 0.01
  done
  fail "consent process did not stop at the requested recovery point"
}

test_exact_consent_stages_without_publication() {
  local after before consent_id contract consumed home normalized pending rc=0
  home="$TMP_ROOT/exact-home"
  contract="$TMP_ROOT/exact-contract.json"
  normalized="$TMP_ROOT/exact-contract-normalized.json"
  write_contract "$contract"
  "$ROOT/bin/fm-evidence-import-contract.py" --file "$contract" > "$normalized"
  write_control_record "$home" "$contract" batch-exact exact.json
  before=$(tree_snapshot "$WORKTREE")
  admit "$home" exact.json || fail "exact protected consent was refused: $(cat "$ERR")"
  consent_id=$(jq -r .consent_id "$OUT")
  pending="$home/evidence-imports/.consents/pending/$consent_id.json"
  consumed="$home/evidence-imports/.consents/consumed/$consent_id.json"
  [ -f "$pending" ] || fail "admission did not create one pending protected consent"
  [ ! -e "$home/evidence-import-control/exact.json" ] \
    || fail "admission did not consume its protected control record"
  jq -e --slurpfile contract "$normalized" '
    .schema_version == "1.0" and
    .decision == "evidence-import-consent" and
    .batch == "batch-exact" and
    .contract == $contract[0]
  ' "$pending" >/dev/null || fail "pending consent omitted or changed an exact binding"

  run_stage "$home" "$contract" batch-exact "$consent_id" \
    || fail "exact admitted consent did not permit staging: $(cat "$ERR")"
  jq -e --arg consent "$consent_id" '
    .status == "finalized" and
    .batch == "batch-exact" and
    .consent_id == $consent and
    .consent_status == "consumed" and
    .publication_authorized == false
  ' "$OUT" >/dev/null || fail "staging output did not preserve exact consent-only semantics"
  [ ! -e "$pending" ] && [ -f "$consumed" ] \
    || fail "successful staging did not consume consent exactly once"
  [ ! -e "$home/publications" ] || fail "consent created publication state"
  after=$(tree_snapshot "$WORKTREE")
  [ "$before" = "$after" ] || fail "consented staging changed the project worktree"

  run_stage "$home" "$contract" batch-exact "$consent_id" || rc=$?
  expect_refusal consent-already-consumed "already-consumed stage" "$rc"
  write_control_record "$home" "$contract" batch-exact replay.json
  rc=0
  admit "$home" replay.json || rc=$?
  expect_refusal consent-replayed "consent control replay" "$rc"
  pass "exact protected consent permits staging once without publication authority"
}

test_binding_drift_refusals() {
  local batch consent_id contract description home mutated rc=0
  home="$TMP_ROOT/drift-home"
  contract="$TMP_ROOT/drift-contract.json"
  mutated="$TMP_ROOT/drift-mutated.json"
  batch='batch-drift'
  write_contract "$contract"
  write_control_record "$home" "$contract" "$batch" drift.json
  admit "$home" drift.json || fail "drift fixture consent admission failed: $(cat "$ERR")"
  consent_id=$(jq -r .consent_id "$OUT")

  run_stage "$home" "$contract" changed-batch "$consent_id" || rc=$?
  expect_refusal consent-mismatch "batch drift" "$rc"
  rc=0
  while IFS=$'\t' read -r description filter; do
    jq "$filter" "$contract" > "$mutated"
    run_stage "$home" "$mutated" "$batch" "$consent_id" || rc=$?
    expect_refusal consent-mismatch "$description" "$rc"
    assert_no_final_import "$home" "$description"
    rc=0
  done <<'EOF'
manifest hash drift	.manifest_sha256 = ("1" * 64)
report path drift	.report.path = "report/changed.md"
report hash drift	.report.sha256 = ("2" * 64)
artifact path drift	.artifacts[0].path = "artifacts/changed.webp"
artifact hash drift	.artifacts[0].sha256 = ("3" * 64)
approval identity drift	.approval_identity = "approval-changed"
destination drift	.destination = "github-pr:hcho22/example#99"
run drift	.run_binding = "run-changed"
reviewed head drift	.reviewed_head = ("4" * 40)
EOF

  run_stage "$home" "$contract" "$batch" "$consent_id" \
    || fail "exact consent stopped working after drift refusals: $(cat "$ERR")"
  pass "every batch, report, artifact, destination, run, and head binding is revalidated"
}

test_project_configuration_and_automatic_forgery() {
  local contract fake_approval forge home rc=0
  home="$TMP_ROOT/forgery-home"
  contract="$TMP_ROOT/forgery-contract.json"
  fake_approval="$WORKTREE/project-approval.json"
  forge="$WORKTREE/forge-import.sh"
  write_contract "$contract"
  jq -n --arg consent "$ZERO_CONSENT_ID" \
    '{approved:true,consent_id:$consent,automatic_approval:true}' > "$fake_approval"
  git init -q "$WORKTREE"
  git -C "$WORKTREE" config evidence.importConsent true
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "\"\$1\" stage --contract \"\$2\" --bundle \"\$3\" --manifest manifest.json --batch project-forged --consent-id \"\$4\" --worktree \"\$5\"" \
    > "$forge"
  chmod +x "$forge"

  NM_HOME="$home" EVIDENCE_IMPORT_CONSENT=1 NO_MISTAKES_AUTO_APPROVE=1 \
    NO_MISTAKES_APPROVAL_FILE="$fake_approval" \
    "$forge" "$SUBJECT" "$contract" "$BUNDLE" "$ZERO_CONSENT_ID" "$WORKTREE" \
    > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal consent-missing "project-code and environment forgery" "$rc"
  assert_no_final_import "$home" "project-code and environment forgery"

  rc=0
  NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
    --manifest manifest.json --batch project-forged --worktree "$WORKTREE" \
    > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal consent-missing "repository configuration forgery" "$rc"

  rc=0
  NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
    --manifest manifest.json --batch project-forged --consent-id "$ZERO_CONSENT_ID" \
    --worktree "$WORKTREE" --yes > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal invalid-arguments "--yes automatic approval forgery" "$rc"

  rc=0
  NM_HOME="$home" "$SUBJECT" admit --control-record "$fake_approval" --worktree "$WORKTREE" \
    > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal invalid-control-record-name "project approval path admission" "$rc"
  assert_no_final_import "$home" "configuration and automatic-approval forgery"
  pass "project code, project JSON, configuration, environment, and --yes grant no authority"
}

test_protected_control_boundary() {
  local contract hardlink_home project_record rc=0 symlink_home writable_home
  contract="$TMP_ROOT/control-boundary-contract.json"
  project_record="$WORKTREE/forged-control.json"
  write_contract "$contract"
  write_control_payload "$project_record" "$contract" batch-control-boundary

  symlink_home="$TMP_ROOT/control-symlink-home"
  mkdir -p "$symlink_home/evidence-import-control"
  chmod 0700 "$symlink_home" "$symlink_home/evidence-import-control"
  ln -s "$project_record" "$symlink_home/evidence-import-control/forged.json"
  admit "$symlink_home" forged.json || rc=$?
  expect_refusal unsafe-control-state "project symlink control forgery" "$rc"
  assert_no_final_import "$symlink_home" "project symlink control forgery"

  hardlink_home="$TMP_ROOT/control-hardlink-home"
  mkdir -p "$hardlink_home/evidence-import-control"
  chmod 0700 "$hardlink_home" "$hardlink_home/evidence-import-control"
  ln "$project_record" "$hardlink_home/evidence-import-control/forged.json"
  rc=0
  admit "$hardlink_home" forged.json || rc=$?
  expect_refusal unsafe-control-state "project hard-link control forgery" "$rc"
  assert_no_final_import "$hardlink_home" "project hard-link control forgery"

  writable_home="$TMP_ROOT/control-writable-home"
  write_control_record "$writable_home" "$contract" batch-control-boundary forged.json
  chmod 0770 "$writable_home/evidence-import-control"
  rc=0
  admit "$writable_home" forged.json || rc=$?
  expect_refusal unsafe-control-state "shared-writable control directory" "$rc"
  assert_no_final_import "$writable_home" "shared-writable control directory"
  pass "only descriptor-bound protected local control records can enter consent state"
}

test_validation_gate_descendants_cannot_admit() {
  local consent_id contract gate_home gate_worktree home rc=0
  home="$TMP_ROOT/gate-refusal-home"
  contract="$TMP_ROOT/gate-refusal-contract.json"
  write_contract "$contract"
  write_control_record "$home" "$contract" batch-gate gate.json

  NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=1 NM_HOME="$home" \
    "$SUBJECT" admit --control-record gate.json --worktree "$WORKTREE" \
    > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal validation-descendant "validation marker descendant" "$rc"
  [ -f "$home/evidence-import-control/gate.json" ] \
    || fail "validation descendant changed the protected control record"
  assert_no_final_import "$home" "validation marker descendant"

  gate_home="$TMP_ROOT/gate-context/.no-mistakes"
  gate_worktree="$gate_home/worktrees/project/run"
  mkdir -p "$gate_home/repos" "$gate_home/worktrees/project"
  git init -q --separate-git-dir="$gate_home/repos/project.git" "$gate_worktree"
  rc=0
  (
    cd "$gate_worktree" || exit 1
    env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 NM_HOME="$home" \
      "$SUBJECT" admit --control-record gate.json --worktree "$WORKTREE"
  ) > "$OUT" 2> "$ERR" || rc=$?
  expect_refusal validation-descendant "validation worktree descendant" "$rc"
  [ -f "$home/evidence-import-control/gate.json" ] \
    || fail "validation worktree descendant changed the protected control record"

  admit "$home" gate.json || fail "ordinary host could not admit consent after gate refusals"
  consent_id=$(jq -r .consent_id "$OUT")
  run_stage "$home" "$contract" batch-gate "$consent_id" \
    || fail "gate-refused consent could not later stage through the legitimate path"
  pass "environment and filesystem gate descendants cannot use the consent interface"
}

test_concurrent_and_interrupted_consumption() {
  local consent_id contract failure home interrupted_home interrupted_id pid_one pid_two recovery rc=0 rc_one=0 rc_two=0
  home="$TMP_ROOT/concurrent-home"
  contract="$TMP_ROOT/concurrent-contract.json"
  write_contract "$contract"
  write_control_record "$home" "$contract" batch-concurrent concurrent.json
  admit "$home" concurrent.json || fail "concurrent fixture consent admission failed"
  consent_id=$(jq -r .consent_id "$OUT")

  NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
    --manifest manifest.json --batch batch-concurrent --consent-id "$consent_id" \
    --worktree "$WORKTREE" > "$TMP_ROOT/concurrent-one.out" 2> "$TMP_ROOT/concurrent-one.err" &
  pid_one=$!
  NM_HOME="$home" "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" \
    --manifest manifest.json --batch batch-concurrent --consent-id "$consent_id" \
    --worktree "$WORKTREE" > "$TMP_ROOT/concurrent-two.out" 2> "$TMP_ROOT/concurrent-two.err" &
  pid_two=$!
  wait "$pid_one" || rc_one=$?
  wait "$pid_two" || rc_two=$?
  case "$rc_one:$rc_two" in
    0:2) failure="$TMP_ROOT/concurrent-two.err" ;;
    2:0) failure="$TMP_ROOT/concurrent-one.err" ;;
    *) fail "concurrent stage callers returned $rc_one and $rc_two instead of one success" ;;
  esac
  jq -e '.code == "consent-already-consumed"' "$failure" >/dev/null \
    || fail "concurrent losing caller did not observe atomic one-time consumption"

  interrupted_home="$TMP_ROOT/interrupted-consume-home"
  write_control_record "$interrupted_home" "$contract" batch-interrupted-consume interrupted.json
  admit "$interrupted_home" interrupted.json || fail "interrupted fixture consent admission failed"
  interrupted_id=$(jq -r .consent_id "$OUT")
  NM_HOME="$interrupted_home" FM_EVIDENCE_IMPORT_TEST_STOP=after-consume-before-finalize \
    "$SUBJECT" stage --contract "$contract" --bundle "$BUNDLE" --manifest manifest.json \
    --batch batch-interrupted-consume --consent-id "$interrupted_id" --worktree "$WORKTREE" \
    > "$OUT" 2> "$ERR" &
  pid_one=$!
  wait_stopped "$pid_one"
  kill -KILL "$pid_one"
  wait "$pid_one" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted consume fixture exited successfully"
  [ -f "$interrupted_home/evidence-imports/.consents/consumed/$interrupted_id.json" ] \
    || fail "interrupted finalization did not durably consume consent first"
  assert_no_final_import "$interrupted_home" "interrupted post-consume finalization"
  rc=0
  run_stage "$interrupted_home" "$contract" batch-interrupted-consume "$interrupted_id" || rc=$?
  expect_refusal consent-already-consumed "interrupted consumed consent replay" "$rc"
  recovery=$(NM_HOME="$interrupted_home" "$SUBJECT" recover --worktree "$WORKTREE") \
    || fail "interrupted post-consume recovery failed"
  printf '%s\n' "$recovery" | jq -e '.status == "recovered" and .removed == 1' >/dev/null \
    || fail "interrupted post-consume recovery did not remove incomplete staging"
  assert_no_final_import "$interrupted_home" "recovered post-consume finalization"
  pass "concurrent callers consume once and interrupted finalization fails closed"
}

test_exact_consent_stages_without_publication
test_binding_drift_refusals
test_project_configuration_and_automatic_forgery
test_protected_control_boundary
test_validation_gate_descendants_cannot_admit
test_concurrent_and_interrupted_consumption
