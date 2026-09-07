#!/usr/bin/env bash
# Regression coverage for the side-effect-free producer-neutral evidence import
# contract exposed by bin/fm-evidence-import-contract.py.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

SUBJECT="$ROOT/bin/fm-evidence-import-contract.py"
FIXTURES="$ROOT/tests/fixtures/evidence-import-contract"
TMP_ROOT=$(fm_test_tmproot evidence-import-contract)
BASE="$TMP_ROOT/base.json"
OUT="$TMP_ROOT/out.json"
ERR="$TMP_ROOT/err.json"
MAX_JSON_BYTES=1048576
MAX_ARTIFACTS=256

cp "$FIXTURES/producer-a.json" "$BASE"

test_python_syntax() {
  python3 -c \
    'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$SUBJECT" "$TMP_ROOT/fm-evidence-import-contract.pyc" \
    || fail "evidence import CLI failed Python syntax compilation"
  pass "evidence import CLI passes Python syntax compilation"
}

test_cli_contract() {
  local from_file from_stdin help_output optimized_help rc=0
  local missing="$TMP_ROOT/does-not-exist.json"
  local non_ascii_missing="$TMP_ROOT/révision.json"
  from_file=$("$SUBJECT" --file "$FIXTURES/producer-a.json") \
    || fail "file-input contract was refused"
  from_stdin=$("$SUBJECT" < "$FIXTURES/producer-a.json") \
    || fail "stdin-input contract was refused"
  [ "$from_file" = "$from_stdin" ] || fail "file and stdin inputs normalized differently"

  help_output=$("$SUBJECT" --help 2> "$ERR") || fail "--help did not exit 0"
  [ ! -s "$ERR" ] || fail "--help wrote stderr"
  case "$help_output" in
    *"Usage:"*"fm-evidence-import-contract.py"*) ;;
    *) fail "--help omitted the executable usage contract" ;;
  esac

  optimized_help=$(PYTHONOPTIMIZE=2 "$SUBJECT" --help 2> "$ERR") \
    || fail "optimized --help did not exit 0"
  [ ! -s "$ERR" ] || fail "optimized --help wrote stderr"
  [ "$optimized_help" = "$help_output" ] || fail "optimized --help changed help output"

  "$SUBJECT" unexpected > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid arguments must exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "invalid arguments wrote stdout"
  case "$(cat "$ERR")" in
    *"Usage:"*) ;;
    *) fail "invalid arguments omitted usage on stderr" ;;
  esac

  rc=0
  PYTHONOPTIMIZE=2 "$SUBJECT" unexpected > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "optimized invalid arguments must exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "optimized invalid arguments wrote stdout"
  case "$(cat "$ERR")" in
    *"Usage:"*) ;;
    *) fail "optimized invalid arguments omitted usage on stderr" ;;
  esac

  rc=0
  "$SUBJECT" --file "$missing" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 1 ] || fail "missing input file must exit 1, got $rc"
  [ ! -s "$OUT" ] || fail "missing input file wrote stdout"
  [ "$(cat "$ERR")" = "fm-evidence-import-contract: input is not a regular file: $missing" ] \
    || fail "missing input file emitted an unstable diagnostic: $(cat "$ERR")"

  rc=0
  PYTHONIOENCODING=ascii "$SUBJECT" --file "$non_ascii_missing" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 1 ] || fail "non-ASCII missing input file must exit 1, got $rc"
  [ ! -s "$OUT" ] || fail "non-ASCII missing input file wrote stdout"
  [ "$(cat "$ERR")" = "fm-evidence-import-contract: input is not a regular file: $non_ascii_missing" ] \
    || fail "non-ASCII missing input file emitted an unstable diagnostic: $(cat "$ERR")"
  pass "standalone CLI owns deterministic input, argument, help, and exit behavior"
}

expect_refusal() { # <code> <fixture> [description]
  local code=$1 fixture=$2 description=${3:-$1} rc=0
  "$SUBJECT" --file "$fixture" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "$description: expected exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$description: refusal wrote accepted output"
  jq -e --arg code "$code" '.code == $code and (.message | type == "string" and length > 0)' \
    "$ERR" >/dev/null || fail "$description: expected stable error code $code, got $(cat "$ERR")"
}

mutate() { # <jq-filter> <destination>
  jq "$1" "$BASE" > "$2" || fail "could not build fixture with: $1"
}

test_producer_neutral_equivalence() {
  local a="$TMP_ROOT/producer-a-normalized.json"
  local b="$TMP_ROOT/producer-b-normalized.json"
  local expected="$TMP_ROOT/expected-normalized.json"
  "$SUBJECT" --file "$FIXTURES/producer-a.json" > "$a" \
    || fail "producer A fixture was refused"
  "$SUBJECT" --file "$FIXTURES/producer-b.json" > "$b" \
    || fail "producer B fixture was refused"
  cmp -s "$a" "$b" || fail "producer identity or optional field order changed accepted semantics"
  printf '%s\n' '{"schema_version":"1.0","manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","report":{"path":"report/evidence.md","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","media_type":"text/markdown"},"artifacts":[{"path":"artifacts/baseline.png","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","media_type":"image/png"},{"path":"artifacts/candidate.webp","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","media_type":"image/webp"}],"approval_identity":"approval-9d0c4f","run_binding":"run-42","reviewed_head":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","destination":"github-pr:hcho22/example#17"}' > "$expected"
  cmp -s "$a" "$expected" || fail "normalized output bytes changed"
  jq -e '
    .schema_version == "1.0" and
    .manifest_sha256 == ("a" * 64) and
    .report == {
      path:"report/evidence.md",
      sha256:("b" * 64),
      media_type:"text/markdown"
    } and
    [.artifacts[].path] == ["artifacts/baseline.png", "artifacts/candidate.webp"] and
    .approval_identity == "approval-9d0c4f" and
    .run_binding == "run-42" and
    .reviewed_head == ("e" * 40) and
    .destination == "github-pr:hcho22/example#17" and
    (has("producer") | not)
  ' "$a" >/dev/null || fail "normalized result did not preserve every required identity"
  pass "producer-neutral output is exact, compact, sorted, and extension-free"
}

test_missing_required_fields() {
  local field fixture subfield
  for field in schema_version manifest_sha256 report artifacts approval_identity run_binding reviewed_head destination; do
    fixture="$TMP_ROOT/missing-$field.json"
    jq --arg field "$field" 'del(.[$field])' "$BASE" > "$fixture"
    expect_refusal missing-field "$fixture" "missing top-level $field"
  done
  for subfield in path sha256 media_type; do
    fixture="$TMP_ROOT/missing-report-$subfield.json"
    jq --arg field "$subfield" 'del(.report[$field])' "$BASE" > "$fixture"
    expect_refusal missing-field "$fixture" "missing report $subfield"
    fixture="$TMP_ROOT/missing-artifact-$subfield.json"
    jq --arg field "$subfield" 'del(.artifacts[0][$field])' "$BASE" > "$fixture"
    expect_refusal missing-field "$fixture" "missing artifact $subfield"
  done
  pass "every required contract, report, and artifact field is enforced"
}

test_schema_boundaries() {
  local fixture out large_integer
  fixture="$TMP_ROOT/schema-new-minor.json"
  mutate '.schema_version = "1.999" | .new_optional = {nested:[1,2,3]}' "$fixture"
  out=$("$SUBJECT" --file "$fixture") || fail "new schema 1 minor and optional field were refused"
  printf '%s\n' "$out" | jq -e '.schema_version == "1.999" and (has("new_optional") | not)' >/dev/null \
    || fail "supported newer minor was not normalized"

  fixture="$TMP_ROOT/large-optional-integer.json"
  large_integer=$(printf '1%04999d' 0)
  {
    printf '{"future_integer":%s,' "$large_integer"
    sed '1s/^[[:space:]]*{//' "$BASE"
  } > "$fixture"
  out=$(PYTHONINTMAXSTRDIGITS=640 "$SUBJECT" --file "$fixture") \
    || fail "large optional integer was refused"
  printf '%s\n' "$out" | jq -e 'has("future_integer") | not' >/dev/null \
    || fail "large optional integer was not omitted from normalized output"

  fixture="$TMP_ROOT/schema-zero-major.json"
  mutate '.schema_version = "0.9"' "$fixture"
  expect_refusal unsupported-schema-version "$fixture" "older unknown major"
  fixture="$TMP_ROOT/schema-two.json"
  mutate '.schema_version = "2.0"' "$fixture"
  expect_refusal unsupported-schema-version "$fixture" "newer unknown major"
  for version in '1' '1.0.0' '01.0' '1.-1'; do
    fixture="$TMP_ROOT/schema-malformed-${version//[^A-Za-z0-9]/_}.json"
    jq --arg version "$version" '.schema_version = $version' "$BASE" > "$fixture"
    expect_refusal invalid-schema-version "$fixture" "malformed schema $version"
  done
  fixture="$TMP_ROOT/schema-number.json"
  mutate '.schema_version = 1.0' "$fixture"
  expect_refusal invalid-schema-version "$fixture" "numeric schema"
  pass "schema major, minor, optional-field, and malformed-version boundaries are deterministic"
}

test_duplicate_object_keys() {
  local fixture
  fixture="$TMP_ROOT/duplicate-reviewed-head.json"
  {
    printf '{"reviewed_head":"%040d",' 0
    sed '1s/^[[:space:]]*{//' "$BASE"
  } > "$fixture"
  expect_refusal duplicate-key "$fixture" "duplicate required object key"

  fixture="$TMP_ROOT/duplicate-optional-key.json"
  jq '.optional = {future_binding:"one"}' "$BASE" |
    sed 's/"future_binding": "one"/"future_binding": "one", "future_binding": "two"/' > "$fixture"
  expect_refusal duplicate-key "$fixture" "duplicate optional object key"
  pass "duplicate required and optional object keys are refused before normalization"
}

test_path_refusals() {
  local fixture path target
  for target in report artifact; do
    for path in '/absolute/evidence.png' '../escape.png' 'safe/../../escape.png' './not-normal.png' 'double//segment.png' 'windows\\escape.png'; do
      fixture="$TMP_ROOT/path-$target-$(printf '%s' "$path" | tr -cs 'A-Za-z0-9' '_').json"
      if [ "$target" = report ]; then
        jq --arg path "$path" '.report.path = $path' "$BASE" > "$fixture"
      else
        jq --arg path "$path" '.artifacts[0].path = $path' "$BASE" > "$fixture"
      fi
      expect_refusal unsafe-path "$fixture" "$target unsafe path $path"
    done
  done

  fixture="$TMP_ROOT/duplicate-artifacts.json"
  mutate '.artifacts[1].path = .artifacts[0].path' "$fixture"
  expect_refusal duplicate-path "$fixture" "duplicate artifact path"
  fixture="$TMP_ROOT/report-artifact-collision.json"
  mutate '.artifacts[0].path = .report.path' "$fixture"
  expect_refusal duplicate-path "$fixture" "report/artifact path collision"
  fixture="$TMP_ROOT/report-path-ancestor.json"
  mutate '.report.path = "evidence" | .artifacts[0].path = "evidence/shot.png"' "$fixture"
  expect_refusal duplicate-path "$fixture" "report path ancestor collision"
  fixture="$TMP_ROOT/report-path-descendant.json"
  mutate '.report.path = "evidence/report.md" | .artifacts[0].path = "evidence"' "$fixture"
  expect_refusal duplicate-path "$fixture" "report path descendant collision"
  fixture="$TMP_ROOT/artifact-path-ancestor.json"
  mutate '.artifacts[0].path = "evidence" | .artifacts[1].path = "evidence/shot.png"' "$fixture"
  expect_refusal duplicate-path "$fixture" "artifact path ancestor collision"
  fixture="$TMP_ROOT/interleaved-path-ancestor.json"
  mutate '.report.path = "evidence" | .artifacts[0].path = "evidence-archive" | .artifacts[1].path = "evidence/shot.png"' "$fixture"
  expect_refusal duplicate-path "$fixture" "lexically interleaved path ancestor collision"
  pass "unsafe, duplicate, and segment-ancestor paths are refused"
}

test_media_boundaries() {
  local fixture media
  for media in image/png image/jpeg image/webp; do
    fixture="$TMP_ROOT/media-$(printf '%s' "$media" | tr / _).json"
    jq --arg media "$media" '.artifacts = [{path:"artifact.bin",sha256:("f" * 64),media_type:$media}]' \
      "$BASE" > "$fixture"
    "$SUBJECT" --file "$fixture" >/dev/null || fail "supported media type was refused: $media"
  done
  for media in image/gif image/svg+xml video/mp4 'image/png; charset=binary' IMAGE/PNG null; do
    fixture="$TMP_ROOT/unsupported-$(printf '%s' "$media" | tr -cs 'A-Za-z0-9' '_').json"
    if [ "$media" = null ]; then
      mutate '.artifacts[0].media_type = null' "$fixture"
    else
      jq --arg media "$media" '.artifacts[0].media_type = $media' "$BASE" > "$fixture"
    fi
    expect_refusal unsupported-media-type "$fixture" "unsupported artifact media $media"
  done
  fixture="$TMP_ROOT/report-media.json"
  mutate '.report.media_type = "text/plain"' "$fixture"
  expect_refusal unsupported-media-type "$fixture" "unsupported report media"
  fixture="$TMP_ROOT/numeric-artifact-media.json"
  mutate '.artifacts[0].media_type = 7' "$fixture"
  expect_refusal unsupported-media-type "$fixture" "numeric artifact media"
  pass "the exact report and screenshot media allowlists are enforced"
}

test_malformed_shapes_and_values() {
  local fixture field
  fixture="$TMP_ROOT/not-json.json"
  printf '{broken\n' > "$fixture"
  expect_refusal invalid-json "$fixture" "invalid JSON"
  fixture="$TMP_ROOT/multiple.json"
  printf '{}\n{}\n' > "$fixture"
  expect_refusal invalid-json-count "$fixture" "multiple JSON values"
  fixture="$TMP_ROOT/root-array.json"
  printf '[]\n' > "$fixture"
  expect_refusal invalid-shape "$fixture" "array root"

  fixture="$TMP_ROOT/report-array.json"
  mutate '.report = []' "$fixture"
  expect_refusal invalid-shape "$fixture" "array report"
  fixture="$TMP_ROOT/artifacts-object.json"
  mutate '.artifacts = {}' "$fixture"
  expect_refusal invalid-shape "$fixture" "object artifacts"
  fixture="$TMP_ROOT/artifact-string.json"
  mutate '.artifacts = ["artifact"]' "$fixture"
  expect_refusal invalid-shape "$fixture" "string artifact"

  for field in manifest_sha256 approval_identity run_binding reviewed_head destination; do
    fixture="$TMP_ROOT/wrong-type-$field.json"
    jq --arg field "$field" '.[$field] = 7' "$BASE" > "$fixture"
    case "$field" in
      manifest_sha256) expect_refusal invalid-hash "$fixture" "$field wrong type" ;;
      reviewed_head) expect_refusal invalid-reviewed-head "$fixture" "$field wrong type" ;;
      *) expect_refusal invalid-value "$fixture" "$field wrong type" ;;
    esac
  done
  fixture="$TMP_ROOT/hash-uppercase.json"
  mutate '.manifest_sha256 = ("A" * 64)' "$fixture"
  expect_refusal invalid-hash "$fixture" "uppercase SHA-256"
  fixture="$TMP_ROOT/hash-short.json"
  mutate '.report.sha256 = ("a" * 63)' "$fixture"
  expect_refusal invalid-hash "$fixture" "short report SHA-256"
  fixture="$TMP_ROOT/head-short.json"
  mutate '.reviewed_head = ("a" * 39)' "$fixture"
  expect_refusal invalid-reviewed-head "$fixture" "short reviewed head"
  fixture="$TMP_ROOT/head-64.json"
  mutate '.reviewed_head = ("f" * 64)' "$fixture"
  "$SUBJECT" --file "$fixture" >/dev/null || fail "64-character reviewed head was refused"
  fixture="$TMP_ROOT/empty-binding.json"
  mutate '.approval_identity = ""' "$fixture"
  expect_refusal invalid-value "$fixture" "empty approval identity"
  fixture="$TMP_ROOT/control-binding.json"
  mutate '.destination = "destination\nother"' "$fixture"
  expect_refusal invalid-value "$fixture" "control character in destination"
  fixture="$TMP_ROOT/c1-binding.json"
  mutate '.approval_identity = "reviewer\u0085admin"' "$fixture"
  expect_refusal invalid-value "$fixture" "C1 control in approval identity"
  fixture="$TMP_ROOT/line-separator-binding.json"
  mutate '.approval_identity = "reviewer\u2028admin"' "$fixture"
  expect_refusal invalid-value "$fixture" "Unicode line separator in approval identity"
  fixture="$TMP_ROOT/paragraph-separator-binding.json"
  mutate '.approval_identity = "reviewer\u2029admin"' "$fixture"
  expect_refusal invalid-value "$fixture" "Unicode paragraph separator in approval identity"

  fixture="$TMP_ROOT/c1-path.json"
  mutate '.report.path = "report/\u009bevidence.md"' "$fixture"
  expect_refusal unsafe-path "$fixture" "C1 control in report path"
  fixture="$TMP_ROOT/line-separator-path.json"
  mutate '.report.path = "report/line\u2028break.md"' "$fixture"
  expect_refusal unsafe-path "$fixture" "Unicode line separator in report path"
  fixture="$TMP_ROOT/paragraph-separator-path.json"
  mutate '.report.path = "report/paragraph\u2029break.md"' "$fixture"
  expect_refusal unsafe-path "$fixture" "Unicode paragraph separator in report path"

  fixture="$TMP_ROOT/non-ascii-binding.json"
  jq --arg identity 'réviseur' '.approval_identity = $identity' "$BASE" > "$fixture"
  PYTHONIOENCODING=ascii "$SUBJECT" --file "$fixture" > "$OUT" 2> "$ERR" \
    || fail "non-ASCII contract was refused under an ASCII output encoding"
  [ ! -s "$ERR" ] || fail "non-ASCII acceptance wrote stderr: $(cat "$ERR")"
  jq -e '.approval_identity == "réviseur"' "$OUT" >/dev/null \
    || fail "non-ASCII approval identity was not preserved"

  fixture="$TMP_ROOT/non-ascii-media-refusal.json"
  jq --arg media 'image/révision' '.artifacts[0].media_type = $media' "$BASE" > "$fixture"
  PYTHONIOENCODING=ascii expect_refusal unsupported-media-type "$fixture" \
    "non-ASCII unsupported media type"

  fixture="$TMP_ROOT/lone-surrogate.json"
  sed 's/"approval_identity": "approval-9d0c4f"/"approval_identity": "\\ud800"/' \
    "$BASE" > "$fixture"
  expect_refusal invalid-json "$fixture" "lone Unicode surrogate"
  pass "malformed shapes, values, Unicode controls, and surrogates are handled deterministically"
}

test_resource_boundaries() {
  local exact_artifacts exact_envelope home over_artifacts over_envelope deep before after
  exact_artifacts="$TMP_ROOT/exact-artifact-limit.json"
  jq --argjson limit "$MAX_ARTIFACTS" '
    .artifacts = [range(0; $limit) | {
      path:("artifacts/shot-" + tostring + ".png"),
      sha256:("f" * 64),
      media_type:"image/png"
    }]
  ' "$BASE" > "$exact_artifacts"
  "$SUBJECT" --file "$exact_artifacts" >/dev/null || fail "exact artifact limit was refused"

  over_artifacts="$TMP_ROOT/over-artifact-limit.json"
  jq '.artifacts += [{path:"artifacts/over.png",sha256:("f" * 64),media_type:"image/png"}]' \
    "$exact_artifacts" > "$over_artifacts"

  exact_envelope="$TMP_ROOT/exact-envelope-limit.json"
  over_envelope="$TMP_ROOT/over-envelope-limit.json"
  deep="$TMP_ROOT/deeply-nested.json"
  python3 - "$BASE" "$exact_envelope" "$over_envelope" "$deep" "$MAX_JSON_BYTES" <<'PY'
import json
from pathlib import Path
import sys

base_path, exact_path, over_path, deep_path, limit_raw = sys.argv[1:]
limit = int(limit_raw)
base = json.loads(Path(base_path).read_text())
base["future_padding"] = ""
empty = json.dumps(base, separators=(",", ":")).encode()
base["future_padding"] = "x" * (limit - len(empty))
exact = json.dumps(base, separators=(",", ":")).encode()
if len(exact) != limit:
    raise SystemExit("could not construct exact envelope boundary")
Path(exact_path).write_bytes(exact)
Path(over_path).write_bytes(exact + b" ")

raw = Path(base_path).read_bytes().lstrip()
deep_depth = sys.getrecursionlimit() * 10
deep = b'{"future_depth":' + (b"[" * deep_depth) + b"0" + (b"]" * deep_depth) + b"," + raw[1:]
Path(deep_path).write_bytes(deep)
PY
  "$SUBJECT" --file "$exact_envelope" >/dev/null || fail "exact JSON envelope limit was refused"
  expect_refusal invalid-json "$deep" "parser depth exhaustion"

  home="$TMP_ROOT/resource-bound-home"
  mkdir -p "$home/imports" "$home/publications"
  printf 'keep\n' > "$home/imports/existing"
  printf 'keep\n' > "$home/publications/existing"
  before=$({ find "$home" -print; find "$home" -type f -exec cksum {} \;; } | LC_ALL=C sort)
  NM_HOME="$home" NO_MISTAKES_HOME="$home" expect_refusal too-many-artifacts "$over_artifacts" \
    "artifact count over limit"
  NM_HOME="$home" NO_MISTAKES_HOME="$home" expect_refusal input-too-large "$over_envelope" \
    "JSON envelope over limit"
  after=$({ find "$home" -print; find "$home" -type f -exec cksum {} \;; } | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "resource-bound refusal changed import or publication state"
  pass "depth and exact resource boundaries refuse safely without state mutation"
}

test_refusal_is_side_effect_free() {
  local home fixture before after
  home="$TMP_ROOT/no-mistakes-home"
  mkdir -p "$home/imports" "$home/publications"
  printf 'keep\n' > "$home/imports/existing"
  printf 'keep\n' > "$home/publications/existing"
  before=$({ find "$home" -print; find "$home" -type f -exec cksum {} \;; } | LC_ALL=C sort)
  fixture="$TMP_ROOT/no-state-on-refusal.json"
  mutate 'del(.manifest_sha256)' "$fixture"
  NM_HOME="$home" NO_MISTAKES_HOME="$home" expect_refusal missing-field "$fixture" \
    "refusal under configured no-mistakes home"
  after=$({ find "$home" -print; find "$home" -type f -exec cksum {} \;; } | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "refusal changed import or publication state"
  pass "refusal creates no import or publication state"
}

test_python_syntax
test_cli_contract
test_producer_neutral_equivalence
test_missing_required_fields
test_schema_boundaries
test_duplicate_object_keys
test_path_refusals
test_media_boundaries
test_malformed_shapes_and_values
test_resource_boundaries
test_refusal_is_side_effect_free
