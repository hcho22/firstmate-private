#!/usr/bin/env bash
# Opt-in behavioral evaluation for conditional Structural Review guidance.
# It gives the directly loaded guidance a fixture containing both a competing
# owner in the affected responsibility and an unrelated duplicated helper, then
# verifies that the resulting review preserves the required scope boundary.
set -u

if [ "${FM_STRUCTURAL_REVIEW_GUIDANCE_EVAL:-0}" != 1 ]; then
  echo "skip: set FM_STRUCTURAL_REVIEW_GUIDANCE_EVAL=1 and FM_STRUCTURAL_REVIEW_LOCAL_MODEL=<model> to run the local instruction evaluation"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUIDANCE="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-structural-review-guidance)
PROMPT_FILE="$TMP_ROOT/prompt.txt"
RESPONSE_JSON="$TMP_ROOT/response.json"

command -v curl >/dev/null 2>&1 || fail "curl is required for the local instruction evaluation"
command -v jq >/dev/null 2>&1 || fail "jq is required for the local instruction evaluation"
curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags > "$TMP_ROOT/tags.json" \
  || fail "local Ollama is unavailable at 127.0.0.1:11434; no remote provider fallback is allowed"

MODEL=${FM_STRUCTURAL_REVIEW_LOCAL_MODEL:-}
[ -n "$MODEL" ] || fail "FM_STRUCTURAL_REVIEW_LOCAL_MODEL must name an explicit local evaluator"
jq -e --arg model "$MODEL" '.models | any(.name == $model)' "$TMP_ROOT/tags.json" >/dev/null \
  || fail "requested local Ollama model is unavailable: $MODEL"

{
  printf '%s\n' 'Act only as a reviewer applying the directly loaded coding guidance below.'
  printf '%s\n' 'The requested change adds token rotation to bin/token-refresh.sh.'
  printf '%s\n' 'That script and bin/session-auth.sh now each implement token rotation independently, so the affected token-rotation responsibility has two owners.'
  printf '%s\n' 'Elsewhere, two unrelated display scripts duplicate a small date-formatting helper.'
  printf '%s\n' 'Return only one JSON object with these exact keys and constrained values:'
  printf '%s\n' 'trigger_structural_review: boolean.'
  printf '%s\n' 'affected_responsibility: the string token rotation.'
  printf '%s\n' 'required_fix: the string consolidate the competing token-rotation owners.'
  printf '%s\n' 'unrelated_finding: the string duplicated date-formatting helper.'
  printf '%s\n' 'unrelated_disposition: either required or recommendation.'
  printf '%s\n' 'speculative_abstraction_required: boolean.'
  printf '%s\n' 'GUIDANCE START'
  cat "$GUIDANCE"
  printf '%s\n' 'GUIDANCE END'
} > "$PROMPT_FILE"

PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --rawfile prompt "$PROMPT_FILE" \
  '{model:$model,prompt:$prompt,stream:false,format:"json",options:{temperature:0,num_predict:1024}}')
curl -fsS --max-time "${FM_STRUCTURAL_REVIEW_EVAL_TIMEOUT_SECONDS:-120}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" http://127.0.0.1:11434/api/generate \
  | jq -er '.response | fromjson' > "$RESPONSE_JSON" \
  || fail "local model $MODEL did not return parseable Structural Review JSON"

jq -e '
  .trigger_structural_review == true and
  .affected_responsibility == "token rotation" and
  .required_fix == "consolidate the competing token-rotation owners" and
  .unrelated_finding == "duplicated date-formatting helper" and
  .unrelated_disposition == "recommendation" and
  .speculative_abstraction_required == false
' "$RESPONSE_JSON" >/dev/null \
  || fail "local model $MODEL did not require the affected owner correction while keeping unrelated duplication advisory"

pass "local model $MODEL scoped Structural Review to the competing owner and reported unrelated duplication separately"
