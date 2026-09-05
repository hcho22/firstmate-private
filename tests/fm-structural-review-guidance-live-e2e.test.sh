#!/usr/bin/env bash
# Opt-in behavioral evaluation for conditional Structural Review guidance.
# It gives the directly loaded guidance triggered and ordinary-change fixtures,
# then verifies both the scope boundary and the conditional trigger.
set -u

if [ "${FM_STRUCTURAL_REVIEW_GUIDANCE_EVAL:-0}" != 1 ]; then
  echo "skip: set FM_STRUCTURAL_REVIEW_GUIDANCE_EVAL=1 and FM_STRUCTURAL_REVIEW_LOCAL_MODEL=<model> to run the local instruction evaluation"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUIDANCE="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-structural-review-guidance)
TRIGGERED_FIXTURE="$TMP_ROOT/competing-owner.txt"
ORDINARY_FIXTURE="$TMP_ROOT/ordinary-copy-edit.txt"
TRIGGERED_RESPONSE="$TMP_ROOT/competing-owner.json"
ORDINARY_RESPONSE="$TMP_ROOT/ordinary-copy-edit.json"

command -v curl >/dev/null 2>&1 || fail "curl is required for the local instruction evaluation"
command -v jq >/dev/null 2>&1 || fail "jq is required for the local instruction evaluation"
curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags > "$TMP_ROOT/tags.json" \
  || fail "local Ollama is unavailable at 127.0.0.1:11434; no remote provider fallback is allowed"

MODEL=${FM_STRUCTURAL_REVIEW_LOCAL_MODEL:-}
[ -n "$MODEL" ] || fail "FM_STRUCTURAL_REVIEW_LOCAL_MODEL must name an explicit local evaluator"
jq -e --arg model "$MODEL" '.models | any(.name == $model)' "$TMP_ROOT/tags.json" >/dev/null \
  || fail "requested local Ollama model is unavailable: $MODEL"

cat > "$TRIGGERED_FIXTURE" <<'FIXTURE'
case_id: competing-owner
requested_change: Add token rotation to bin/token-refresh.sh.
responsibility auth.rotation: bin/token-refresh.sh chooses the renewal threshold, requests a replacement token, and persists it.
responsibility auth.rotation: bin/session-auth.sh separately chooses the renewal threshold, requests a replacement token, and persists it.
responsibility display.date: bin/report-time.sh defines a helper that converts a Unix timestamp to YYYY-MM-DD.
responsibility display.date: bin/status-time.sh defines its own helper that converts a Unix timestamp to YYYY-MM-DD.
change_boundary: Neither display script is called by the token code or changed by the request.
FIXTURE

cat > "$ORDINARY_FIXTURE" <<'FIXTURE'
case_id: ordinary-copy-edit
requested_change: Correct the user-facing word "retrys" to "retries" in bin/upload.sh.
change_boundary: No control flow, data transformation, ownership, or call relationship changes.
FIXTURE

run_evaluation() {
  local fixture=$1 response=$2 case_id prompt_file payload
  case_id=$(sed -n 's/^case_id: //p' "$fixture")
  prompt_file="$TMP_ROOT/$case_id.prompt.txt"
  {
    printf '%s\n' 'Act only as a reviewer applying the directly loaded coding guidance below.'
    printf '%s\n' 'Evaluate the fixture facts without assuming a desired outcome.'
    printf '%s\n' 'Return only one JSON object with this schema:'
    printf '%s\n' 'case_id: copy the fixture case_id.'
    printf '%s\n' 'review_depth: either ordinary or structural.'
    printf '%s\n' 'focus: a responsibility id from the fixture, or null.'
    printf '%s\n' 'assessments: an array of structural concerns; each item has id (a responsibility id), relationship_to_request (affected or unrelated), disposition (required, recommendation, or none), and resulting_owner_count (a nonnegative integer or null).'
    printf '%s\n' 'abstraction: an object with proposed (boolean), basis_responsibility (a responsibility id or null), and basis_condition (competing-implementations, duplicated-mechanics, unclear-ownership, other-concrete-need, review-routine-only, or none).'
    printf '%s\n' 'FIXTURE START'
    cat "$fixture"
    printf '%s\n' 'FIXTURE END'
    printf '%s\n' 'GUIDANCE START'
    cat "$GUIDANCE"
    printf '%s\n' 'GUIDANCE END'
  } > "$prompt_file"

  payload=$(jq -n \
    --arg model "$MODEL" \
    --rawfile prompt "$prompt_file" \
    '{model:$model,prompt:$prompt,stream:false,format:"json",options:{temperature:0,num_predict:1024}}')
  curl -fsS --max-time "${FM_STRUCTURAL_REVIEW_EVAL_TIMEOUT_SECONDS:-120}" \
    -H 'Content-Type: application/json' \
    -d "$payload" http://127.0.0.1:11434/api/generate \
    | jq -er '.response | fromjson' > "$response" \
    || fail "local model $MODEL did not return parseable Structural Review JSON for $case_id"
}

run_evaluation "$TRIGGERED_FIXTURE" "$TRIGGERED_RESPONSE"
run_evaluation "$ORDINARY_FIXTURE" "$ORDINARY_RESPONSE"

jq -e '
  .case_id == "competing-owner" and
  .review_depth == "structural" and
  .focus == "auth.rotation" and
  ([.assessments[]? | select(
    .id == "auth.rotation" and
    .relationship_to_request == "affected" and
    .disposition == "required" and
    .resulting_owner_count == 1
  )] | length) == 1 and
  ([.assessments[]? | select(
    .id == "display.date" and
    .relationship_to_request == "unrelated" and
    .disposition == "recommendation"
  )] | length) == 1 and
  ([.assessments[]? | select(.id != "auth.rotation" and .id != "display.date")] | length) == 0 and
  ([.assessments[]? | select(
    .disposition == "required" and
    (.id != "auth.rotation" or .relationship_to_request != "affected")
  )] | length) == 0 and
  (.abstraction |
    if .proposed then
      .basis_responsibility == "auth.rotation" and
      .basis_condition == "competing-implementations"
    else
      .basis_responsibility == null and .basis_condition == "none"
    end
  )
' "$TRIGGERED_RESPONSE" >/dev/null \
  || fail "local model $MODEL did not restore one affected owner, keep unrelated duplication advisory, and reject routine-only abstraction"

jq -e '
  .case_id == "ordinary-copy-edit" and
  .review_depth == "ordinary" and
  .focus == null and
  ([.assessments[]? | select(.disposition != "none")] | length) == 0 and
  .abstraction.proposed == false and
  .abstraction.basis_responsibility == null and
  .abstraction.basis_condition == "none"
' "$ORDINARY_RESPONSE" >/dev/null \
  || fail "local model $MODEL activated Structural Review for an ordinary change"

pass "local model $MODEL applied Structural Review only to the competing-owner fixture"
