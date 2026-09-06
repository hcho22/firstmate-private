#!/usr/bin/env bash
# fm-evidence-import-contract.sh - parse and validate one producer-neutral
# evidence import offer without creating import, approval, or publication state.
#
# Usage:
#   fm-evidence-import-contract.sh [--file <offer.json>]
#   fm-evidence-import-contract.sh < offer.json
#
# Contract schema `1.x` is one JSON object with these required fields:
#   schema_version      "1.<minor>", where minor is a non-negative integer.
#   manifest_sha256     Lowercase 64-character SHA-256 digest.
#   report              Object with path, sha256, and media_type.
#   artifacts           Array of objects with path, sha256, and media_type.
#   approval_identity   Non-empty opaque single-line identity.
#   run_binding         Non-empty opaque single-line no-mistakes run binding.
#   reviewed_head       Lowercase 40- or 64-character Git object identity.
#   destination         Non-empty opaque single-line named destination.
#
# The report media type is `text/markdown`.
# Supported artifact media types are `image/png`, `image/jpeg`, and
# `image/webp`.
# Every report and artifact path is a normalized relative POSIX path: it has no
# absolute root, backslash, empty segment, `.` segment, `..` segment, or control
# character.
# Paths must be unique across the report and all artifacts, and no path may be
# an ancestor of another path.
#
# Unknown fields at any object level are optional extension data within schema
# major 1 and are accepted but omitted from normalized output.
# Producer identity is therefore opaque optional extension data and cannot
# affect parsing, validation, or normalized semantics.
#
# On acceptance, stdout is the compact normalized contract object with artifacts
# sorted bytewise by path, and the command exits 0.
# On refusal, stderr is a compact object with stable `code` and `message` fields,
# stdout is empty, and the command exits 2.
# Dependency or I/O failures exit 1.
# The command reads input only and performs no staging, consent admission,
# preview, approval, drift or replay enforcement, or publication.
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

refuse() {
  jq -cn --arg code "$1" --arg message "$2" \
    '{code:$code,message:$message}' >&2
  exit 2
}

fail() {
  printf 'fm-evidence-import-contract: %s\n' "$1" >&2
  exit 1
}

SOURCE=
case "${1:-}" in
  '') ;;
  --file)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    SOURCE=$2
    [ -f "$SOURCE" ] || fail "input is not a regular file: $SOURCE"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
if [ -z "$SOURCE" ] && [ -t 0 ]; then
  refuse input-required "one JSON contract is required on stdin or with --file"
fi

PYTHON_PROGRAM=$(cat <<'PY'
import json
import re
import sys

class DuplicateKeyError(ValueError):
    pass

def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(key)
        result[key] = value
    return result

def reject_constant(value):
    raise ValueError(value)

try:
    if len(sys.argv) == 2:
        with open(sys.argv[1], "rb") as source:
            raw = source.read()
    else:
        raw = sys.stdin.buffer.read()
except OSError:
    sys.exit(1)

try:
    text = raw.decode("utf-8")
    decoder = json.JSONDecoder(
        object_pairs_hook=object_without_duplicates,
        parse_constant=reject_constant,
    )
    whitespace = re.compile(r"[ \t\r\n]*")
    start = whitespace.match(text, 0).end()
    _, end = decoder.raw_decode(text, start)
    end = whitespace.match(text, end).end()
    if end != len(text):
        decoder.raw_decode(text, end)
        sys.exit(4)
except DuplicateKeyError:
    sys.exit(3)
except (UnicodeDecodeError, ValueError):
    sys.exit(2)

sys.stdout.buffer.write(raw)
PY
)

STRICT_JSON=
if [ -n "$SOURCE" ]; then
  STRICT_JSON=$(python3 -c "$PYTHON_PROGRAM" "$SOURCE")
else
  STRICT_JSON=$(python3 -c "$PYTHON_PROGRAM")
fi
case $? in
  0) ;;
  1) fail "could not read input" ;;
  3) refuse duplicate-key "input contains a duplicate object key" ;;
  4) refuse invalid-json-count "input must contain exactly one JSON value" ;;
  *) refuse invalid-json "input is not valid JSON" ;;
esac

JQ_PROGRAM=$(cat <<'JQ'
def refuse($code; $message): error({code: $code, message: $message});
def missing($object; $field; $label):
  if $object | has($field) then $object[$field]
  else refuse("missing-field"; "missing required field: \($label).\($field)")
  end;
def opaque($value; $label):
  if ($value | type) != "string" then
    refuse("invalid-value"; "\($label) must be a string")
  elif ($value | length) == 0 or ($value | length) > 512 then
    refuse("invalid-value"; "\($label) must contain 1 to 512 characters")
  elif $value | test("[\\x00-\\x1f\\x7f]") then
    refuse("invalid-value"; "\($label) must not contain control characters")
  elif ($value | test("^\\s|\\s$")) then
    refuse("invalid-value"; "\($label) must not start or end with whitespace")
  else $value
  end;
def sha256($value; $label):
  if ($value | type) == "string" and ($value | test("^[0-9a-f]{64}$")) then $value
  else refuse("invalid-hash"; "\($label) must be a lowercase SHA-256 digest")
  end;
def relative_path($value; $label):
  if ($value | type) != "string" then
    refuse("invalid-path"; "\($label) must be a string")
  elif ($value | length) == 0 or ($value | length) > 512 then
    refuse("invalid-path"; "\($label) must contain 1 to 512 characters")
  elif ($value | startswith("/")) or ($value | contains("\\")) then
    refuse("unsafe-path"; "\($label) must be a relative POSIX path")
  elif $value | test("[\\x00-\\x1f\\x7f]") then
    refuse("unsafe-path"; "\($label) must not contain control characters")
  elif any($value | split("/")[]; . == "" or . == "." or . == "..") then
    refuse("unsafe-path"; "\($label) must be normalized and must not traverse")
  else $value
  end;
def report_media($value):
  if $value == "text/markdown" then $value
  else refuse("unsupported-media-type"; "report.media_type is not supported: \($value | tojson)")
  end;
def artifact_media($value; $label):
  if $value == "image/png" or $value == "image/jpeg" or $value == "image/webp" then $value
  else refuse("unsupported-media-type"; "\($label) is not supported: \($value | tojson)")
  end;
def validate_report($value):
  if ($value | type) != "object" then
    refuse("invalid-shape"; "report must be an object")
  else {
    path: relative_path(missing($value; "path"; "report"); "report.path"),
    sha256: sha256(missing($value; "sha256"; "report"); "report.sha256"),
    media_type: report_media(missing($value; "media_type"; "report"))
  } end;
def validate_artifact($entry; $index):
  if ($entry | type) != "object" then
    refuse("invalid-shape"; "artifacts[\($index)] must be an object")
  else {
    path: relative_path(missing($entry; "path"; "artifacts[\($index)]"); "artifacts[\($index)].path"),
    sha256: sha256(missing($entry; "sha256"; "artifacts[\($index)]"); "artifacts[\($index)].sha256"),
    media_type: artifact_media(missing($entry; "media_type"; "artifacts[\($index)]"); "artifacts[\($index)].media_type")
  } end;
def validate_version($value):
  if ($value | type) != "string" or (($value | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) | not) then
    refuse("invalid-schema-version"; "schema_version must be <major>.<minor>")
  elif ($value | split(".")[0]) != "1" then
    refuse("unsupported-schema-version"; "unsupported evidence import schema major: \($value | split(".")[0])")
  else $value
  end;
def paths_overlap($paths):
  any(range(0; ($paths | length));
    . as $left |
    any(range($left + 1; ($paths | length));
      . as $right |
      ($paths[$left] == $paths[$right]) or
      ($paths[$left] | startswith($paths[$right] + "/")) or
      ($paths[$right] | startswith($paths[$left] + "/"))));
def validate_contract($value):
  if ($value | type) != "object" then
    refuse("invalid-shape"; "contract must be a JSON object")
  else
    (validate_version(missing($value; "schema_version"; "contract"))) as $schema_version |
    (sha256(missing($value; "manifest_sha256"; "contract"); "manifest_sha256")) as $manifest_sha256 |
    (validate_report(missing($value; "report"; "contract"))) as $report |
    (missing($value; "artifacts"; "contract")) as $artifact_input |
    if ($artifact_input | type) != "array" then
      refuse("invalid-shape"; "artifacts must be an array")
    else
      ($artifact_input | to_entries | map(validate_artifact(.value; .key))) as $artifacts |
      ([$report.path] + ($artifacts | map(.path))) as $paths |
      if paths_overlap($paths) then
        refuse("duplicate-path"; "report and artifact paths must be distinct non-ancestor paths")
      else {
        schema_version: $schema_version,
        manifest_sha256: $manifest_sha256,
        report: $report,
        artifacts: ($artifacts | sort_by(.path)),
        approval_identity: opaque(missing($value; "approval_identity"; "contract"); "approval_identity"),
        run_binding: opaque(missing($value; "run_binding"; "contract"); "run_binding"),
        reviewed_head:
          (missing($value; "reviewed_head"; "contract") as $head |
           if ($head | type) == "string" and ($head | test("^([0-9a-f]{40}|[0-9a-f]{64})$")) then $head
           else refuse("invalid-reviewed-head"; "reviewed_head must be a lowercase 40- or 64-character Git object identity")
           end),
        destination: opaque(missing($value; "destination"; "contract"); "destination")
      } end
    end
  end;
try (
  if length != 1 then
    refuse("invalid-json-count"; "input must contain exactly one JSON value")
  else validate_contract(.[0])
  end |
  {accepted: true, contract: .}
) catch {accepted: false, error: .}
JQ
)

RESULT=$(printf '%s\n' "$STRICT_JSON" | jq -cs "$JQ_PROGRAM" 2>/dev/null) \
  || refuse invalid-json "input is not valid JSON"

if [ "$(printf '%s\n' "$RESULT" | jq -r '.accepted')" = true ]; then
  printf '%s\n' "$RESULT" | jq -c '.contract'
  exit 0
fi
printf '%s\n' "$RESULT" | jq -c '.error' >&2
exit 2
