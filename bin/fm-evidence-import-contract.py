#!/usr/bin/env python3
"""Parse and validate one producer-neutral evidence import contract.

Usage:
  fm-evidence-import-contract.py [--file <offer.json>]
  fm-evidence-import-contract.py < offer.json

Contract schema ``1.x`` is one JSON object with these required fields:

``schema_version``
    ``1.<minor>``, where minor is zero or a positive decimal without a leading
    zero.
``manifest_sha256``
    Lowercase 64-character SHA-256 digest.
``report``
    Object with ``path``, ``sha256``, and ``media_type``.
``artifacts``
    Array of objects with ``path``, ``sha256``, and ``media_type``.
``approval_identity``
    Opaque single-line identity of 1 to 512 characters.
``run_binding``
    Opaque single-line no-mistakes run binding of 1 to 512 characters.
``reviewed_head``
    Lowercase 40- or 64-character Git object identity.
``destination``
    Opaque single-line named destination of 1 to 512 characters.

Opaque binding values have no leading or trailing whitespace, C0 or C1
control, or Unicode line or paragraph separator.

The report media type is ``text/markdown``.
Supported artifact media types are ``image/png``, ``image/jpeg``, and
``image/webp``.
Every report and artifact path is a normalized relative POSIX path of 1 to 512
characters: it has no absolute root, backslash, empty segment, ``.`` segment,
``..`` segment, C0 or C1 control, or Unicode line or paragraph separator.
Paths must be unique across the report and all artifacts, and no path may be
an ancestor of another path.
The UTF-8 JSON envelope must contain exactly one value, must not contain
duplicate object keys, and may contain at most 1048576 bytes and 256 artifacts.

Unknown fields at any object level are optional extension data within schema
major 1 and are accepted but omitted from normalized output.
Producer identity is therefore opaque optional extension data and cannot
affect parsing, validation, or normalized semantics.

On acceptance, stdout is the compact normalized contract object with artifacts
sorted bytewise by path, and the command exits 0.
On refusal, stderr is a compact object with stable ``code`` and ``message``
fields, stdout is empty, and the command exits 2.
Dependency or I/O failures exit 1.
The command reads input only and performs no staging, consent admission,
preview, approval, drift or replay enforcement, or publication.
"""

import json
import os
import re
import sys


MAX_JSON_BYTES = 1048576
MAX_ARTIFACTS = 256


class DuplicateKeyError(ValueError):
    """Signal a duplicate key while decoding any JSON object."""


class Refusal(ValueError):
    """Carry the stable public refusal code and message."""

    def __init__(self, code, message):
        super().__init__(message)
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
        refuse("missing-field", "missing required field: {}.{}".format(label, field))
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
        refuse("invalid-value", "{} must be a string".format(label))
    if not 1 <= len(value) <= 512:
        refuse("invalid-value", "{} must contain 1 to 512 characters".format(label))
    if has_forbidden_control(value):
        refuse("invalid-value", "{} must not contain control characters".format(label))
    if value[0].isspace() or value[-1].isspace():
        refuse("invalid-value", "{} must not start or end with whitespace".format(label))
    return value


def sha256(value, label):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        refuse("invalid-hash", "{} must be a lowercase SHA-256 digest".format(label))
    return value


def relative_path(value, label):
    if not isinstance(value, str):
        refuse("invalid-path", "{} must be a string".format(label))
    if not 1 <= len(value) <= 512:
        refuse("invalid-path", "{} must contain 1 to 512 characters".format(label))
    if value.startswith("/") or "\\" in value:
        refuse("unsafe-path", "{} must be a relative POSIX path".format(label))
    if has_forbidden_control(value):
        refuse("unsafe-path", "{} must not contain control characters".format(label))
    if any(segment in ("", ".", "..") for segment in value.split("/")):
        refuse("unsafe-path", "{} must be normalized and must not traverse".format(label))
    return value


def json_value(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def reject_lone_surrogates(value):
    pending = [value]
    while pending:
        current = pending.pop()
        if isinstance(current, str):
            if any(0xD800 <= ord(character) <= 0xDFFF for character in current):
                refuse("invalid-json", "input contains a lone Unicode surrogate")
        elif isinstance(current, dict):
            pending.extend(current.keys())
            pending.extend(current.values())
        elif isinstance(current, list):
            pending.extend(current)


def report_media(value):
    if value != "text/markdown":
        refuse(
            "unsupported-media-type",
            "report.media_type is not supported: {}".format(json_value(value)),
        )
    return value


def artifact_media(value, label):
    if value not in ("image/png", "image/jpeg", "image/webp"):
        refuse(
            "unsupported-media-type",
            "{} is not supported: {}".format(label, json_value(value)),
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
    label = "artifacts[{}]".format(index)
    if not isinstance(value, dict):
        refuse("invalid-shape", "{} must be an object".format(label))
    return {
        "path": relative_path(missing(value, "path", label), "{}.path".format(label)),
        "sha256": sha256(missing(value, "sha256", label), "{}.sha256".format(label)),
        "media_type": artifact_media(
            missing(value, "media_type", label), "{}.media_type".format(label)
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
            "unsupported evidence import schema major: {}".format(major),
        )
    return value


def paths_overlap(paths):
    ordered = sorted(paths, key=lambda path: path.split("/"))
    return any(
        current == previous or current.startswith(previous + "/")
        for previous, current in zip(ordered, ordered[1:])
    )


def validate_contract(value):
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
    if len(artifact_input) > MAX_ARTIFACTS:
        refuse(
            "too-many-artifacts",
            "artifacts must contain at most {} entries".format(MAX_ARTIFACTS),
        )
    artifacts = [
        validate_artifact(artifact, index)
        for index, artifact in enumerate(artifact_input)
    ]
    paths = [report["path"]] + [artifact["path"] for artifact in artifacts]
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


def emit_failure(message):
    output = "fm-evidence-import-contract: {}\n".format(message)
    sys.stderr.buffer.write(output.encode("utf-8", errors="backslashreplace"))


def usage(stream):
    print(__doc__.strip(), file=stream)


def input_path(arguments):
    if not arguments:
        return None
    if arguments in (["-h"], ["--help"], ["help"]):
        usage(sys.stdout)
        raise SystemExit(0)
    if len(arguments) == 2 and arguments[0] == "--file":
        path = arguments[1]
        if not os.path.isfile(path):
            emit_failure("input is not a regular file: {}".format(path))
            raise SystemExit(1)
        return path
    usage(sys.stderr)
    raise SystemExit(2)


def read_input(path):
    try:
        if path is None:
            if sys.stdin.isatty():
                refuse(
                    "input-required",
                    "one JSON contract is required on stdin or with --file",
                )
            return sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
        with open(path, "rb") as source:
            return source.read(MAX_JSON_BYTES + 1)
    except OSError:
        emit_failure("could not read input")
        raise SystemExit(1)
    except (MemoryError, OverflowError):
        refuse("invalid-json", "input is not valid JSON")


def decode_contract(raw):
    if len(raw) > MAX_JSON_BYTES:
        refuse(
            "input-too-large",
            "input exceeds the 1048576-byte JSON envelope",
        )

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
    reject_lone_surrogates(value)
    return validate_contract(value)


def main(arguments):
    try:
        path = input_path(arguments)
        raw = read_input(path)
        normalized = decode_contract(raw)
    except DuplicateKeyError:
        emit_refusal("duplicate-key", "input contains a duplicate object key")
        return 2
    except Refusal as error:
        emit_refusal(error.code, error.message)
        return 2
    except (UnicodeDecodeError, ValueError, RecursionError, MemoryError, OverflowError):
        emit_refusal("invalid-json", "input is not valid JSON")
        return 2

    print(json_value(normalized))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception:
        emit_failure("validator failed unexpectedly")
        sys.exit(1)
