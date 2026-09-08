#!/usr/bin/env python3
"""Stage one producer-neutral evidence bundle in no-mistakes local state.

Usage:
  fm-evidence-import-stage.py admit --control-record NAME --worktree DIR
  fm-evidence-import-stage.py stage --contract OFFER.json --bundle DIR \\
      --manifest RELATIVE_PATH --batch BATCH --consent-id SHA256 \\
      --worktree DIR
  fm-evidence-import-stage.py recover --worktree DIR

The contract schema and normalization are owned by
``fm-evidence-import-contract.py``.  This command copies only its manifest,
report, and artifact files.  Final imports live below
``$NM_HOME/evidence-imports`` (or ``~/.no-mistakes/evidence-imports``), never
below the named project worktree.
``NM_HOME`` must be absolute and its protected ancestry must not be replaceable
by another local principal.  The state root, evidence-import directory, and
lock must be owned by the current user and must not be group or world writable;
the lock also must be a regular file.  On macOS, grant-capable extended ACLs on
the protected directory boundary are refused.  The state root must be outside
the named worktree, and ``evidence-imports`` must not overlap it in either
direction.  Atomic no-replace finalization requires supported macOS or Linux.

``admit`` is the only Evidence Import Consent intake.  It accepts one basename
from ``$NM_HOME/evidence-import-control``, a protected local directory created
and populated by the trusted host controller outside this command.  It never
accepts a project path, stdin, repository or environment approval setting,
``--yes``, or generic automatic approval.  The control record is one JSON
object with ``schema_version`` ``1.0``, ``decision``
``evidence-import-consent``, an opaque ``batch``, and ``contract`` containing
the exact contract owned by ``fm-evidence-import-contract.py``.  Admission is
refused from a no-mistakes validation-gate descendant.  Accepted consent is
canonically stored below protected evidence-import state and identified by its
SHA-256 digest.

Every source component is opened relative to the already-open bundle directory
with symlink following disabled.  The command copies into one unique
``.incomplete-*`` directory, proves each source path remained bound to the same
regular file, verifies every hash from the staged bytes, and publishes the
complete directory with one rename.  ``stage`` first requires the exact pending
consent id and batch, revalidates every consent binding, and atomically consumes
that one consent under the staging lock immediately before finalized staging
can become visible.  A byte-identical finalized import remains a safe target
for a newly admitted exact consent, but ordinary replay of consumed consent is
refused.  Any other import resolving to the same run-and-manifest identity is
refused without replacing or merging the existing directory.  Consent
authorizes protected staging only; this command never creates publication
approval or mutates a pull request.

``recover`` removes abandoned incomplete directories while holding the same
per-state-root lock used by ``stage``.  Incomplete names are never import
destinations and therefore cannot become publishable during recovery.
One source file may contain at most 67108864 bytes and one incomplete import
may contain at most 536870912 source bytes, bounding interrupted recovery state.
"""

import argparse
import ctypes
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parent
CONTRACT_SCRIPT = SCRIPT_DIR / "fm-evidence-import-contract.py"
GATE_REFUSE_SCRIPT = SCRIPT_DIR / "fm-gate-refuse-lib.sh"
INCOMPLETE_PREFIX = ".incomplete-"
CONSENT_STATE_DIRECTORY = ".consents"
CONSENT_PENDING_DIRECTORY = "pending"
CONSENT_CONSUMED_DIRECTORY = "consumed"
CONTROL_DIRECTORY = "evidence-import-control"
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_IMPORT_BYTES = 512 * 1024 * 1024
ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0
ACL_NEXT_ENTRY = -1
ACL_EXTENDED_ALLOW = 1
LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.openat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_int)
LIBC.openat.restype = ctypes.c_int
LIBC.mkdirat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
LIBC.mkdirat.restype = ctypes.c_int
LIBC.unlinkat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
LIBC.unlinkat.restype = ctypes.c_int
LIBC.readlinkat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t)
LIBC.readlinkat.restype = ctypes.c_ssize_t
if sys.platform == "darwin":
    LIBC.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
    LIBC.acl_get_fd_np.restype = ctypes.c_void_p
    LIBC.acl_get_entry.argtypes = (
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_void_p),
    )
    LIBC.acl_get_entry.restype = ctypes.c_int
    LIBC.acl_get_tag_type.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_int))
    LIBC.acl_get_tag_type.restype = ctypes.c_int
    LIBC.acl_free.argtypes = (ctypes.c_void_p,)
    LIBC.acl_free.restype = ctypes.c_int


class Refusal(ValueError):
    """A deterministic, caller-correctable refusal."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def emit_line(stream, value):
    stream.buffer.write((value + "\n").encode("utf-8", errors="backslashreplace"))


def emit_json(stream, value):
    emit_line(stream, json.dumps(value, ensure_ascii=True, separators=(",", ":")))


def refuse(code, message):
    raise Refusal(code, message)


def load_contract_owner():
    spec = importlib.util.spec_from_file_location("fm_evidence_import_contract", CONTRACT_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("contract validator is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalized_contract(path):
    owner = load_contract_owner()
    try:
        if not os.path.isfile(path):
            raise RuntimeError("contract input is not a regular file")
        raw = owner.read_input(path)
        contract = owner.decode_contract(raw)
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    except owner.DuplicateKeyError as error:
        raise Refusal("duplicate-key", "input contains a duplicate object key") from error
    except (UnicodeDecodeError, ValueError, RecursionError, MemoryError, OverflowError) as error:
        raise Refusal("invalid-json", "input is not valid JSON") from error
    return contract, (owner.json_value(contract) + "\n").encode("utf-8")


def decode_one_json(raw, owner):
    if len(raw) > owner.MAX_JSON_BYTES:
        refuse("control-record-too-large", "consent control record exceeds 1048576 bytes")
    try:
        text = raw.decode("utf-8")
        decoder = json.JSONDecoder(
            object_pairs_hook=owner.object_without_duplicates,
            parse_int=owner.JsonIntegerToken,
            parse_constant=owner.reject_constant,
        )
        whitespace = re.compile(r"[ \t\r\n]*")
        start = whitespace.match(text, 0).end()
        value, end = decoder.raw_decode(text, start)
        end = whitespace.match(text, end).end()
        if end != len(text):
            refuse("invalid-control-record", "consent control record must contain one JSON value")
        owner.reject_lone_surrogates(value)
        return value
    except owner.DuplicateKeyError as error:
        raise Refusal(
            "duplicate-control-key", "consent control record contains a duplicate object key"
        ) from error
    except Refusal:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError, MemoryError, OverflowError) as error:
        raise Refusal(
            "invalid-control-record", "consent control record is not valid JSON"
        ) from error


def normalized_consent(raw):
    owner = load_contract_owner()
    value = decode_one_json(raw, owner)
    if not isinstance(value, dict):
        refuse("invalid-control-record", "consent control record must be a JSON object")
    expected = {"schema_version", "decision", "batch", "contract"}
    if set(value) != expected:
        refuse(
            "invalid-control-record",
            "consent control record must contain exactly schema_version, decision, batch, and contract",
        )
    if value["schema_version"] != "1.0":
        refuse("unsupported-consent-schema", "consent control schema_version must be 1.0")
    if value["decision"] != "evidence-import-consent":
        refuse(
            "invalid-control-record",
            "consent control decision must be evidence-import-consent",
        )
    try:
        batch = owner.opaque(value["batch"], "batch")
        contract = owner.validate_contract(value["contract"])
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    consent = {
        "schema_version": "1.0",
        "decision": "evidence-import-consent",
        "batch": batch,
        "contract": contract,
    }
    encoded = (owner.json_value(consent) + "\n").encode("utf-8")
    return consent, encoded, hashlib.sha256(encoded).hexdigest()


def expected_consent(batch, contract):
    owner = load_contract_owner()
    try:
        normalized_batch = owner.opaque(batch, "batch")
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    consent = {
        "schema_version": "1.0",
        "decision": "evidence-import-consent",
        "batch": normalized_batch,
        "contract": contract,
    }
    encoded = (owner.json_value(consent) + "\n").encode("utf-8")
    return consent, encoded


def gate_context(anchor):
    command = """
unset FM_GATE_REFUSE_BYPASS
. "$1" || exit 2
if fm_is_gate_agent "$2"; then
  exit 0
fi
exit 1
"""
    result = subprocess.run(
        ["bash", "-c", command, "fm-evidence-import-stage", str(GATE_REFUSE_SCRIPT), anchor],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise RuntimeError("validation-gate context could not be inspected safely")


def refuse_validation_descendant(worktree):
    if gate_context(".") or gate_context(worktree):
        refuse(
            "validation-descendant",
            "a no-mistakes validation-step descendant cannot admit Evidence Import Consent",
        )


def contained_by(path, directory):
    try:
        return os.path.commonpath((path, directory)) == directory
    except ValueError:
        return False


def group_or_world_writable(file_stat):
    return bool(file_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH))


def directory_flags():
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def file_identity(file_stat):
    return file_stat.st_dev, file_stat.st_ino


def shared_write_and_execute(file_stat):
    mode = file_stat.st_mode
    return bool(
        (mode & stat.S_IWGRP and mode & stat.S_IXGRP)
        or (mode & stat.S_IWOTH and mode & stat.S_IXOTH)
    )


def ancestor_is_replaceable(parent_stat, child_stat=None):
    trusted_owners = (0, os.geteuid())
    if parent_stat.st_uid not in trusted_owners:
        return True
    if not shared_write_and_execute(parent_stat):
        return False
    if not parent_stat.st_mode & stat.S_ISVTX:
        return True
    return child_stat is not None and child_stat.st_uid not in trusted_owners


def descriptor_has_grant_acl(descriptor):
    if sys.platform != "darwin":
        return False
    ctypes.set_errno(0)
    acl = LIBC.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error_number = ctypes.get_errno()
        if error_number in (errno.ENOENT, errno.EOPNOTSUPP):
            return False
        raise OSError(error_number, os.strerror(error_number))
    try:
        entry_id = ACL_FIRST_ENTRY
        while True:
            entry = ctypes.c_void_p()
            ctypes.set_errno(0)
            result = LIBC.acl_get_entry(acl, entry_id, ctypes.byref(entry))
            if result < 0:
                error_number = ctypes.get_errno()
                if error_number == errno.EINVAL:
                    return False
                raise OSError(error_number, os.strerror(error_number))
            tag_type = ctypes.c_int()
            if LIBC.acl_get_tag_type(entry, ctypes.byref(tag_type)) < 0:
                error_number = ctypes.get_errno()
                raise OSError(error_number, os.strerror(error_number))
            if tag_type.value == ACL_EXTENDED_ALLOW:
                return True
            entry_id = ACL_NEXT_ENTRY
    finally:
        LIBC.acl_free(acl)


def refuse_grant_acl(descriptor):
    try:
        has_grant = descriptor_has_grant_acl(descriptor)
    except OSError as error:
        raise Refusal(
            "unsafe-state-root",
            "NM_HOME extended ACLs could not be inspected safely",
        ) from error
    if has_grant:
        refuse(
            "unsafe-state-root",
            "NM_HOME state directories must not grant access through extended ACLs",
        )


def directory_contains(ancestor_fd, descendant_fd):
    ancestor = file_identity(os.fstat(ancestor_fd))
    current = os.dup(descendant_fd)
    seen = set()
    try:
        while True:
            current_identity = file_identity(os.fstat(current))
            if current_identity == ancestor:
                return True
            if current_identity in seen:
                return False
            seen.add(current_identity)
            parent = open_at(current, "..", directory_flags())
            parent_identity = file_identity(os.fstat(parent))
            if parent_identity == current_identity:
                os.close(parent)
                return False
            os.close(current)
            current = parent
    finally:
        os.close(current)


def open_worktree(worktree):
    worktree_path = os.path.realpath(os.path.abspath(worktree))
    try:
        descriptor = os.open(worktree_path, directory_flags())
    except OSError as error:
        raise Refusal("invalid-worktree", "worktree must name an existing directory") from error
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        refuse("invalid-worktree", "worktree must name an existing directory")
    return worktree_path, descriptor


def open_state_root(path, worktree_fd):
    current = os.open(os.sep, directory_flags())
    components = path.split(os.sep)[1:]
    followed = 0
    try:
        while components:
            component = components.pop(0)
            if component in ("", "."):
                continue
            refuse_grant_acl(current)
            if component == "..":
                next_fd = open_at(current, "..", directory_flags())
                os.close(current)
                current = next_fd
                continue
            parent_stat = os.fstat(current)
            if ancestor_is_replaceable(parent_stat):
                refuse(
                    "unsafe-state-root",
                    "NM_HOME ancestors must not permit replacement by another local principal",
                )
            try:
                next_fd = open_at(current, component, directory_flags())
            except FileNotFoundError:
                if file_identity(os.fstat(current)) == file_identity(os.fstat(worktree_fd)):
                    refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
                try:
                    mkdir_at(current, component, 0o700)
                except FileExistsError:
                    components.insert(0, component)
                    continue
                next_fd = open_at(current, component, directory_flags())
            except OSError as error:
                if error.errno not in (errno.ELOOP, errno.ENOTDIR):
                    raise
                if shared_write_and_execute(parent_stat):
                    refuse(
                        "unsafe-state-root",
                        "NM_HOME ancestors must not permit replacement by another local principal",
                    )
                try:
                    target = readlink_at(current, component)
                except OSError:
                    raise error
                followed += 1
                if followed > 40:
                    refuse("unsafe-state-root", "NM_HOME contains too many symbolic links")
                target_components = target.split(os.sep)
                if os.path.isabs(target):
                    os.close(current)
                    current = os.open(os.sep, directory_flags())
                    target_components = target_components[1:]
                components = target_components + components
                continue
            next_stat = os.fstat(next_fd)
            if ancestor_is_replaceable(parent_stat, next_stat):
                os.close(next_fd)
                refuse(
                    "unsafe-state-root",
                    "NM_HOME ancestors must not permit replacement by another local principal",
                )
            if file_identity(next_stat) == file_identity(os.fstat(worktree_fd)):
                os.close(next_fd)
                refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
            os.close(current)
            current = next_fd
        refuse_grant_acl(current)
        if file_identity(os.fstat(current)) == file_identity(os.fstat(worktree_fd)):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
        return current
    except Refusal:
        os.close(current)
        raise
    except OSError as error:
        os.close(current)
        raise RuntimeError("could not prepare no-mistakes state") from error


def resolve_state_root(worktree):
    worktree_path, worktree_fd = open_worktree(worktree)

    configured = os.environ.get("NM_HOME", os.path.expanduser("~/.no-mistakes"))
    if not os.path.isabs(configured):
        os.close(worktree_fd)
        refuse("unsafe-state-root", "NM_HOME must resolve from an absolute path")
    state_root = os.path.realpath(configured)
    imports = os.path.join(state_root, "evidence-imports")
    imports_namespace = os.path.realpath(imports)
    if contained_by(state_root, worktree_path):
        os.close(worktree_fd)
        refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
    if contained_by(imports_namespace, worktree_path) or contained_by(
        worktree_path, imports_namespace
    ):
        os.close(worktree_fd)
        refuse(
            "unsafe-state-root",
            "evidence import state must not overlap the project worktree",
        )

    state_root_fd = None
    imports_fd = None
    try:
        state_root_fd = open_state_root(configured, worktree_fd)
        state_root = os.path.realpath(configured)
        imports = os.path.join(state_root, "evidence-imports")
        imports_namespace = os.path.realpath(imports)
        if contained_by(state_root, worktree_path):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
        if contained_by(imports_namespace, worktree_path) or contained_by(
            worktree_path, imports_namespace
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must not overlap the project worktree",
            )
        root_stat = os.fstat(state_root_fd)
        if (
            not stat.S_ISDIR(root_stat.st_mode)
            or root_stat.st_uid != os.geteuid()
            or group_or_world_writable(root_stat)
        ):
            refuse(
                "unsafe-state-root",
                "no-mistakes state must be an owned directory without group or world write access",
            )
        if directory_contains(worktree_fd, state_root_fd):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")

        try:
            imports_fd = open_at(state_root_fd, "evidence-imports", directory_flags())
        except FileNotFoundError:
            mkdir_at(state_root_fd, "evidence-imports", 0o700)
            imports_fd = open_at(state_root_fd, "evidence-imports", directory_flags())
        refuse_grant_acl(imports_fd)
        imports_stat = os.fstat(imports_fd)
        if (
            not stat.S_ISDIR(imports_stat.st_mode)
            or imports_stat.st_uid != os.geteuid()
            or group_or_world_writable(imports_stat)
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must be an owned directory without group or world write access",
            )
        if directory_contains(imports_fd, worktree_fd) or directory_contains(
            worktree_fd, imports_fd
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must not overlap the project worktree",
            )
        result_root_fd = state_root_fd
        state_root_fd = None
        return state_root, imports, result_root_fd, imports_fd
    except Refusal:
        if imports_fd is not None:
            os.close(imports_fd)
        raise
    except OSError as error:
        if imports_fd is not None:
            os.close(imports_fd)
        raise RuntimeError("could not prepare evidence import state") from error
    finally:
        if state_root_fd is not None:
            os.close(state_root_fd)
        os.close(worktree_fd)


def acquire_lock(imports_fd):
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = open_at(imports_fd, ".lock", flags, 0o600)
        lock_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(lock_stat.st_mode)
            or lock_stat.st_uid != os.geteuid()
            or group_or_world_writable(lock_stat)
        ):
            os.close(descriptor)
            refuse(
                "unsafe-state-root",
                "evidence import lock must be an owned regular file without group or world write access",
            )
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except Refusal:
        raise
    except OSError as error:
        raise RuntimeError("could not lock evidence import state") from error


def open_owned_directory_at(parent_fd, name, label, create):
    try:
        descriptor = open_at(parent_fd, name, directory_flags())
    except FileNotFoundError:
        if not create:
            refuse("control-state-missing", "protected evidence import control state is unavailable")
        try:
            mkdir_at(parent_fd, name, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            raise Refusal(
                "unsafe-control-state", "{} could not be prepared safely".format(label)
            ) from error
        try:
            descriptor = open_at(parent_fd, name, directory_flags())
        except OSError as error:
            raise Refusal(
                "unsafe-control-state", "{} could not be opened safely".format(label)
            ) from error
    except OSError as error:
        raise Refusal("unsafe-control-state", "{} could not be opened safely".format(label)) from error
    try:
        refuse_grant_acl(descriptor)
        entry_stat = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(entry_stat.st_mode)
            or entry_stat.st_uid != os.geteuid()
            or group_or_world_writable(entry_stat)
        ):
            refuse(
                "unsafe-control-state",
                "{} must be an owned directory without group or world write access".format(label),
            )
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def consent_state(imports_fd):
    root_fd = open_owned_directory_at(
        imports_fd, CONSENT_STATE_DIRECTORY, "evidence import consent state", True
    )
    pending_fd = None
    consumed_fd = None
    try:
        pending_fd = open_owned_directory_at(
            root_fd, CONSENT_PENDING_DIRECTORY, "pending consent state", True
        )
        consumed_fd = open_owned_directory_at(
            root_fd, CONSENT_CONSUMED_DIRECTORY, "consumed consent state", True
        )
        return root_fd, pending_fd, consumed_fd
    except Exception:
        if pending_fd is not None:
            os.close(pending_fd)
        if consumed_fd is not None:
            os.close(consumed_fd)
        os.close(root_fd)
        raise


def control_record_name(value):
    if not isinstance(value, str) or not value:
        refuse("invalid-control-record-name", "control record name is required")
    if len(value) > 128 or value[0] == "." or any(
        character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        for character in value
    ):
        refuse(
            "invalid-control-record-name",
            "control record must be one non-hidden basename of at most 128 safe characters",
        )
    return value


def validate_consent_id(value):
    if value is None:
        refuse("consent-missing", "one exact pending consent id is required before staging")
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        refuse("invalid-consent-id", "consent id must be a lowercase SHA-256 digest")
    return value


def read_regular_record_at(directory_fd, name, label, missing_ok=False):
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = open_at(directory_fd, name, flags)
    except FileNotFoundError:
        if missing_ok:
            return None
        refuse("control-record-missing", "protected consent control record is unavailable")
    except OSError as error:
        raise Refusal("unsafe-control-state", "{} could not be opened safely".format(label)) from error
    try:
        before_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before_stat.st_mode)
            or before_stat.st_uid != os.geteuid()
            or group_or_world_writable(before_stat)
            or before_stat.st_nlink != 1
        ):
            refuse(
                "unsafe-control-state",
                "{} must be one owned regular file without shared write access or hard links".format(label),
            )
        chunks = []
        size = 0
        while True:
            chunk = os.read(descriptor, min(65536, 1048577 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > 1048576:
                refuse("control-record-too-large", "{} exceeds 1048576 bytes".format(label))
        after_stat = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    rebound_fd = None
    try:
        rebound_fd = open_at(directory_fd, name, flags)
        rebound_stat = os.fstat(rebound_fd)
        if (
            source_fingerprint(before_stat) != source_fingerprint(after_stat)
            or source_fingerprint(before_stat) != source_fingerprint(rebound_stat)
        ):
            refuse("control-state-changed", "{} changed while it was read".format(label))
    except FileNotFoundError as error:
        raise Refusal("control-state-changed", "{} changed while it was read".format(label)) from error
    except OSError as error:
        raise Refusal("control-state-changed", "{} changed while it was read".format(label)) from error
    finally:
        if rebound_fd is not None:
            os.close(rebound_fd)
    return b"".join(chunks), source_fingerprint(before_stat)


def write_all(descriptor, content):
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        view = view[written:]


def write_atomic_record(directory_fd, name, content):
    temporary = ".incomplete-consent-" + os.urandom(16).hex()
    descriptor = None
    try:
        descriptor = open_at(
            directory_fd,
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        write_all(descriptor, content)
        os.fchmod(descriptor, 0o400)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        rename_without_replace(directory_fd, temporary, directory_fd, name)
        os.fsync(directory_fd)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            unlink_at(directory_fd, temporary)
        except FileNotFoundError:
            pass


def read_stored_consent(directory_fd, consent_id, state, missing_ok=False):
    name = consent_id + ".json"
    record = read_regular_record_at(
        directory_fd, name, "{} consent record".format(state), missing_ok
    )
    if record is None:
        return None
    raw, _fingerprint = record
    try:
        consent, encoded, actual_id = normalized_consent(raw)
    except Refusal as error:
        raise Refusal(
            "consent-state-invalid",
            "{} consent record is invalid: {}".format(state, error.code),
        ) from error
    if encoded != raw or actual_id != consent_id:
        refuse(
            "consent-state-invalid",
            "{} consent record does not match its protected identity".format(state),
        )
    return consent, encoded


def pending_consent(pending_fd, consumed_fd, consent_id, expected):
    if read_stored_consent(consumed_fd, consent_id, "consumed", True) is not None:
        refuse("consent-already-consumed", "Evidence Import Consent was already consumed")
    stored = read_stored_consent(pending_fd, consent_id, "pending", True)
    if stored is None:
        refuse("consent-missing", "matching pending Evidence Import Consent was not found")
    consent, encoded = stored
    if consent != expected:
        refuse("consent-mismatch", "pending Evidence Import Consent does not match the offered batch")
    return encoded


def consume_consent(pending_fd, consumed_fd, consent_id):
    try:
        rename_without_replace(
            pending_fd,
            consent_id + ".json",
            consumed_fd,
            consent_id + ".json",
        )
    except FileExistsError:
        refuse("consent-already-consumed", "Evidence Import Consent was already consumed")
    except OSError as error:
        raise Refusal(
            "consent-state-changed", "pending Evidence Import Consent changed before consumption"
        ) from error
    os.fsync(pending_fd)
    os.fsync(consumed_fd)


def remove_incomplete(imports):
    removed = 0
    try:
        names = os.listdir(imports)
    except OSError as error:
        raise RuntimeError("could not inspect incomplete imports") from error
    for name in names:
        if not name.startswith(INCOMPLETE_PREFIX):
            continue
        path = os.path.join(imports, name)
        try:
            entry_stat = os.lstat(path)
            if stat.S_ISDIR(entry_stat.st_mode):
                remove_tree(path)
            else:
                os.unlink(path)
            removed += 1
        except FileNotFoundError:
            continue
        except OSError as error:
            raise RuntimeError("could not remove an incomplete import") from error
    return removed


def remove_tree(path):
    for directory, directories, _files in os.walk(path, topdown=True, followlinks=False):
        os.chmod(directory, 0o700, follow_symlinks=False)
        for name in directories:
            member = os.path.join(directory, name)
            if stat.S_ISDIR(os.lstat(member).st_mode):
                os.chmod(member, 0o700, follow_symlinks=False)
    for directory, directories, files in os.walk(path, topdown=False, followlinks=False):
        for name in files:
            member = os.path.join(directory, name)
            try:
                os.chmod(member, 0o600, follow_symlinks=False)
            except OSError:
                pass
            os.unlink(member)
        for name in directories:
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if stat.S_ISDIR(member_stat.st_mode):
                os.rmdir(member)
            else:
                os.unlink(member)
    os.rmdir(path)


def open_bundle(bundle):
    path = os.path.abspath(bundle)
    try:
        bundle_stat = os.lstat(path)
    except OSError as error:
        raise Refusal("unsafe-bundle", "offered bundle is unavailable") from error
    if not stat.S_ISDIR(bundle_stat.st_mode):
        refuse("unsafe-bundle", "offered bundle must be a directory, not a symlink")
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as error:
        raise Refusal("unsafe-bundle", "could not safely open offered bundle") from error


def source_fingerprint(file_stat):
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def open_at(directory_fd, name, flags, mode=0):
    descriptor = LIBC.openat(directory_fd, os.fsencode(name), flags, mode)
    if descriptor < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)
    return descriptor


def mkdir_at(directory_fd, name, mode):
    result = LIBC.mkdirat(directory_fd, os.fsencode(name), mode)
    if result < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)


def unlink_at(directory_fd, name):
    result = LIBC.unlinkat(directory_fd, os.fsencode(name), 0)
    if result < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)


def readlink_at(directory_fd, name):
    size = 256
    while size <= 65536:
        buffer = ctypes.create_string_buffer(size)
        result = LIBC.readlinkat(directory_fd, os.fsencode(name), buffer, size)
        if result < 0:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number), name)
        if result < size:
            return os.fsdecode(buffer.raw[:result])
        size *= 2
    raise OSError(errno.ENAMETOOLONG, os.strerror(errno.ENAMETOOLONG), name)


def open_regular_at(bundle_fd, relative_path):
    current = os.dup(bundle_fd)
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        components = relative_path.split("/")
        for component in components[:-1]:
            directory_flags = flags
            if hasattr(os, "O_DIRECTORY"):
                directory_flags |= os.O_DIRECTORY
            next_fd = open_at(current, component, directory_flags)
            next_stat = os.fstat(next_fd)
            if not stat.S_ISDIR(next_stat.st_mode):
                os.close(next_fd)
                refuse("unsafe-source", "bundle path component is not a directory")
            os.close(current)
            current = next_fd
        file_fd = open_at(current, components[-1], flags)
        file_stat = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat.st_mode):
            os.close(file_fd)
            refuse("unsafe-source", "bundle member is not a regular file")
        return file_fd, source_fingerprint(file_stat)
    except Refusal:
        raise
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR, errno.ENOENT):
            raise Refusal(
                "unsafe-source", "bundle member could not be opened without path substitution"
            ) from error
        raise RuntimeError("could not read offered bundle") from error
    finally:
        os.close(current)


def test_stop(point):
    """Deterministic process-stop seam used only by filesystem race tests."""
    if os.environ.get("FM_EVIDENCE_IMPORT_TEST_STOP") == point:
        os.kill(os.getpid(), signal.SIGSTOP)


def write_from_source(bundle_fd, relative_path, destination, max_bytes):
    source_fd, before = open_regular_at(bundle_fd, relative_path)
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    output_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        output_flags |= os.O_NOFOLLOW
    output_fd = os.open(destination, output_flags, 0o600)
    digest = hashlib.sha256()
    copied = 0
    try:
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > max_bytes:
                refuse("source-too-large", "bundle member exceeds the bounded import size")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output_fd, view)
                view = view[written:]
        os.fsync(output_fd)
        test_stop("after-copy:" + relative_path)
        after = source_fingerprint(os.fstat(source_fd))
    finally:
        os.close(output_fd)
        os.close(source_fd)

    replacement_fd, rebound = open_regular_at(bundle_fd, relative_path)
    os.close(replacement_fd)
    if before != after or before != rebound:
        refuse("source-changed", "bundle member changed during import: {}".format(relative_path))
    return digest.hexdigest(), copied


def sha256_file(path):
    digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            refuse("staged-copy-invalid", "staged evidence contains a non-regular file")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def write_bytes(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def staged_files(contract, manifest_path):
    entries = [(manifest_path, "manifest.json", contract["manifest_sha256"])]
    entries.append(
        (
            contract["report"]["path"],
            "bundle/" + contract["report"]["path"],
            contract["report"]["sha256"],
        )
    )
    entries.extend(
        (artifact["path"], "bundle/" + artifact["path"], artifact["sha256"])
        for artifact in contract["artifacts"]
    )
    return entries


def verify_staged(temp_path, entries):
    for _source, destination, expected in entries:
        actual = sha256_file(os.path.join(temp_path, destination))
        if actual != expected:
            refuse("hash-mismatch", "staged file hash does not match contract: {}".format(destination))


def tree_identity(path):
    identity = []
    for directory, directories, files in os.walk(path, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        relative_directory = os.path.relpath(directory, path)
        for name in list(directories):
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if not stat.S_ISDIR(member_stat.st_mode):
                refuse("destination-collision", "final import contains an unsafe path")
            relative = os.path.normpath(os.path.join(relative_directory, name))
            identity.append(("directory", relative))
        for name in files:
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if not stat.S_ISREG(member_stat.st_mode):
                refuse("destination-collision", "final import contains an unsafe path")
            relative = os.path.normpath(os.path.join(relative_directory, name))
            identity.append(("file", relative, member_stat.st_size, sha256_file(member)))
    return identity


def protect_tree(path):
    directories = []
    for directory, child_directories, files in os.walk(path, topdown=True):
        directories.append(directory)
        for name in files:
            os.chmod(os.path.join(directory, name), 0o400, follow_symlinks=False)
        child_directories.sort()
    for directory in reversed(directories):
        os.chmod(directory, 0o700, follow_symlinks=False)


def import_identity(contract):
    material = (contract["run_binding"] + "\0" + contract["manifest_sha256"]).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def rename_without_replace(source_directory_fd, source, destination_directory_fd, destination):
    if sys.platform == "darwin" and hasattr(LIBC, "renameatx_np"):
        function = LIBC.renameatx_np
        function.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(
            source_directory_fd,
            os.fsencode(source),
            destination_directory_fd,
            os.fsencode(destination),
            0x00000004,
        )
    elif sys.platform.startswith("linux") and hasattr(LIBC, "renameat2"):
        function = LIBC.renameat2
        function.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(
            source_directory_fd,
            os.fsencode(source),
            destination_directory_fd,
            os.fsencode(destination),
            1,
        )
    else:
        refuse("unsupported-platform", "atomic no-replace finalization is unavailable")
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError(error_number, os.strerror(error_number), destination)
    raise OSError(error_number, os.strerror(error_number), destination)


def admit(arguments):
    refuse_validation_descendant(arguments.worktree)
    record_name = control_record_name(arguments.control_record)
    state_root, _imports, state_root_fd, imports_fd = resolve_state_root(arguments.worktree)
    control_fd = None
    lock_fd = None
    consent_root_fd = None
    pending_fd = None
    consumed_fd = None
    try:
        control_fd = open_owned_directory_at(
            state_root_fd,
            CONTROL_DIRECTORY,
            "evidence import control directory",
            False,
        )
        lock_fd = acquire_lock(imports_fd)
        raw, fingerprint = read_regular_record_at(
            control_fd, record_name, "consent control record"
        )
        consent, encoded, consent_id = normalized_consent(raw)
        rebound, rebound_fingerprint = read_regular_record_at(
            control_fd, record_name, "consent control record"
        )
        if rebound != raw or rebound_fingerprint != fingerprint:
            refuse("control-state-changed", "consent control record changed during admission")
        consent_root_fd, pending_fd, consumed_fd = consent_state(imports_fd)
        if read_stored_consent(consumed_fd, consent_id, "consumed", True) is not None:
            refuse("consent-replayed", "Evidence Import Consent control record was already consumed")
        stored = read_stored_consent(pending_fd, consent_id, "pending", True)
        if stored is None:
            try:
                write_atomic_record(pending_fd, consent_id + ".json", encoded)
            except FileExistsError as error:
                raise Refusal(
                    "consent-replayed", "Evidence Import Consent control record was already admitted"
                ) from error
            status = "admitted"
        else:
            _stored_consent, stored_bytes = stored
            if stored_bytes != encoded:
                refuse(
                    "consent-state-invalid",
                    "pending consent identity collides with different protected bytes",
                )
            refuse("consent-replayed", "Evidence Import Consent control record was already admitted")

        unlink_at(control_fd, record_name)
        os.fsync(control_fd)
        emit_json(
            sys.stdout,
            {
                "status": status,
                "consent_id": consent_id,
                "batch": consent["batch"],
                "state_root": state_root,
            },
        )
        return 0
    finally:
        if consumed_fd is not None:
            os.close(consumed_fd)
        if pending_fd is not None:
            os.close(pending_fd)
        if consent_root_fd is not None:
            os.close(consent_root_fd)
        if lock_fd is not None:
            os.close(lock_fd)
        if control_fd is not None:
            os.close(control_fd)
        os.close(imports_fd)
        os.close(state_root_fd)


def stage(arguments):
    contract, normalized = normalized_contract(arguments.contract)
    expected_authority, consent_bytes = expected_consent(arguments.batch, contract)
    owner = load_contract_owner()
    try:
        manifest_path = owner.relative_path(arguments.manifest, "manifest path")
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    declared_paths = [contract["report"]["path"]] + [
        artifact["path"] for artifact in contract["artifacts"]
    ]
    if owner.paths_overlap([manifest_path] + declared_paths):
        refuse("duplicate-path", "manifest, report, and artifact paths must not overlap")
    consent_id = validate_consent_id(arguments.consent_id)

    state_root, imports, state_root_fd, imports_fd = resolve_state_root(arguments.worktree)
    test_stop("after-state-open")
    lock_fd = acquire_lock(imports_fd)
    consent_root_fd = None
    pending_fd = None
    consumed_fd = None
    bundle_fd = None
    cwd_fd = os.open(".", directory_flags())
    temp_path = None
    try:
        consent_root_fd, pending_fd, consumed_fd = consent_state(imports_fd)
        pending_bytes = pending_consent(
            pending_fd, consumed_fd, consent_id, expected_authority
        )
        if pending_bytes != consent_bytes:
            refuse("consent-mismatch", "pending Evidence Import Consent bindings changed")
        bundle_fd = open_bundle(arguments.bundle)
        os.fchdir(imports_fd)
        remove_incomplete(".")
        temp_path = tempfile.mkdtemp(prefix=INCOMPLETE_PREFIX, dir=".")
        write_bytes(os.path.join(temp_path, "contract.json"), normalized)
        write_bytes(os.path.join(temp_path, "consent.json"), consent_bytes)
        entries = staged_files(contract, manifest_path)
        total_bytes = 0
        for source, destination, expected in entries:
            remaining = MAX_IMPORT_BYTES - total_bytes
            actual, copied = write_from_source(
                bundle_fd,
                source,
                os.path.join(temp_path, destination),
                min(MAX_FILE_BYTES, remaining),
            )
            total_bytes += copied
            if actual != expected:
                refuse("hash-mismatch", "bundle member hash does not match contract: {}".format(source))
        verify_staged(temp_path, entries)
        protect_tree(temp_path)
        test_stop("before-finalize")

        identity = import_identity(contract)
        final_path = os.path.join(imports, identity)
        if os.path.lexists(identity):
            try:
                final_stat = os.lstat(identity)
                identical = stat.S_ISDIR(final_stat.st_mode) and tree_identity(
                    identity
                ) == tree_identity(temp_path)
            except (OSError, Refusal):
                identical = False
            if not identical:
                refuse(
                    "destination-collision",
                    "a non-identical finalized import already exists for this run and manifest",
                )
            remove_tree(temp_path)
            temp_path = None
            status = "already-finalized"
            consume_consent(pending_fd, consumed_fd, consent_id)
        else:
            consume_consent(pending_fd, consumed_fd, consent_id)
            test_stop("after-consume-before-finalize")
            try:
                rename_without_replace(imports_fd, temp_path, imports_fd, identity)
                temp_path = None
                status = "finalized"
            except FileExistsError:
                refuse(
                    "destination-collision",
                    "a finalized import appeared before atomic finalization",
                )
        try:
            emit_json(
                sys.stdout,
                {
                    "status": status,
                    "import_id": identity,
                    "path": final_path,
                    "state_root": state_root,
                    "batch": expected_authority["batch"],
                    "consent_id": consent_id,
                    "consent_status": "consumed",
                    "publication_authorized": False,
                },
            )
        except OSError:
            pass
        return 0
    finally:
        if temp_path is not None:
            try:
                remove_tree(temp_path)
            except OSError:
                pass
        os.fchdir(cwd_fd)
        os.close(cwd_fd)
        os.close(lock_fd)
        if consumed_fd is not None:
            os.close(consumed_fd)
        if pending_fd is not None:
            os.close(pending_fd)
        if consent_root_fd is not None:
            os.close(consent_root_fd)
        os.close(imports_fd)
        os.close(state_root_fd)
        if bundle_fd is not None:
            os.close(bundle_fd)


def recover(arguments):
    state_root, _imports, state_root_fd, imports_fd = resolve_state_root(arguments.worktree)
    test_stop("after-state-open")
    lock_fd = acquire_lock(imports_fd)
    cwd_fd = os.open(".", directory_flags())
    try:
        os.fchdir(imports_fd)
        removed = remove_incomplete(".")
        emit_json(sys.stdout, {"status": "recovered", "removed": removed, "state_root": state_root})
        return 0
    finally:
        os.fchdir(cwd_fd)
        os.close(cwd_fd)
        os.close(lock_fd)
        os.close(imports_fd)
        os.close(state_root_fd)


class StructuredArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("invalid-arguments", message)


def parse_arguments(arguments):
    parser = StructuredArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command", required=True)
    admit_parser = commands.add_parser(
        "admit", help="admit one controller-written protected consent record"
    )
    admit_parser.add_argument("--control-record", required=True)
    admit_parser.add_argument("--worktree", required=True)
    stage_parser = commands.add_parser("stage", help="stage and atomically finalize one bundle")
    stage_parser.add_argument("--contract", required=True)
    stage_parser.add_argument("--bundle", required=True)
    stage_parser.add_argument("--manifest", required=True)
    stage_parser.add_argument("--batch", required=True)
    stage_parser.add_argument("--consent-id")
    stage_parser.add_argument("--worktree", required=True)
    recover_parser = commands.add_parser("recover", help="remove abandoned incomplete imports")
    recover_parser.add_argument("--worktree", required=True)
    return parser.parse_args(arguments)


def main(arguments):
    try:
        parsed = parse_arguments(arguments)
        if parsed.command == "admit":
            return admit(parsed)
        if parsed.command == "stage":
            return stage(parsed)
        return recover(parsed)
    except Refusal as error:
        emit_json(sys.stderr, {"code": error.code, "message": error.message})
        return 2
    except RuntimeError as error:
        emit_line(sys.stderr, "fm-evidence-import-stage: {}".format(error))
        return 1
    except OSError:
        emit_line(sys.stderr, "fm-evidence-import-stage: import failed unexpectedly")
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception:
        emit_line(sys.stderr, "fm-evidence-import-stage: import failed unexpectedly")
        sys.exit(1)
