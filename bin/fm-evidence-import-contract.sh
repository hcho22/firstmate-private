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
# absolute root, backslash, empty segment, `.` segment, `..` segment, C0 or C1
# control, or Unicode line or paragraph separator.
# Paths must be unique across the report and all artifacts, and no path may be
# an ancestor of another path.
# The JSON envelope may contain at most 1048576 bytes and 256 artifacts.
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
  printf '{"code":"%s","message":"%s"}\n' "$1" "$2" >&2
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

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
if [ -z "$SOURCE" ] && [ -t 0 ]; then
  refuse input-required "one JSON contract is required on stdin or with --file"
fi

MAX_JSON_BYTES=1048576
MAX_ARTIFACTS=256

PYTHON_PROGRAM=$(cat <<'PY'
import json
import re
import sys


class DuplicateKeyError(ValueError):
    pass


class Refusal(ValueError):
    def __init__(self, code, message):
        self.code = code
        self.message = message


def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(value)


def refuse(code, message):
    raise Refusal(code, message)


def missing(value, field, label):
    if field not in value:
        refuse("missing-field", f"missing required field: {label}.{field}")
    return value[field]


def has_forbidden_control(value):
    return any(
        ord(character) <= 31
        or 127 <= ord(character) <= 159
        or ord(character) in (8232, 8233)
        for character in value
    )


def opaque(value, label):
    if not isinstance(value, str):
        refuse("invalid-value", f"{label} must be a string")
    if not 1 <= len(value) <= 512:
        refuse("invalid-value", f"{label} must contain 1 to 512 characters")
    if has_forbidden_control(value):
        refuse("invalid-value", f"{label} must not contain control characters")
    if value[0].isspace() or value[-1].isspace():
        refuse("invalid-value", f"{label} must not start or end with whitespace")
    return value


def sha256(value, label):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        refuse("invalid-hash", f"{label} must be a lowercase SHA-256 digest")
    return value


def relative_path(value, label):
    if not isinstance(value, str):
        refuse("invalid-path", f"{label} must be a string")
    if not 1 <= len(value) <= 512:
        refuse("invalid-path", f"{label} must contain 1 to 512 characters")
    if value.startswith("/") or "\\" in value:
        refuse("unsafe-path", f"{label} must be a relative POSIX path")
    if has_forbidden_control(value):
        refuse("unsafe-path", f"{label} must not contain control characters")
    if any(segment in ("", ".", "..") for segment in value.split("/")):
        refuse("unsafe-path", f"{label} must be normalized and must not traverse")
    return value


def json_value(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def report_media(value):
    if value != "text/markdown":
        refuse(
            "unsupported-media-type",
            f"report.media_type is not supported: {json_value(value)}",
        )
    return value


def artifact_media(value, label):
    if value not in ("image/png", "image/jpeg", "image/webp"):
        refuse(
            "unsupported-media-type",
            f"{label} is not supported: {json_value(value)}",
        )
    return value


def validate_report(value):
    if not isinstance(value, dict):
        refuse("invalid-shape", "report must be an object")
    return {
        "path": relative_path(missing(value, "path", "report"), "report.path"),
        "sha256": sha256(missing(value, "sha256", "report"), "report.sha256"),
        "media_type": report_media(missing(value, "media_type", "report")),
    }


def validate_artifact(value, index):
    label = f"artifacts[{index}]"
    if not isinstance(value, dict):
        refuse("invalid-shape", f"{label} must be an object")
    return {
        "path": relative_path(missing(value, "path", label), f"{label}.path"),
        "sha256": sha256(missing(value, "sha256", label), f"{label}.sha256"),
        "media_type": artifact_media(
            missing(value, "media_type", label), f"{label}.media_type"
        ),
    }


def validate_version(value):
    if not isinstance(value, str) or re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value
    ) is None:
        refuse("invalid-schema-version", "schema_version must be <major>.<minor>")
    major = value.split(".", 1)[0]
    if major != "1":
        refuse(
            "unsupported-schema-version",
            f"unsupported evidence import schema major: {major}",
        )
    return value


def paths_overlap(paths):
    ordered = sorted(paths, key=lambda path: path.split("/"))
    return any(
        current == previous or current.startswith(previous + "/")
        for previous, current in zip(ordered, ordered[1:])
    )


def validate_contract(value, max_artifacts):
    if not isinstance(value, dict):
        refuse("invalid-shape", "contract must be a JSON object")

    schema_version = validate_version(missing(value, "schema_version", "contract"))
    manifest_sha256 = sha256(
        missing(value, "manifest_sha256", "contract"), "manifest_sha256"
    )
    report = validate_report(missing(value, "report", "contract"))
    artifact_input = missing(value, "artifacts", "contract")
    if not isinstance(artifact_input, list):
        refuse("invalid-shape", "artifacts must be an array")
    if len(artifact_input) > max_artifacts:
        refuse(
            "too-many-artifacts",
            f"artifacts must contain at most {max_artifacts} entries",
        )
    artifacts = [
        validate_artifact(artifact, index)
        for index, artifact in enumerate(artifact_input)
    ]
    paths = [report["path"], *(artifact["path"] for artifact in artifacts)]
    if paths_overlap(paths):
        refuse(
            "duplicate-path",
            "report and artifact paths must be distinct non-ancestor paths",
        )

    reviewed_head = missing(value, "reviewed_head", "contract")
    if not isinstance(reviewed_head, str) or re.fullmatch(
        r"(?:[0-9a-f]{40}|[0-9a-f]{64})", reviewed_head
    ) is None:
        refuse(
            "invalid-reviewed-head",
            "reviewed_head must be a lowercase 40- or 64-character Git object identity",
        )

    return {
        "schema_version": schema_version,
        "manifest_sha256": manifest_sha256,
        "report": report,
        "artifacts": sorted(artifacts, key=lambda artifact: artifact["path"]),
        "approval_identity": opaque(
            missing(value, "approval_identity", "contract"), "approval_identity"
        ),
        "run_binding": opaque(
            missing(value, "run_binding", "contract"), "run_binding"
        ),
        "reviewed_head": reviewed_head,
        "destination": opaque(
            missing(value, "destination", "contract"), "destination"
        ),
    }


def emit_refusal(code, message):
    print(json_value({"code": code, "message": message}), file=sys.stderr)


try:
    byte_limit = int(sys.argv[1])
    artifact_limit = int(sys.argv[2])
    if len(sys.argv) == 4:
        with open(sys.argv[3], "rb") as source:
            raw = source.read(byte_limit + 1)
    else:
        raw = sys.stdin.buffer.read(byte_limit + 1)
except OSError:
    sys.exit(1)
except (MemoryError, OverflowError):
    emit_refusal("invalid-json", "input is not valid JSON")
    sys.exit(2)

if len(raw) > byte_limit:
    emit_refusal("input-too-large", "input exceeds the 1048576-byte JSON envelope")
    sys.exit(2)

try:
    text = raw.decode("utf-8")
    decoder = json.JSONDecoder(
        object_pairs_hook=object_without_duplicates,
        parse_constant=reject_constant,
    )
    whitespace = re.compile(r"[ \t\r\n]*")
    start = whitespace.match(text, 0).end()
    value, end = decoder.raw_decode(text, start)
    end = whitespace.match(text, end).end()
    if end != len(text):
        decoder.raw_decode(text, end)
        refuse("invalid-json-count", "input must contain exactly one JSON value")
    normalized = validate_contract(value, artifact_limit)
except DuplicateKeyError:
    emit_refusal("duplicate-key", "input contains a duplicate object key")
    sys.exit(2)
except Refusal as error:
    emit_refusal(error.code, error.message)
    sys.exit(2)
except (UnicodeDecodeError, ValueError, RecursionError, MemoryError, OverflowError):
    emit_refusal("invalid-json", "input is not valid JSON")
    sys.exit(2)

print(json_value(normalized))
PY
)

if [ -n "$SOURCE" ]; then
  python3 -c "$PYTHON_PROGRAM" "$MAX_JSON_BYTES" "$MAX_ARTIFACTS" "$SOURCE"
else
  python3 -c "$PYTHON_PROGRAM" "$MAX_JSON_BYTES" "$MAX_ARTIFACTS"
fi
case $? in
  0) exit 0 ;;
  1) fail "could not read input" ;;
  2) exit 2 ;;
  *) fail "validator failed unexpectedly" ;;
esac
